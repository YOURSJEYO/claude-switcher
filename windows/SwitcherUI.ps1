function Get-LegacySystemPowerShellPath {
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function New-LegacyCoreInvocation {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Target = '',
        [Parameter(Mandatory = $true)][string]$CorePath,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    if (@('checkdetail', 'status', 'fix', 'switch') -notcontains $Command) {
        throw "Unsupported core command: $Command"
    }
    if (-not $CorePath -or [string]::IsNullOrWhiteSpace($CorePath)) {
        throw 'Core path must not be empty.'
    }
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParseExact($OperationId, 'D', [ref]$parsedId) -or
        $parsedId -eq [guid]::Empty -or
        $OperationId -cne $parsedId.ToString('D')) {
        throw 'Operation ID must be a canonical nonempty D-form GUID.'
    }
    if ($Command -eq 'switch') {
        if ($Target -cnotin @('A', 'B')) { throw 'Switch target must be A or B.' }
    }
    elseif ($Target) {
        throw 'Only switch accepts a target.'
    }

    $arguments = New-Object System.Collections.Generic.List[string]
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $CorePath, $Command)) {
        [void]$arguments.Add($argument)
    }
    if ($Target) { [void]$arguments.Add($Target) }
    foreach ($argument in @('-Json', '-OperationId', $OperationId)) {
        [void]$arguments.Add($argument)
    }
    return [pscustomobject]@{
        FilePath = Get-LegacySystemPowerShellPath
        Arguments = $arguments.ToArray()
        Command = $Command
        Target = $Target
        OperationId = $OperationId
    }
}

function Get-LegacyUiTimeoutPolicy {
    param([Parameter(Mandatory = $true)][string]$Command)
    switch ($Command) {
        'status' { return [pscustomobject]@{ Kind = 'Hard'; TimeoutSeconds = 10; KillOnTimeout = $true } }
        'checkdetail' { return [pscustomobject]@{ Kind = 'Hard'; TimeoutSeconds = 90; KillOnTimeout = $true } }
        'switch' { return [pscustomobject]@{ Kind = 'Soft'; TimeoutSeconds = 120; KillOnTimeout = $false } }
        'fix' { return [pscustomobject]@{ Kind = 'Soft'; TimeoutSeconds = 180; KillOnTimeout = $false } }
        default { throw "Unsupported core command: $Command" }
    }
}

function Remove-LegacyCompletedProcessObservers {
    $retained = Get-Variable -Name LegacyProcessObservers -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $retained) { return }
    foreach ($entry in @($script:LegacyProcessObservers.ToArray())) {
        if ($entry.Invocation.IsCompleted) {
            try { [void]$entry.Pipeline.EndInvoke($entry.Invocation) } catch {}
            $entry.Pipeline.Dispose()
            [void]$script:LegacyProcessObservers.Remove($entry)
        }
    }
}

function Start-LegacyProcessObserver {
    param($Process, $StdoutTask, $StderrTask)
    Remove-LegacyCompletedProcessObservers
    if ($null -eq (Get-Variable -Name LegacyProcessObservers -Scope Script -ErrorAction SilentlyContinue)) {
        $script:LegacyProcessObservers = New-Object 'System.Collections.Generic.List[object]'
    }
    $completion = New-Object 'System.Threading.Tasks.TaskCompletionSource[object]'
    $pipeline = [powershell]::Create()
    [void]$pipeline.AddScript({
        param($child, $stdout, $stderr, $completionSource)
        try {
            [void]$child.WaitForExit()
            $result = [pscustomobject]@{
                ExitCode = [int]$child.ExitCode
                StandardOutput = [string]$stdout.GetAwaiter().GetResult()
                StandardError = [string]$stderr.GetAwaiter().GetResult()
            }
            try { $child.Dispose() } catch {}
            $completionSource.SetResult($result)
        }
        catch {
            try { $child.Dispose() } catch {}
            $completionSource.SetException($_.Exception)
        }
    }.ToString()).AddArgument($Process).AddArgument($StdoutTask).AddArgument($StderrTask).AddArgument($completion)
    $invocation = $pipeline.BeginInvoke()
    [void]$script:LegacyProcessObservers.Add([pscustomobject]@{ Pipeline = $pipeline; Invocation = $invocation })
    return $completion.Task
}

function Invoke-LegacyUiProcess {
    param(
        [Parameter(Mandatory = $true)]$Invocation,
        [Parameter(Mandatory = $true)]$TimeoutPolicy,
        [scriptblock]$ProcessFactory = $null
    )
    Remove-LegacyCompletedProcessObservers
    if (-not $ProcessFactory) {
        $ProcessFactory = {
            param($item)
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $item.FilePath
            $startInfo.Arguments = (@($item.Arguments) | ForEach-Object {
                '"' + ([string]$_).Replace('"', '\"') + '"'
            }) -join ' '
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.RedirectStandardInput = $true
            try { $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
            try { $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            [void]$process.Start()
            return $process
        }
    }

    try { $process = & $ProcessFactory $Invocation } catch {
        return [pscustomobject]@{
            ExitCode = $null
            StandardOutput = ''
            StandardError = $_.Exception.Message
            TimedOut = $false
            StillRunning = $false
            Killed = $false
            Observer = $null
            StartFailed = $true
        }
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $streamTasks = [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
    $milliseconds = [int]($TimeoutPolicy.TimeoutSeconds * 1000)
    $exited = $process.WaitForExit($milliseconds)
    if (-not $exited) {
        if ($TimeoutPolicy.KillOnTimeout) {
            try { $process.Kill() } catch {}
            try { [void]$process.WaitForExit(1000) } catch {}
            $observer = Start-LegacyProcessObserver -Process $process -StdoutTask $stdoutTask -StderrTask $stderrTask
            return [pscustomobject]@{
                ExitCode = $null
                StandardOutput = ''
                StandardError = ''
                TimedOut = $true
                StillRunning = $false
                Killed = $true
                Observer = $observer
                StartFailed = $false
            }
        }
        $observer = Start-LegacyProcessObserver -Process $process -StdoutTask $stdoutTask -StderrTask $stderrTask
        return [pscustomobject]@{
            ExitCode = $null
            StandardOutput = ''
            StandardError = ''
            TimedOut = $true
            StillRunning = $true
            Killed = $false
            Observer = $observer
            StartFailed = $false
        }
    }

    [System.Threading.Tasks.Task]::WaitAll($streamTasks)
    $result = [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        StandardOutput = [string]$stdoutTask.Result
        StandardError = [string]$stderrTask.Result
        TimedOut = $false
        StillRunning = $false
        Killed = $false
        Observer = $null
        StartFailed = $false
    }
    try { $process.Dispose() } catch {}
    return $result
}

function Get-LegacyRequiredProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { throw "Core result is not an object (missing $Name)." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Core result is missing required field: $Name" }
    return $property.Value
}

function ConvertFrom-LegacyStrictBoolean {
    param($Value, [string]$Name)
    if ($Value -isnot [bool]) { throw "Core field $Name must be a Boolean." }
    return [bool]$Value
}

function ConvertFrom-LegacyStrictString {
    param($Value, [string]$Name)
    if ($Value -isnot [string]) { throw "Core field $Name must be a string." }
    return [string]$Value
}

function Test-LegacyCanonicalGuid {
    param([string]$Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = [guid]::Empty
    return [guid]::TryParseExact($Value, 'D', [ref]$parsed) -and $Value -ceq $parsed.ToString('D')
}

function ConvertFrom-LegacyCoreJson {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Stdout,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$ExpectedCommand,
        [Parameter(Mandatory = $true)][string]$ExpectedOperationId,
        [string]$Target = ''
    )
    if ([string]::IsNullOrWhiteSpace($Stdout)) { throw 'Core returned empty protocol output.' }
    $trimmed = $Stdout.Trim()
    if (-not $trimmed.StartsWith('{') -or -not $trimmed.EndsWith('}')) {
        throw 'Core output is not one JSON object.'
    }
    try { $root = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Core output is malformed JSON.' }
    if ($null -eq $root -or $root -is [array]) { throw 'Core result must be a JSON object.' }

    $schema = Get-LegacyRequiredProperty $root 'schemaVersion'
    $integerSchemaTypes = @([sbyte], [byte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $isIntegerSchema = $false
    foreach ($integerSchemaType in $integerSchemaTypes) {
        if ($schema -is $integerSchemaType) { $isIntegerSchema = $true; break }
    }
    if (-not $isIntegerSchema -or [decimal]$schema -ne [decimal]1) {
        throw 'Core protocol schemaVersion must be integer 1.'
    }

    $operationId = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $root 'operationId') 'operationId'
    if (-not (Test-LegacyCanonicalGuid $operationId) -or $operationId -cne $ExpectedOperationId) {
        throw 'Core operationId does not match the request.'
    }
    $command = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $root 'command') 'command'
    if ($command -cne $ExpectedCommand) { throw 'Core command does not match the request.' }
    $success = ConvertFrom-LegacyStrictBoolean (Get-LegacyRequiredProperty $root 'success') 'success'
    $code = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $root 'code') 'code'
    if (-not $code) { throw 'Core code must not be empty.' }
    $message = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $root 'message') 'message'

    $checks = @()
    $canLaunch = $false
    if ($command -eq 'checkdetail') {
        $checkIds = @(
            'proxy_engine', 'tun_interface', 'egress_country', 'ip_consistency',
            'timezone', 'locale', 'ipv6', 'dns', 'webrtc', 'bodyguard',
            'routing_rules', 'client_language', 'asn', 'ecosystem'
        )
        $rawChecks = @(Get-LegacyRequiredProperty $root 'checks')
        if ($rawChecks.Count -ne 14) { throw 'Core checks must contain exactly 14 items.' }
        for ($i = 0; $i -lt $checkIds.Count; $i++) {
            $item = $rawChecks[$i]
            if ($null -eq $item -or $item -is [array]) { throw 'Each core check must be an object.' }
            $id = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $item 'id') 'id'
            if ($id -cne $checkIds[$i]) { throw 'Core check IDs are missing, duplicate, unknown, or out of order.' }
            $name = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $item 'name') 'name'
            if (-not $name) { throw 'Core check name must not be empty.' }
            $status = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $item 'status') 'status'
            if (@('ok', 'warn', 'fail', 'unknown') -notcontains $status) { throw 'Core check status is unknown.' }
            $blocking = ConvertFrom-LegacyStrictBoolean (Get-LegacyRequiredProperty $item 'blocking') 'blocking'
            $expectedBlocking = switch ($status) {
                'ok' { $false }
                'warn' { $id -notin @('ip_consistency', 'asn') }
                default { $true }
            }
            if ($blocking -ne $expectedBlocking) { throw 'Core check blocking contradicts status.' }
            $detail = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $item 'detail') 'detail'
            $checks += [pscustomobject]@{
                Id = $id; Name = $name; Status = $status; Blocking = $blocking; Detail = $detail
            }
        }
        $canLaunch = ConvertFrom-LegacyStrictBoolean (Get-LegacyRequiredProperty $root 'canLaunch') 'canLaunch'
        $hasBlocking = @($checks | Where-Object { $_.Blocking }).Count -gt 0
        if ($canLaunch -ne ($success -and -not $hasBlocking)) {
            throw 'Core canLaunch contradicts success and blocking checks.'
        }
    }

    $current = $null; $phase = $null; $recoveryRequired = $null
    $activeOperationId = $null; $transactionPhase = $null
    if ($command -in @('status', 'switch')) {
        $current = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $root 'current') 'current'
        if (@('A', 'B', 'none') -notcontains $current) { throw 'Core current must be A, B, or none.' }
        $phase = ConvertFrom-LegacyStrictString (Get-LegacyRequiredProperty $root 'phase') 'phase'
        if (@('idle', 'running', 'recoveryRequired', 'completed') -notcontains $phase) { throw 'Core phase is invalid.' }
        $recoveryRequired = ConvertFrom-LegacyStrictBoolean (Get-LegacyRequiredProperty $root 'recoveryRequired') 'recoveryRequired'
        if ($recoveryRequired -ne ($phase -eq 'recoveryRequired')) { throw 'Core recoveryRequired contradicts phase.' }

        $activeValue = Get-LegacyRequiredProperty $root 'activeOperationId'
        $transactionValue = Get-LegacyRequiredProperty $root 'transactionPhase'
        if ($null -ne $activeValue) {
            $activeOperationId = ConvertFrom-LegacyStrictString $activeValue 'activeOperationId'
            if (-not (Test-LegacyCanonicalGuid $activeOperationId)) { throw 'Core activeOperationId must be canonical.' }
        }
        if ($null -ne $transactionValue) {
            $transactionPhase = ConvertFrom-LegacyStrictString $transactionValue 'transactionPhase'
            if (-not $transactionPhase) { throw 'Core transactionPhase must not be empty.' }
        }
        $ongoing = $phase -in @('running', 'recoveryRequired')
        if ($ongoing -and ($null -eq $activeOperationId -or $null -eq $transactionPhase)) {
            throw 'Running or recovery status requires activeOperationId and transactionPhase.'
        }
        if ($phase -eq 'idle' -and ($null -ne $activeOperationId -or $null -ne $transactionPhase)) {
            throw 'Idle status must not contain active operation metadata.'
        }

        if ($command -eq 'switch' -and $success -and $phase -eq 'completed' -and $current -cne $Target) {
            throw 'Completed switch current does not match target.'
        }
    }

    if ($ExitCode -ne 0 -and $success) { throw "Core exited nonzero ($ExitCode) while claiming success." }
    return [pscustomobject]@{
        SchemaVersion = 1
        OperationId = $operationId
        Command = $command
        Success = $success
        TrustedSuccess = ($ExitCode -eq 0 -and $success)
        Code = $code
        Message = $message
        Checks = $checks
        CanLaunch = $canLaunch
        Current = $current
        Phase = $phase
        RecoveryRequired = $recoveryRequired
        ActiveOperationId = $activeOperationId
        TransactionPhase = $transactionPhase
        ExitCode = $ExitCode
    }
}

function Get-LegacyCheckPresentation {
    param([Parameter(Mandatory = $true)]$Result)
    $rows = @()
    $hasWarning = $false
    foreach ($check in @($Result.Checks)) {
        switch ($check.Status) {
            'ok' { $icon = '✓'; $color = '#FF22C55E' }
            'warn' { $icon = '⚠'; $color = '#FFFACC15'; $hasWarning = $true }
            'fail' { $icon = '✗'; $color = '#FFF87171' }
            default { $icon = '?'; $color = '#FFF87171' }
        }
        $safeDetail = [string]$check.Detail
        $safeDetail = [regex]::Replace($safeDetail, '(?i)\b(?:\d{1,3}\.){3}\d{1,3}\b', '[redacted]')
        $safeDetail = [regex]::Replace($safeDetail, '(?i)(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*', '[redacted]')
        $rows += [pscustomobject]@{
            Id = $check.Id; Name = $check.Name; Detail = $safeDetail
            Icon = $icon; Color = $color; Blocking = $check.Blocking
        }
    }
    $ready = [bool]($Result.TrustedSuccess -and $Result.CanLaunch -and -not @($rows | Where-Object { $_.Blocking }).Count)
    return [pscustomobject]@{
        Checks = $rows
        CanLaunch = $ready
        AllGreen = [bool]($ready -and -not $hasWarning)
        StatusText = if ($ready -and $hasWarning) { '环境可用（有警告）' } elseif ($ready) { '环境就绪' } else { '检查未通过' }
    }
}

function Get-LegacyRecoveryGuidance {
    return @(
        '检测到未完成事务，请勿删除任何未核实的恢复材料。',
        '可能包含恢复数据的位置：%APPDATA%\Claude.new、%APPDATA%\Claude.previous，',
        '%USERPROFILE%\.claude-switcher\accounts\A.new、accounts\A.previous、accounts\B.new、accounts\B.previous。',
        '请先核对并恢复有效快照；在恢复完成并重新检查前，账号切换、修复和启动均不可用。'
    ) -join "`n"
}

function Get-LegacyStatusPresentation {
    param([Parameter(Mandatory = $true)]$Result)
    $active = if ($Result.ActiveOperationId) { $Result.ActiveOperationId } else { '—' }
    $phase = if ($Result.TransactionPhase) { $Result.TransactionPhase } else { '—' }
    $current = if ($Result.Current -eq 'none') { '未初始化' } else { $Result.Current }
    if ($Result.Phase -eq 'recoveryRequired') {
        return [pscustomobject]@{
            IsRecovery = $true; IsRunning = $false
            StatusText = '需要恢复'
            Banner = (Get-LegacyRecoveryGuidance)
            CurrentAccount = $current; ActiveOperationId = $active; TransactionPhase = $phase
            CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
        }
    }
    if ($Result.Phase -eq 'running') {
        return [pscustomobject]@{
            IsRecovery = $false; IsRunning = $true
            StatusText = '处理中'
            Banner = "核心事务仍在运行（阶段：$phase），完成状态尚未确认。请稍后刷新状态。"
            CurrentAccount = $current; ActiveOperationId = $active; TransactionPhase = $phase
            CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
        }
    }
    return [pscustomobject]@{
        IsRecovery = $false; IsRunning = $false
        StatusText = '状态已读取'
        Banner = ''
        CurrentAccount = $current; ActiveOperationId = $active; TransactionPhase = $phase
        CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
    }
}

function ConvertTo-LegacyStatusOutcome {
    param([Parameter(Mandatory = $true)]$Outcome)
    if ($Outcome.TimedOut) {
        $message = '状态查询已超时，事务状态未知。请稍后刷新状态；确认状态前不能修复、切换或启动。'
        return [pscustomobject]@{
            State = [pscustomobject]@{
                IsUnavailable = $true; IsRecovery = $false; IsRunning = $false
                StatusText = '状态不可用'; Banner = $message
                CurrentAccount = '?'; ActiveOperationId = '—'; TransactionPhase = '—'
                CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
            }
            Error = $message
        }
    }
    return [pscustomobject]@{ State = (Get-LegacyStatusPresentation -Result $Outcome.Result); Error = $null }
}

function Get-LegacySwitchPhasePresentation {
    param([Parameter(Mandatory = $true)]$Result)
    if ($Result.Phase -in @('running', 'recoveryRequired')) {
        return Get-LegacyStatusPresentation -Result $Result
    }
    return $null
}

function Set-LegacyPendingCheckRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    $ids = @(
        'proxy_engine', 'tun_interface', 'egress_country', 'ip_consistency',
        'timezone', 'locale', 'ipv6', 'dns', 'webrtc', 'bodyguard',
        'routing_rules', 'client_language', 'asn', 'ecosystem'
    )
    $Rows.Clear()
    for ($index = 0; $index -lt $ids.Count; $index++) {
        [void]$Rows.Add([pscustomobject]@{
            Id = $ids[$index]; Name = $Names[$index]; Detail = ''
            Icon = '…'; Color = '#FF6B7280'; Blocking = $true
        })
    }
}

function Test-LegacySwitchCompletion {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$Target)
    return [bool](
        $Target -in @('A', 'B') -and
        $Result.Command -eq 'switch' -and
        $Result.ExitCode -eq 0 -and
        $Result.Success -eq $true -and
        $Result.Phase -eq 'completed' -and
        $Result.RecoveryRequired -eq $false -and
        $Result.Current -ceq $Target
    )
}

function Test-LegacySwitchReady {
    param([Parameter(Mandatory = $true)]$SwitchResult, [Parameter(Mandatory = $true)][string]$Target, $FreshCheckResult = $null)
    if (-not (Test-LegacySwitchCompletion -Result $SwitchResult -Target $Target)) { return $false }
    if ($null -eq $FreshCheckResult -or $FreshCheckResult.Command -ne 'checkdetail') { return $false }
    return [bool](Get-LegacyCheckPresentation -Result $FreshCheckResult).CanLaunch
}

function Invoke-LegacyCoreOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string]$Target = '',
        [string]$CorePath = $CORE,
        [string]$OperationId = ([guid]::NewGuid().ToString('D')),
        [scriptblock]$ProcessRunner = $null
    )
    $invocation = New-LegacyCoreInvocation -Command $Command -Target $Target -CorePath $CorePath -OperationId $OperationId
    $policy = Get-LegacyUiTimeoutPolicy -Command $Command
    if (-not $ProcessRunner) { $ProcessRunner = { param($item, $timeoutPolicy) Invoke-LegacyUiProcess -Invocation $item -TimeoutPolicy $timeoutPolicy } }
    try { $processResult = & $ProcessRunner $invocation $policy } catch {
        throw "Core process could not be started or read: $($_.Exception.Message)"
    }
    if ($processResult.StartFailed) {
        throw "Core process could not be started: $($processResult.StandardError)"
    }
    if ($processResult.TimedOut) {
        return [pscustomobject]@{
            Invocation = $invocation; TimeoutPolicy = $policy; ProcessResult = $processResult
            Result = $null; TimedOut = $true; StillRunning = [bool]$processResult.StillRunning
        }
    }
    $result = ConvertFrom-LegacyCoreJson -Stdout $processResult.StandardOutput -ExitCode $processResult.ExitCode -ExpectedCommand $Command -ExpectedOperationId $OperationId -Target $Target
    return [pscustomobject]@{
        Invocation = $invocation; TimeoutPolicy = $policy; ProcessResult = $processResult
        Result = $result; TimedOut = $false; StillRunning = $false
    }
}

# Claude 账号切换器 - Windows 界面 (WPF, Beta)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$BASE = "$env:USERPROFILE\.claude-switcher"
$CORE = "$BASE\claude-switch.ps1"

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 账号切换器" Width="470" Height="820" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#FF12141D" Foreground="White">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Foreground="White">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,14">
            <Border Width="44" Height="44" CornerRadius="12">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#FF6366F1" Offset="0"/><GradientStop Color="#FF9333EA" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="盾" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="20" Foreground="White"/>
            </Border>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="Claude 账号切换器" FontSize="18" FontWeight="Bold"/>
                <TextBlock Text="安全检查 · 切换 · 启动" FontSize="11" Foreground="#8AFFFFFF"/>
            </StackPanel>
            <Border x:Name="StatusPill" Margin="60,0,0,0" Padding="12,5" CornerRadius="12" Background="#2E22C55E" VerticalAlignment="Center">
                <TextBlock x:Name="StatusText" Text="检查中" FontSize="11" FontWeight="Bold" Foreground="#FFFB923C"/>
            </Border>
        </StackPanel>

        <Border Grid.Row="1" CornerRadius="12" Background="#0DFFFFFF" BorderBrush="#14FFFFFF" BorderThickness="1" Padding="4">
            <ListBox x:Name="CheckList" Background="Transparent" BorderThickness="0" Foreground="#E6FFFFFF" FontSize="13">
                <ListBox.ItemTemplate>
                    <DataTemplate>
                        <Grid Margin="6,6" Width="380">
                            <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
                            <TextBlock Text="{Binding Detail}" HorizontalAlignment="Right" Margin="0,0,26,0" Foreground="#73FFFFFF" FontSize="11"/>
                            <TextBlock Text="{Binding Icon}" HorizontalAlignment="Right" Foreground="{Binding Color}" FontSize="14" FontWeight="Bold"/>
                        </Grid>
                    </DataTemplate>
                </ListBox.ItemTemplate>
            </ListBox>
        </Border>

        <StackPanel Grid.Row="2" Margin="0,14,0,0">
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="当前账号" FontSize="11" Foreground="#80FFFFFF" VerticalAlignment="Center"/>
                <Border Margin="6,0,0,0" Padding="10,3" CornerRadius="10" Background="#4D6366F1">
                    <TextBlock x:Name="CurrentAccount" Text="?" FontSize="11" FontWeight="Bold" Foreground="#FFA5B4FC"/>
                </Border>
            </StackPanel>
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Button x:Name="BtnA" Grid.Column="0" Content="账号 A" Height="52" FontSize="15" FontWeight="Bold"
                        Foreground="White" Background="#7A6366F1" BorderThickness="0" Cursor="Hand"/>
                <Button x:Name="BtnB" Grid.Column="2" Content="账号 B" Height="52" FontSize="15" FontWeight="Bold"
                        Foreground="White" Background="#14FFFFFF" BorderBrush="#26FFFFFF" Cursor="Hand"/>
            </Grid>
            <TextBlock x:Name="ActionHint" Text="" FontSize="11" Foreground="#80FFFFFF" Margin="0,8,0,0" TextWrapping="Wrap"/>
        </StackPanel>

        <StackPanel Grid.Row="3">
            <Border x:Name="UpdateBar" Visibility="Collapsed" CornerRadius="10" Background="#1F6366F1" BorderBrush="#556366F1" BorderThickness="1" Padding="12,10" Margin="0,12,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="UpdateText" Grid.Column="0" Text="" FontSize="11" Foreground="#FFE0E7FF" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <Button x:Name="BtnUpdate" Grid.Column="1" Content="一键更新" Padding="10,5" Margin="0,0,6,0" FontSize="11" FontWeight="Bold" Foreground="White" Background="#FF6366F1" BorderThickness="0" Cursor="Hand"/>
                    <Button x:Name="BtnLater" Grid.Column="2" Content="稍后" Padding="10,5" FontSize="11" Foreground="#B3FFFFFF" Background="#14FFFFFF" BorderThickness="0" Cursor="Hand"/>
                </Grid>
            </Border>
            <TextBlock x:Name="Banner" Text="" FontSize="12" Foreground="#FFF87171" Margin="0,12,0,6" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                <Button x:Name="BtnFix" Content="一键修复" Padding="18,8" Margin="0,0,10,0" FontWeight="Bold" Foreground="White" BorderThickness="0" Cursor="Hand">
                    <Button.Background>
                        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                            <GradientStop Color="#FF6366F1" Offset="0"/><GradientStop Color="#FF9333EA" Offset="1"/>
                        </LinearGradientBrush>
                    </Button.Background>
                </Button>
                <Button x:Name="BtnRefresh" Content="重新检查" Padding="18,8" FontWeight="Bold" Foreground="White" Background="#1AFFFFFF" BorderThickness="0" Cursor="Hand"/>
                <Button x:Name="BtnCheckUpdate" Content="检查更新" Padding="18,8" Margin="10,0,0,0" FontWeight="Bold" Foreground="White" Background="#1AFFFFFF" BorderThickness="0" Cursor="Hand"/>
            </StackPanel>
            <TextBlock Text="任何一项检查不过，都不会启动 Claude" FontSize="10" Foreground="#59FFFFFF" HorizontalAlignment="Center" Margin="0,14,0,0"/>
        </StackPanel>
    </Grid>
    </ScrollViewer>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$rows = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$win.FindName('CheckList').ItemsSource = $rows

$checkNames = @('代理内核','TUN网卡','出口IP','IP一致','时区','地区','IPv6','DNS','WebRTC','保镖','规则置顶','客户端语言','ASN属性','生态可达性')

function Set-Status($text, $color) {
    $win.FindName('StatusText').Text = $text
    $win.FindName('StatusText').Foreground = (New-Object System.Windows.Media.SolidColorBrush $color)
}

function Set-Banner($text, $color = '#FFF87171') {
    $banner = $win.FindName('Banner')
    $banner.Text = $text
    $banner.Foreground = (New-Object System.Windows.Media.SolidColorBrush $color)
}

function Set-ActionAvailability($state) {
    $win.FindName('BtnA').IsEnabled = [bool]$state.CanSwitch
    $win.FindName('BtnB').IsEnabled = [bool]$state.CanSwitch
    $win.FindName('BtnFix').IsEnabled = [bool]$state.CanFix
    $win.FindName('BtnRefresh').IsEnabled = [bool]$state.CanRefresh
    $win.FindName('CurrentAccount').Text = if ($state.CurrentAccount) { $state.CurrentAccount } else { '?' }
    $hint = if ($state.IsRecovery -or $state.IsRunning) {
        "操作 ID：$($state.ActiveOperationId)  阶段：$($state.TransactionPhase)"
    } else { '' }
    $win.FindName('ActionHint').Text = $hint
}

function Show-RecoveryState($state) {
    $color = if ($state.IsRunning) { [System.Windows.Media.Color]::FromRgb(0xFA,0xCC,0x15) } else { [System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71) }
    Set-Status $state.StatusText $color
    Set-Banner $state.Banner '#FFFACC15'
    Set-ActionAvailability $state
}

function Show-StatusFailure($message) {
    Set-Status '状态不可用' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
    Set-Banner $message
    Set-ActionAvailability ([pscustomobject]@{
        CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
        CurrentAccount = '?'; ActiveOperationId = '—'; TransactionPhase = '—'
        IsRecovery = $false; IsRunning = $false
    })
}

function Get-CurrentStatus {
    try {
        $outcome = Invoke-LegacyCoreOperation -Command 'status' -CorePath $CORE
        return ConvertTo-LegacyStatusOutcome -Outcome $outcome
    }
    catch {
        return [pscustomobject]@{ State = $null; Error = $_.Exception.Message }
    }
}

function Refresh-Checks {
    Set-LegacyPendingCheckRows -Rows $rows -Names $checkNames
    Set-Status '检查中' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C))
    Set-Banner ''
    $win.FindName('BtnA').IsEnabled = $false
    $win.FindName('BtnB').IsEnabled = $false
    $win.FindName('BtnFix').IsEnabled = $false
    $win.FindName('BtnRefresh').IsEnabled = $false
    $win.FindName('ActionHint').Text = ''

    $status = Get-CurrentStatus
    if ($status.Error) {
        Show-StatusFailure "无法读取事务状态：$($status.Error)"
        return
    }
    if ($status.State.IsRecovery -or $status.State.IsRunning) {
        Show-RecoveryState $status.State
        return
    }
    $win.FindName('CurrentAccount').Text = $status.State.CurrentAccount

    try {
        $outcome = Invoke-LegacyCoreOperation -Command 'checkdetail' -CorePath $CORE
        if ($outcome.TimedOut) {
            Set-Status '检查超时' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
            Set-Banner '安全检查未在 90 秒内完成，未获得可信结果。请稍后重新检查。'
            Set-ActionAvailability ([pscustomobject]@{
                CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
                CurrentAccount = $status.State.CurrentAccount; ActiveOperationId = '—'; TransactionPhase = '—'
                IsRecovery = $false; IsRunning = $false
            })
            return
        }
        $presentation = Get-LegacyCheckPresentation -Result $outcome.Result
        $rows.Clear()
        foreach ($row in $presentation.Checks) { $rows.Add($row) }
        if ($presentation.CanLaunch) {
            $color = if ($presentation.AllGreen) { '#FF22C55E' } else { '#FFFACC15' }
            $statusColor = if ($presentation.AllGreen) { [System.Windows.Media.Color]::FromRgb(0x22,0xC5,0x5E) } else { [System.Windows.Media.Color]::FromRgb(0xFA,0xCC,0x15) }
            Set-Status $presentation.StatusText $statusColor
            Set-Banner $(if ($presentation.AllGreen) { '14 项安全检查已通过。' } else { '14 项检查已完成；黄色警告不阻断启动，但不会显示为全绿。' }) $color
            Set-ActionAvailability ([pscustomobject]@{
                CanRefresh = $true; CanFix = $true; CanSwitch = $true; CanLaunch = $true
                CurrentAccount = $status.State.CurrentAccount; ActiveOperationId = '—'; TransactionPhase = '—'
                IsRecovery = $false; IsRunning = $false
            })
        }
        else {
            Set-Status $presentation.StatusText ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
            Set-Banner $outcome.Result.Message
            Set-ActionAvailability ([pscustomobject]@{
                CanRefresh = $true; CanFix = $true; CanSwitch = $false; CanLaunch = $false
                CurrentAccount = $status.State.CurrentAccount; ActiveOperationId = '—'; TransactionPhase = '—'
                IsRecovery = $false; IsRunning = $false
            })
        }
    }
    catch {
        Set-Status '检查不可用' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        Set-Banner "未获得可信的检查结果：$($_.Exception.Message)"
        Set-ActionAvailability ([pscustomobject]@{
            CanRefresh = $true; CanFix = $false; CanSwitch = $false; CanLaunch = $false
            CurrentAccount = $status.State.CurrentAccount; ActiveOperationId = '—'; TransactionPhase = '—'
            IsRecovery = $false; IsRunning = $false
        })
    }
}

function Switch-To($t) {
    if ($t -notin @('A', 'B')) { return }
    Set-LegacyPendingCheckRows -Rows $rows -Names $checkNames
    Set-Status '切换中' ([System.Windows.Media.Color]::FromRgb(0x60,0xA5,0xFA))
    Set-Banner "正在切换到账号 $t…（归档约需几十秒）" '#FF60A5FA'
    $win.FindName('BtnA').IsEnabled = $false
    $win.FindName('BtnB').IsEnabled = $false
    $win.FindName('BtnFix').IsEnabled = $false
    $win.FindName('BtnRefresh').IsEnabled = $false
    $win.FindName('ActionHint').Text = ''
    $win.Dispatcher.Invoke([action]{}, 'Render')
    try {
        $switchOutcome = Invoke-LegacyCoreOperation -Command 'switch' -Target $t -CorePath $CORE
        if ($switchOutcome.TimedOut) {
            Set-Status '切换仍在运行' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C))
            Set-Banner "切换尚未确认完成（后台事务可能仍在运行）。请刷新状态观察；在状态确认完成并重新检查前不会启动 Claude。" '#FFFACC15'
            $win.FindName('BtnRefresh').IsEnabled = $true
            return
        }
        $phasePresentation = Get-LegacySwitchPhasePresentation -Result $switchOutcome.Result
        if ($null -ne $phasePresentation) {
            Show-RecoveryState $phasePresentation
            return
        }
        if (-not (Test-LegacySwitchCompletion -Result $switchOutcome.Result -Target $t)) {
            Set-Status '切换未完成' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
            Set-Banner $switchOutcome.Result.Message
            $win.FindName('BtnRefresh').IsEnabled = $true
            return
        }

        $win.FindName('CurrentAccount').Text = $t
        $freshOutcome = Invoke-LegacyCoreOperation -Command 'checkdetail' -CorePath $CORE
        if ($freshOutcome.TimedOut) {
            Set-Status '切换后检查未完成' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
            Set-Banner '切换已完成，但新的安全检查未在 90 秒内完成；不会启动 Claude。请稍后重新检查。'
            $win.FindName('BtnRefresh').IsEnabled = $true
            return
        }
        if (-not (Test-LegacySwitchReady -SwitchResult $switchOutcome.Result -Target $t -FreshCheckResult $freshOutcome.Result)) {
            $presentation = Get-LegacyCheckPresentation -Result $freshOutcome.Result
            $rows.Clear()
            foreach ($row in $presentation.Checks) { $rows.Add($row) }
            Set-Status '切换后检查未通过' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
            Set-Banner $freshOutcome.Result.Message
            Set-ActionAvailability ([pscustomobject]@{
                CanRefresh = $true; CanFix = $true; CanSwitch = $false; CanLaunch = $false
                CurrentAccount = $t; ActiveOperationId = '—'; TransactionPhase = 'completed'
                IsRecovery = $false; IsRunning = $false
            })
            return
        }
        Refresh-Checks
    }
    catch {
        Set-LegacyPendingCheckRows -Rows $rows -Names $checkNames
        Set-Status '切换状态不可用' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        Set-Banner "切换结果不可信，不会启动 Claude：$($_.Exception.Message)"
        $win.FindName('BtnRefresh').IsEnabled = $true
    }
}

$script:checkJob = $null
$script:checkTimer = $null
$script:checkManual = $false
$script:updateJob = $null
$script:updateTimer = $null
$script:updateRunning = $false
$script:latestVersion = ''

function Get-UiVersion {
    $vf = Join-Path $BASE 'version.txt'
    if (Test-Path -LiteralPath $vf) {
        try {
            $raw = Get-Content -LiteralPath $vf -Raw -Encoding UTF8 -ErrorAction Stop
            if ($null -ne $raw) {
                $v = ([string]$raw).Trim()
                if ($v) { return $v }
            }
        } catch {}
    }
    return 'unknown'
}

function ConvertFrom-UpdateOutput([string]$text) {
    $map = @{}
    foreach ($line in ($text -split "`r?`n")) {
        $kv = $line -split '=', 2
        if ($kv.Count -eq 2) { $map[$kv[0].Trim()] = $kv[1].Trim() }
    }
    return $map
}

function Write-UpdateCache([string]$status, [string]$latest) {
    try {
        $obj = [pscustomobject]@{
            checkedAt = (Get-Date).ToString('o')
            latest = $latest
            status = $status
        }
        $p = Join-Path $BASE 'update-check.json'
        [System.IO.File]::WriteAllText($p, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Read-UpdateCache {
    $p = Join-Path $BASE 'update-check.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Test-UpdateCacheFresh($cache) {
    if (-not $cache -or -not $cache.checkedAt) { return $false }
    try {
        $checked = [DateTime]::Parse([string]$cache.checkedAt, [Globalization.CultureInfo]::InvariantCulture)
        $hours = ((Get-Date) - $checked).TotalHours
        return ($hours -ge 0 -and $hours -lt 24)
    } catch { return $false }
}

function Set-UpdateText([string]$text, [string]$hex) {
    $win.FindName('UpdateText').Text = $text
    $win.FindName('UpdateText').Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
}

function Show-UpdateAvailable([string]$latest) {
    $script:latestVersion = $latest
    $current = Get-UiVersion
    Set-UpdateText "发现新版本 v$latest（当前 v$current）" '#FFE0E7FF'
    $win.FindName('BtnUpdate').Visibility = 'Visible'
    $win.FindName('BtnUpdate').IsEnabled = $true
    $win.FindName('BtnLater').Content = '稍后'
    $win.FindName('BtnLater').Visibility = 'Visible'
    $win.FindName('UpdateBar').Visibility = 'Visible'
}

function Show-UpdateNote([string]$text, [bool]$isError) {
    $script:latestVersion = ''
    if ($isError) { Set-UpdateText $text '#FFF87171' } else { Set-UpdateText $text '#FFE0E7FF' }
    $win.FindName('BtnUpdate').Visibility = 'Collapsed'
    $win.FindName('BtnLater').Content = '关闭'
    $win.FindName('BtnLater').Visibility = 'Visible'
    $win.FindName('UpdateBar').Visibility = 'Visible'
}

function Show-UpdateChecking {
    Set-UpdateText '正在检查更新…' '#FFE0E7FF'
    $win.FindName('BtnUpdate').Visibility = 'Collapsed'
    $win.FindName('BtnLater').Content = '关闭'
    $win.FindName('BtnLater').Visibility = 'Visible'
    $win.FindName('UpdateBar').Visibility = 'Visible'
}

function Start-UpdateCheck([bool]$manual) {
    if ($script:updateRunning) { return }
    if (Test-Path -LiteralPath (Join-Path $BASE 'config.json')) {
        if ($manual) { Show-UpdateNote '原生安装请参考原生升级说明；当前开发 Beta 不支持原地升级。' $false }
        return
    }
    if ($script:checkJob) {
        $s = $script:checkJob.State
        if ($s -eq 'Running' -or $s -eq 'NotStarted') {
            if ($manual) { $script:checkManual = $true; Show-UpdateChecking }
            return
        }
        Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue
        $script:checkJob = $null
    }

    if (-not $manual) {
        $cache = Read-UpdateCache
        if (Test-UpdateCacheFresh $cache) {
            if ($cache.status -eq 'update_available' -and $cache.latest) {
                Show-UpdateAvailable ([string]$cache.latest)
                return
            }
            if ($cache.status -eq 'dismissed') { return }
        }
    }

    if ($script:checkTimer) {
        $script:checkTimer.Stop()
        $script:checkTimer = $null
    }
    $script:checkManual = $manual
    if ($manual) { Show-UpdateChecking }

    try {
        $script:checkJob = Start-Job -ScriptBlock {
            param($core)
            & powershell -NoProfile -ExecutionPolicy Bypass -File $core check-update 2>$null
        } -ArgumentList $CORE
    } catch {
        $script:checkJob = $null
        if ($manual) { Show-UpdateNote ("检查更新失败：" + $_.Exception.Message) $true }
        return
    }

    $script:checkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:checkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:checkTimer.Add_Tick({
        if (-not $script:checkJob) { $script:checkTimer.Stop(); return }
        $st = $script:checkJob.State
        if ($st -ne 'Completed' -and $st -ne 'Failed' -and $st -ne 'Stopped') { return }
        $script:checkTimer.Stop()
        $out = (Receive-Job $script:checkJob -ErrorAction SilentlyContinue | Out-String)
        Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue
        $script:checkJob = $null
        $kv = ConvertFrom-UpdateOutput $out
        $manualNow = [bool]$script:checkManual
        if ($kv['STATUS'] -eq 'update_available' -and $kv['LATEST']) {
            Show-UpdateAvailable ([string]$kv['LATEST'])
            Write-UpdateCache 'update_available' ([string]$kv['LATEST'])
        } elseif ($manualNow) {
            if ($kv['STATUS'] -eq 'latest') {
                Show-UpdateNote ("已是最新版本 v" + $kv['LATEST']) $false
                Write-UpdateCache 'latest' ([string]$kv['LATEST'])
            } else {
                $msg = if ($kv['MESSAGE']) { $kv['MESSAGE'] } else { '无法获取更新信息' }
                Show-UpdateNote ("检查更新失败：" + $msg) $true
            }
        } elseif ($kv['STATUS'] -eq 'latest') {
            Write-UpdateCache 'latest' ([string]$kv['LATEST'])
        }
    })
    $script:checkTimer.Start()
}

$win.FindName('BtnRefresh').Add_Click({ Refresh-Checks })
function Invoke-LegacyFixAction {
    Set-LegacyPendingCheckRows -Rows $rows -Names $checkNames
    Set-Status '修复中' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C))
    Set-Banner '正在修复…（会弹出管理员授权框）' '#FFFB923C'
    $win.FindName('BtnA').IsEnabled = $false
    $win.FindName('BtnB').IsEnabled = $false
    $win.FindName('BtnFix').IsEnabled = $false
    $win.FindName('BtnRefresh').IsEnabled = $false
    $win.Dispatcher.Invoke([action]{}, 'Render')
    try {
        $outcome = Invoke-LegacyCoreOperation -Command 'fix' -CorePath $CORE
        if ($outcome.TimedOut) {
            Set-Status '修复仍在运行' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C))
            Set-Banner '修复尚未确认完成（后台操作可能仍在运行）。请稍后刷新状态。' '#FFFACC15'
            $win.FindName('BtnRefresh').IsEnabled = $true
            return
        }
        if ($outcome.Result.Phase -eq 'recoveryRequired') {
            Show-RecoveryState (Get-LegacyStatusPresentation -Result $outcome.Result)
            return
        }
        if (-not $outcome.Result.TrustedSuccess) {
            Set-Status '修复未完成' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
            Set-Banner $outcome.Result.Message
            $win.FindName('BtnRefresh').IsEnabled = $true
            return
        }
        Refresh-Checks
    }
    catch {
        Set-Status '修复状态不可用' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        Set-Banner "未获得可信的修复结果：$($_.Exception.Message)"
        $win.FindName('BtnRefresh').IsEnabled = $true
    }
}

$win.FindName('BtnFix').Add_Click({ Invoke-LegacyFixAction })
$win.FindName('BtnA').Add_Click({ Switch-To 'A' })
$win.FindName('BtnB').Add_Click({ Switch-To 'B' })

$win.FindName('BtnCheckUpdate').Add_Click({
    if ($script:updateRunning) { return }
    Remove-Item -LiteralPath (Join-Path $BASE 'update-check.json') -Force -ErrorAction SilentlyContinue
    Start-UpdateCheck $true
})

$win.FindName('BtnLater').Add_Click({
    if ($script:checkJob) {
        Stop-Job $script:checkJob -ErrorAction SilentlyContinue
        Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue
        $script:checkJob = $null
    }
    if ($script:checkTimer) { $script:checkTimer.Stop() }
    $win.FindName('UpdateBar').Visibility = 'Collapsed'
    $latest = if ($script:latestVersion) { [string]$script:latestVersion } else { '' }
    Write-UpdateCache 'dismissed' $latest
})

$win.FindName('BtnUpdate').Add_Click({
    if ($script:updateRunning) { return }
    $script:updateRunning = $true
    $btn = $win.FindName('BtnUpdate')
    $btn.IsEnabled = $false
    $win.FindName('BtnLater').IsEnabled = $false
    $win.FindName('BtnCheckUpdate').IsEnabled = $false
    if ($script:updateTimer) { $script:updateTimer.Stop(); $script:updateTimer = $null }
    Set-UpdateText '正在下载并校验…' '#FFE0E7FF'

    try {
        $script:updateJob = Start-Job -ScriptBlock {
            param($core)
            & powershell -NoProfile -ExecutionPolicy Bypass -File $core update-now 2>$null
        } -ArgumentList $CORE
    } catch {
        $script:updateRunning = $false
        $btn.IsEnabled = $true
        $win.FindName('BtnLater').IsEnabled = $true
        $win.FindName('BtnCheckUpdate').IsEnabled = $true
        Set-UpdateText ("更新失败：" + $_.Exception.Message) '#FFF87171'
        return
    }

    $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:updateTimer.Add_Tick({
        if (-not $script:updateJob) { $script:updateTimer.Stop(); return }
        $st = $script:updateJob.State
        if ($st -ne 'Completed' -and $st -ne 'Failed' -and $st -ne 'Stopped') { return }
        $script:updateTimer.Stop()
        $out = (Receive-Job $script:updateJob -ErrorAction SilentlyContinue | Out-String)
        Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue
        $script:updateJob = $null
        $script:updateRunning = $false
        $kv = ConvertFrom-UpdateOutput $out
        if ($kv['STATUS'] -eq 'updated') {
            Set-UpdateText '更新完成，正在重启界面' '#FF22C55E'
            Write-UpdateCache 'latest' ([string]$kv['LATEST'])
            if ($script:checkJob) {
                Stop-Job $script:checkJob -ErrorAction SilentlyContinue
                Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue
                $script:checkJob = $null
            }
            $uiScript = "$BASE\SwitcherUI.ps1"
            Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $uiScript + '"')
            $win.Close()
        } elseif ($kv['STATUS'] -eq 'latest') {
            $win.FindName('BtnUpdate').IsEnabled = $true
            $win.FindName('BtnLater').IsEnabled = $true
            $win.FindName('BtnCheckUpdate').IsEnabled = $true
            Show-UpdateNote '已是最新版本' $false
            Write-UpdateCache 'latest' ([string]$kv['LATEST'])
        } else {
            $msg = if ($kv['MESSAGE']) { $kv['MESSAGE'] } else { '更新失败，请稍后重试' }
            Set-UpdateText ("更新失败：" + $msg) '#FFF87171'
            $win.FindName('BtnUpdate').IsEnabled = $true
            $win.FindName('BtnLater').IsEnabled = $true
            $win.FindName('BtnCheckUpdate').IsEnabled = $true
        }
    })
    $script:updateTimer.Start()
})

$win.Add_ContentRendered({
    Start-UpdateCheck $false
    Refresh-Checks
})
$win.Add_Closed({
    if ($script:checkTimer) { $script:checkTimer.Stop() }
    if ($script:updateTimer) { $script:updateTimer.Stop() }
    foreach ($j in @($script:checkJob, $script:updateJob)) {
        if ($j) {
            Stop-Job $j -ErrorAction SilentlyContinue
            Remove-Job $j -Force -ErrorAction SilentlyContinue
        }
    }
})
[void]$win.ShowDialog()
