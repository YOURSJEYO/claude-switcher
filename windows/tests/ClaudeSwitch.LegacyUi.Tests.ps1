# Legacy WPF compatibility UI protocol tests.
# Only function ASTs are loaded from SwitcherUI.ps1; handlers use fake controls.
# No window is created/shown and no real core, accounts, installer, Claude,
# network, or system settings are invoked. Child processes are synthetic only.

$script:LegacyUiPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SwitcherUI.ps1'
$script:LegacyUiOperationId = '76edf30d-d528-47dd-81e0-176f5a3cd895'
$script:LegacyUiCheckIds = @(
    'proxy_engine', 'tun_interface', 'egress_country', 'ip_consistency',
    'timezone', 'locale', 'ipv6', 'dns', 'webrtc', 'bodyguard',
    'routing_rules', 'client_language', 'asn', 'ecosystem'
)
$script:LegacyUiLoadError = $null

if (Test-Path -LiteralPath $script:LegacyUiPath -PathType Leaf) {
    try {
        $legacyTokens = $null
        $legacyErrors = $null
        $legacyAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:LegacyUiPath,
            [ref]$legacyTokens,
            [ref]$legacyErrors
        )
        if ($legacyErrors.Count -gt 0) {
            throw (($legacyErrors | ForEach-Object { $_.Message }) -join '; ')
        }
        $legacyFunctions = @($legacyAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        foreach ($legacyFunction in $legacyFunctions) {
            . ([scriptblock]::Create($legacyFunction.Extent.Text))
        }
    }
    catch {
        $script:LegacyUiLoadError = $_.Exception.Message
    }
}
else {
    $script:LegacyUiLoadError = "SwitcherUI.ps1 missing: $script:LegacyUiPath"
}

function Assert-LegacyUiThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Pattern = '',
        [Parameter(Mandatory = $true)][string]$Message
    )
    $threw = $false
    $actual = ''
    try { & $Action | Out-Null }
    catch {
        $threw = $true
        $actual = $_.Exception.Message
    }
    if (-not $threw) { throw "ASSERT: $Message (no exception)" }
    if ($Pattern -and $actual -notmatch $Pattern) {
        throw "ASSERT: $Message (pattern=$Pattern actual=$actual)"
    }
}

function New-LegacyUiCheckArray {
    param([hashtable]$States = @{})
    $checks = @()
    foreach ($id in $script:LegacyUiCheckIds) {
        $entry = if ($States.ContainsKey($id)) { $States[$id] } else { @{ status = 'ok'; blocking = $false } }
        $checks += [ordered]@{
            id = $id
            name = "label-$id"
            status = [string]$entry.status
            blocking = [bool]$entry.blocking
            detail = "detail-$id"
        }
    }
    return ,$checks
}

function New-LegacyUiCheckDetailJson {
    param(
        [hashtable]$States = @{},
        [object]$CanLaunchOverride = $null,
        [bool]$Success = $true,
        [string]$OperationId = $script:LegacyUiOperationId
    )
    $checks = New-LegacyUiCheckArray -States $States
    $hasBlocking = @($checks | Where-Object { $_.blocking }).Count -gt 0
    $canLaunch = [bool]($Success -and -not $hasBlocking)
    if ($null -ne $CanLaunchOverride) { $canLaunch = [bool]$CanLaunchOverride }
    return ([ordered]@{
        schemaVersion = 1
        operationId = $OperationId
        command = 'checkdetail'
        success = $Success
        code = if ($Success) { 'ok' } else { 'blocked' }
        message = 'synthetic checkdetail'
        checks = $checks
        canLaunch = $canLaunch
    } | ConvertTo-Json -Depth 10 -Compress)
}

function New-LegacyUiStateJson {
    param(
        [string]$Command = 'status',
        [string]$Current = 'A',
        [string]$Phase = 'idle',
        [bool]$RecoveryRequired = $false,
        [object]$ActiveOperationId = $null,
        [object]$TransactionPhase = $null,
        [bool]$Success = $true,
        [string]$OperationId = $script:LegacyUiOperationId
    )
    return ([ordered]@{
        schemaVersion = 1
        operationId = $OperationId
        command = $Command
        success = $Success
        code = if ($Success) { 'ok' } else { 'transactionRecoveryRequired' }
        message = 'synthetic state'
        current = $Current
        phase = $Phase
        recoveryRequired = $RecoveryRequired
        activeOperationId = $ActiveOperationId
        transactionPhase = $TransactionPhase
    } | ConvertTo-Json -Depth 6 -Compress)
}

function ConvertTo-LegacyUiJson {
    param([Parameter(Mandatory = $true)]$Object)
    return ($Object | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertFrom-LegacyUiJson {
    param([Parameter(Mandatory = $true)][string]$Json)
    return ($Json | ConvertFrom-Json)
}

function New-LegacyUiSyntheticProcessFactory {
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [hashtable]$Capture = @{})
    $scriptPathValue = $ScriptPath
    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return {
        param($invocation)
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powerShellPath
        $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPathValue + '"'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        $Capture.Process = $process
        return $process
    }.GetNewClosure()
}

function Invoke-LegacyUiHandlerFixture {
    param([scriptblock]$Responder, [scriptblock]$Action)
    Add-Type -AssemblyName PresentationCore
    $controls = @{}
    foreach ($name in @('BtnA', 'BtnB', 'BtnFix', 'BtnRefresh', 'CurrentAccount', 'ActionHint', 'StatusText', 'Banner')) {
        $controls[$name] = [pscustomobject]@{ IsEnabled = $true; Text = ''; Foreground = '' }
    }
    $controls.CurrentAccount.Text = 'A'
    $dispatcher = [pscustomobject]@{}
    $dispatcher | Add-Member ScriptMethod Invoke { param($action, $priority) $action.Invoke() }
    $win = [pscustomobject]@{ Controls = $controls; Dispatcher = $dispatcher }
    $win | Add-Member ScriptMethod FindName { param($name) return $this.Controls[$name] }
    $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $checkNames = $script:LegacyUiCheckIds
    foreach ($id in $checkNames) {
        [void]$rows.Add([pscustomobject]@{ Id = $id; Detail = 'old green'; Icon = '✓'; Color = '#FF22C55E' })
    }
    $CORE = 'C:\synthetic\never-invoked.ps1'
    $calls = New-Object 'System.Collections.Generic.List[string]'
    function Invoke-LegacyCoreOperation {
        param($Command, $Target, $CorePath)
        [void]$calls.Add($Command)
        & $Responder $Command $Target
    }
    function Set-Status { param($text, $color) $controls.StatusText.Text = $text }
    function Set-Banner { param($text, $color) $controls.Banner.Text = $text }
    & $Action
}

Add-CoreTest 'legacy-ui invocation uses explicit system PowerShell 5.1 and fixed argument order' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $core = 'C:\synthetic\claude-switch.ps1'
    $invocation = New-LegacyCoreInvocation -Command 'checkdetail' -CorePath $core -OperationId $script:LegacyUiOperationId
    $expectedPowerShell = Join-Path ([Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-Equal $expectedPowerShell $invocation.FilePath 'the UI must use the explicit system PowerShell 5.1 executable'
    Assert-Equal ('-NoProfile|-NonInteractive|-ExecutionPolicy|Bypass|-File|{0}|checkdetail|-Json|-OperationId|{1}' -f $core, $script:LegacyUiOperationId) (@($invocation.Arguments) -join '|') 'query arguments must be passed as a fixed array'

    $switch = New-LegacyCoreInvocation -Command 'switch' -Target 'B' -CorePath $core -OperationId $script:LegacyUiOperationId
    Assert-Equal ('-NoProfile|-NonInteractive|-ExecutionPolicy|Bypass|-File|{0}|switch|B|-Json|-OperationId|{1}' -f $core, $script:LegacyUiOperationId) (@($switch.Arguments) -join '|') 'switch target must precede protocol options'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui invocation allowlists commands and restricts targets to switch A/B' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $core = 'C:\synthetic\claude-switch.ps1'
    foreach ($command in @('status', 'fix')) {
        $invocation = New-LegacyCoreInvocation -Command $command -CorePath $core -OperationId $script:LegacyUiOperationId
        Assert-False (@($invocation.Arguments) -contains 'A') "$command must not accept a target"
    }
    Assert-LegacyUiThrows { New-LegacyCoreInvocation -Command 'check' -CorePath $core -OperationId $script:LegacyUiOperationId } 'command' 'unknown commands must be rejected'
    Assert-LegacyUiThrows { New-LegacyCoreInvocation -Command 'status' -Target 'A' -CorePath $core -OperationId $script:LegacyUiOperationId } 'target' 'queries must reject targets'
    Assert-LegacyUiThrows { New-LegacyCoreInvocation -Command 'switch' -Target 'C' -CorePath $core -OperationId $script:LegacyUiOperationId } 'target' 'switch target C must be rejected'
    Assert-LegacyUiThrows { New-LegacyCoreInvocation -Command 'switch' -Target 'a' -CorePath $core -OperationId $script:LegacyUiOperationId } 'target' 'switch target must be uppercase A or B'
    Assert-LegacyUiThrows { New-LegacyCoreInvocation -Command 'status' -CorePath $core -OperationId '76EDF30D-D528-47DD-81E0-176F5A3CD895' } 'operation' 'noncanonical operation IDs must be rejected'
    Assert-LegacyUiThrows { New-LegacyCoreInvocation -Command 'status' -CorePath $core -OperationId ([guid]::Empty.ToString('D')) } 'operation' 'empty request operation IDs must be rejected'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui timeout policy uses hard status/check bounds and soft mutation bounds' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $status = Get-LegacyUiTimeoutPolicy -Command 'status'
    $check = Get-LegacyUiTimeoutPolicy -Command 'checkdetail'
    $switch = Get-LegacyUiTimeoutPolicy -Command 'switch'
    $fix = Get-LegacyUiTimeoutPolicy -Command 'fix'
    Assert-Equal 'Hard' $status.Kind 'status must be a hard-bounded query'
    Assert-Equal 10 $status.TimeoutSeconds 'status must time out at 10 seconds'
    Assert-True $status.KillOnTimeout 'status timeout must terminate only the query child'
    Assert-Equal 'Hard' $check.Kind 'checkdetail must be a hard-bounded query'
    Assert-Equal 90 $check.TimeoutSeconds 'checkdetail must time out at 90 seconds'
    Assert-True $check.KillOnTimeout 'checkdetail timeout must terminate only the query child'
    Assert-Equal 'Soft' $switch.Kind 'switch must use a soft timeout'
    Assert-Equal 120 $switch.TimeoutSeconds 'switch soft timeout must be bounded for UI reporting'
    Assert-False $switch.KillOnTimeout 'switch must never kill a committing core'
    Assert-Equal 'Soft' $fix.Kind 'fix must use a soft timeout'
    Assert-Equal 180 $fix.TimeoutSeconds 'fix soft timeout must be bounded for UI reporting'
    Assert-False $fix.KillOnTimeout 'fix must never kill a committing core'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui hard query timeout kills only its process child' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $script:LegacyUiFakeKillCalls = 0
    $fake = [pscustomobject]@{
        StandardOutput = New-Object System.IO.StringReader ''
        StandardError = New-Object System.IO.StringReader ''
    }
    $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $false }
    $fake | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:LegacyUiFakeKillCalls++ }
    $script:LegacyUiFakeProcess = $fake
    $invocation = New-LegacyCoreInvocation -Command 'status' -CorePath 'C:\synthetic\claude-switch.ps1' -OperationId $script:LegacyUiOperationId
    $result = Invoke-LegacyUiProcess -Invocation $invocation -TimeoutPolicy (Get-LegacyUiTimeoutPolicy 'status') -ProcessFactory { param($item) return $script:LegacyUiFakeProcess }
    Assert-True $result.TimedOut 'hard timeout must be reported'
    Assert-True $result.Killed 'hard timeout must kill the query child'
    Assert-Equal 1 $script:LegacyUiFakeKillCalls 'hard timeout must call Kill exactly once'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui soft mutation timeout leaves the committing core running' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $script:LegacyUiFakeKillCalls = 0
    $fake = [pscustomobject]@{
        StandardOutput = New-Object System.IO.StringReader ''
        StandardError = New-Object System.IO.StringReader ''
    }
    $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) return $false }
    $fake | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:LegacyUiFakeKillCalls++ }
    $script:LegacyUiFakeProcess = $fake
    $invocation = New-LegacyCoreInvocation -Command 'switch' -Target 'B' -CorePath 'C:\synthetic\claude-switch.ps1' -OperationId $script:LegacyUiOperationId
    $result = Invoke-LegacyUiProcess -Invocation $invocation -TimeoutPolicy (Get-LegacyUiTimeoutPolicy 'switch') -ProcessFactory { param($item) return $script:LegacyUiFakeProcess }
    Assert-True $result.TimedOut 'soft timeout must be reported'
    Assert-True $result.StillRunning 'soft timeout must report that completion is unconfirmed'
    Assert-False $result.Killed 'soft timeout must not kill the core'
    Assert-Equal 0 $script:LegacyUiFakeKillCalls 'soft timeout must never call Kill'
    Assert-True ($null -ne $result.Observer) 'soft timeout must retain a non-disruptive completion observer'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui status query timeout is unavailable rather than an active transaction' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $outcome = ConvertTo-LegacyStatusOutcome ([pscustomobject]@{ TimedOut = $true; Result = $null })
    Assert-True $outcome.State.IsUnavailable 'a timed-out status read must be unavailable'
    Assert-False $outcome.State.IsRunning 'a query timeout must not claim a core transaction is running'
    Assert-Match '状态查询.*超时' $outcome.State.Banner 'the timeout must identify the status query'
    Assert-Match '事务状态未知' $outcome.State.Banner 'the actual transaction state must remain unknown'
    Assert-False $outcome.State.CanFix 'unknown status must disable fix'
    Assert-False $outcome.State.CanSwitch 'unknown status must disable account switching'
    Assert-False $outcome.State.CanLaunch 'unknown status must disable launch'
    Assert-Match '超时' $outcome.Error 'refresh must stop after a status query timeout'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui completed timed child output drains stdout and stderr concurrently' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $childPath = Join-Path ([IO.Path]::GetTempPath()) ('legacy-ui-pipe-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $child = @'
$line = 'x' * 4096
for ($i = 0; $i -lt 96; $i++) {
    [Console]::Out.WriteLine($line)
    [Console]::Error.WriteLine($line)
}
[Console]::Out.WriteLine('stdout-complete')
[Console]::Error.WriteLine('stderr-complete')
'@
    [IO.File]::WriteAllText($childPath, $child, (New-Object Text.UTF8Encoding($true)))
    $capture = @{}
    try {
        $factory = New-LegacyUiSyntheticProcessFactory -ScriptPath $childPath -Capture $capture
        $policy = [pscustomobject]@{ TimeoutSeconds = 5; KillOnTimeout = $true; Kind = 'Hard' }
        $result = Invoke-LegacyUiProcess -Invocation ([pscustomobject]@{}) -TimeoutPolicy $policy -ProcessFactory $factory
        Assert-False $result.TimedOut 'a healthy child producing to both pipes must finish within the bound'
        Assert-Match 'stdout-complete' $result.StandardOutput 'stdout must be drained while the child runs'
        Assert-Match 'stderr-complete' $result.StandardError 'stderr must be drained while the child runs'
    }
    finally {
        try { if ($capture.Process -and -not $capture.Process.HasExited) { $capture.Process.Kill(); [void]$capture.Process.WaitForExit(2000) } } catch {}
        Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui soft-timeout observer drains both pipes and retains child until exit' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $childPath = Join-Path ([IO.Path]::GetTempPath()) ('legacy-ui-soft-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $child = @'
$line = 'y' * 4096
for ($i = 0; $i -lt 96; $i++) {
    [Console]::Out.WriteLine($line)
    [Console]::Error.WriteLine($line)
}
Start-Sleep -Milliseconds 500
[Console]::Out.WriteLine('soft-stdout-complete')
[Console]::Error.WriteLine('soft-stderr-complete')
'@
    [IO.File]::WriteAllText($childPath, $child, (New-Object Text.UTF8Encoding($true)))
    $capture = @{}
    try {
        $factory = New-LegacyUiSyntheticProcessFactory -ScriptPath $childPath -Capture $capture
        $policy = [pscustomobject]@{ TimeoutSeconds = 0.1; KillOnTimeout = $false; Kind = 'Soft' }
        $result = Invoke-LegacyUiProcess -Invocation ([pscustomobject]@{}) -TimeoutPolicy $policy -ProcessFactory $factory
        Assert-True $result.TimedOut 'the caller must return at the soft observation bound'
        Assert-True $result.StillRunning 'soft timeout must report an unconfirmed child'
        Assert-False $result.Killed 'the mutation child must remain alive'
        Assert-True ($null -ne $result.Observer) 'the observer must outlive the UI call'
        Assert-True $result.Observer.Wait(10000) 'the retained observer must finish after child exit and pipe drains'
        Assert-Match 'soft-stdout-complete' $result.Observer.Result.StandardOutput 'the observer must retain final stdout'
        Assert-Match 'soft-stderr-complete' $result.Observer.Result.StandardError 'the observer must retain final stderr'
    }
    finally {
        try { if ($capture.Process -and -not $capture.Process.HasExited) { $capture.Process.Kill(); [void]$capture.Process.WaitForExit(2000) } } catch {}
        Remove-LegacyCompletedProcessObservers
        Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui accepts strict schema version one with all fourteen ordered checks' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $result = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    Assert-Equal $script:LegacyUiOperationId $result.OperationId 'the request operation ID must be echoed exactly'
    Assert-Equal 14 @($result.Checks).Count 'exactly fourteen checks must be accepted'
    Assert-Equal ($script:LegacyUiCheckIds -join '|') (@($result.Checks | ForEach-Object { $_.Id }) -join '|') 'check IDs must retain the required order'
    Assert-True $result.TrustedSuccess 'exit zero plus success true is the only trusted success state'
    Assert-True $result.CanLaunch 'a complete all-ok result may enable launch'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui rejects missing duplicate unknown and reordered checks' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $base = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $missing = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $missing.checks = @($missing.checks | Select-Object -Skip 1)
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $missing) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } '14|checks' 'missing checks must be rejected'

    $duplicate = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $duplicate.checks[1].id = $duplicate.checks[0].id
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $duplicate) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'checks|duplicate|order' 'duplicate IDs must be rejected'

    $unknown = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $unknown.checks[5].id = 'mystery_check'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $unknown) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'checks|unknown|order' 'unknown IDs must be rejected'

    $reordered = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    [array]::Reverse($reordered.checks)
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $reordered) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'checks|order' 'out-of-order IDs must be rejected'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui rejects unknown check status and malformed check fields' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $unknownStatus = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $unknownStatus.checks[3].status = 'maybe'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $unknownStatus) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'status' 'unknown status must disable launch'

    $missingName = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $missingName.checks[0].PSObject.Properties.Remove('name')
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $missingName) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'name' 'missing check names must be rejected'

    $stringBlocking = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $stringBlocking.checks[0].blocking = 'false'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $stringBlocking) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'blocking' 'string booleans must not be trusted'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui rejects empty non-object malformed multiple and trailing JSON' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    Assert-True ([bool](Get-Command ConvertFrom-LegacyCoreJson -ErrorAction SilentlyContinue)) 'strict JSON parser must exist'
    foreach ($payload in @('', '   ', '[]', 'not-json', '{', '{} {}', '{} trailing')) {
        Assert-LegacyUiThrows {
            ConvertFrom-LegacyCoreJson -Stdout $payload -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
        } '' "malformed output must be rejected: $payload"
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui rejects wrong schema command operation and common field types' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $wrongSchema = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $wrongSchema.schemaVersion = 2
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $wrongSchema) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'schema' 'schema mismatch must be rejected'
    foreach ($nonIntegerSchema in @('1.0', '1e0')) {
        $rawSchema = New-LegacyUiCheckDetailJson -OperationId $script:LegacyUiOperationId
        $rawSchema = $rawSchema.Replace('"schemaVersion":1', '"schemaVersion":' + $nonIntegerSchema)
        Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout $rawSchema -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'schema' "non-integer schema $nonIntegerSchema must be rejected"
    }

    $wrongCommand = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $wrongCommand.command = 'status'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $wrongCommand) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'command' 'command mismatch must be rejected'

    $wrongOperation = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $wrongOperation.operationId = '0a20a892-df4d-4c74-bad6-68f854441fe9'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $wrongOperation) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'operation' 'operation echo mismatch must be rejected'

    $stringSuccess = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $stringSuccess.success = 'true'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $stringSuccess) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'success' 'string success must be rejected'

    $emptyCode = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $emptyCode.code = ''
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $emptyCode) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'code' 'empty result codes must be rejected'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui rejects contradictory canLaunch and blocking flags' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson -CanLaunchOverride $false) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'canLaunch' 'canLaunch false with all-ok success must be rejected'

    $contradiction = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson -States @{ dns = @{ status = 'fail'; blocking = $false } } -CanLaunchOverride $true)
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $contradiction) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'blocking|canLaunch' 'a fail marked nonblocking must be rejected'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui renders valid failure rows but never authorizes launch' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $json = New-LegacyUiCheckDetailJson -States @{ dns = @{ status = 'fail'; blocking = $true } } -Success $false
    $result = ConvertFrom-LegacyCoreJson -Stdout $json -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    $presentation = Get-LegacyCheckPresentation -Result $result
    Assert-Equal 14 @($presentation.Checks).Count 'valid failed checks must still render fourteen rows'
    Assert-False $result.TrustedSuccess 'success false must not be trusted as success'
    Assert-False $presentation.CanLaunch 'a failed check result must never enable launch'
    Assert-Equal '检查未通过' $presentation.StatusText 'failed checks must not present as green'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui never trusts nonzero exit even when JSON claims success' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson) -ExitCode 1 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'exit|non-zero|nonzero' 'nonzero exit plus success true must be rejected'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui permits warnings only for ip consistency and ASN' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    foreach ($id in @('ip_consistency', 'asn')) {
        $result = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson -States @{ $id = @{ status = 'warn'; blocking = $false } }) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
        Assert-True $result.CanLaunch "$id warning must remain nonblocking"
    }

    $dns = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson -States @{ dns = @{ status = 'warn'; blocking = $true } }) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    Assert-False $dns.CanLaunch 'a DNS warning must block launch'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson -States @{ dns = @{ status = 'warn'; blocking = $false } } -CanLaunchOverride $true) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId } 'blocking' 'non-allowlisted warnings cannot be marked nonblocking'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui warning presentation stays yellow and never all green' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $result = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson -States @{ asn = @{ status = 'warn'; blocking = $false } }) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    $presentation = Get-LegacyCheckPresentation -Result $result
    $row = @($presentation.Checks | Where-Object { $_.Id -eq 'asn' })[0]
    Assert-Equal '#FFFACC15' $row.Color 'allowed warnings must render yellow'
    Assert-Equal '⚠' $row.Icon 'allowed warnings must use the warning icon'
    Assert-False $presentation.AllGreen 'a warning result must never be presented as all green'
    Assert-Match '警告' $presentation.StatusText 'warning presentation must explicitly mention warnings'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui validates running and recovery metadata' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $active = '0a20a892-df4d-4c74-bad6-68f854441fe9'
    $running = New-LegacyUiStateJson -Phase 'running' -ActiveOperationId $active -TransactionPhase 'copyingToB'
    $parsedRunning = ConvertFrom-LegacyCoreJson -Stdout $running -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId
    Assert-Equal 'running' $parsedRunning.Phase 'running status must be accepted with metadata'
    Assert-Equal $active $parsedRunning.ActiveOperationId 'active operation must be exposed'

    $missingActive = ConvertFrom-LegacyUiJson (New-LegacyUiStateJson -Phase 'running' -ActiveOperationId $active -TransactionPhase 'copyingToB')
    $missingActive.PSObject.Properties.Remove('activeOperationId')
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $missingActive) -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId } 'activeOperationId' 'running without activeOperationId must be rejected'

    $missingPhase = ConvertFrom-LegacyUiJson (New-LegacyUiStateJson -Phase 'running' -ActiveOperationId $active -TransactionPhase 'copyingToB')
    $missingPhase.PSObject.Properties.Remove('transactionPhase')
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $missingPhase) -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId } 'transactionPhase' 'running without transactionPhase must be rejected'

    $mismatch = ConvertFrom-LegacyUiJson (New-LegacyUiStateJson -Phase 'recoveryRequired' -RecoveryRequired $false -ActiveOperationId $active -TransactionPhase 'restoreNeeded')
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $mismatch) -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId } 'recoveryRequired' 'recoveryRequired must equal the phase'

    $idleActive = ConvertFrom-LegacyUiJson (New-LegacyUiStateJson -Phase 'idle' -ActiveOperationId $active -TransactionPhase 'copyingToB')
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $idleActive) -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId } 'idle' 'idle status must not expose an active operation'

    $unknownRecovery = New-LegacyUiStateJson -Phase 'recoveryRequired' -RecoveryRequired $true -ActiveOperationId ([guid]::Empty.ToString('D')) -TransactionPhase 'unverified' -Success $false
    $parsedUnknown = ConvertFrom-LegacyCoreJson -Stdout $unknownRecovery -ExitCode 3 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId
    Assert-Equal ([guid]::Empty.ToString('D')) $parsedUnknown.ActiveOperationId 'the explicit unknown-operation recovery sentinel must be accepted'
    Assert-Equal 'unverified' $parsedUnknown.TransactionPhase 'the unknown recovery phase must remain visible'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui check presentation redacts addresses from displayed detail' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $fixture = ConvertFrom-LegacyUiJson (New-LegacyUiCheckDetailJson)
    $fixture.checks[2].detail = 'egress 203.0.113.42 and 2001:db8::1'
    $result = ConvertFrom-LegacyCoreJson -Stdout (ConvertTo-LegacyUiJson $fixture) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    $presentation = Get-LegacyCheckPresentation -Result $result
    $detail = @($presentation.Checks | Where-Object { $_.Id -eq 'egress_country' })[0].Detail
    Assert-False ($detail -match '203\.0\.113\.42|2001:db8::1') 'displayed details must not expose IP addresses'
    Assert-Match '\[redacted\]' $detail 'redaction must remain visible'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui recovery state is explicit actionable and disables mutations' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $active = '0a20a892-df4d-4c74-bad6-68f854441fe9'
    $result = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson -Current 'B' -Phase 'recoveryRequired' -RecoveryRequired $true -ActiveOperationId $active -TransactionPhase 'restoreNeeded' -Success $false) -ExitCode 3 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId
    $state = Get-LegacyStatusPresentation -Result $result
    Assert-True $state.IsRecovery 'recovery must be an explicit state rather than a generic failure'
    Assert-Equal 'B' $state.CurrentAccount 'a verified current account must remain visible'
    Assert-Equal $active $state.ActiveOperationId 'the active operation must remain visible'
    Assert-Equal 'restoreNeeded' $state.TransactionPhase 'the transaction phase must remain visible'
    Assert-True $state.CanRefresh 'refresh must remain available in recovery'
    Assert-False $state.CanFix 'fix must be disabled in recovery'
    Assert-False $state.CanSwitch 'A/B switching must be disabled in recovery'
    Assert-False $state.CanLaunch 'launch must be disabled in recovery'
    Assert-Match 'Claude\.new' $state.Banner 'recovery guidance must mention Claude.new'
    Assert-Match 'Claude\.previous' $state.Banner 'recovery guidance must mention Claude.previous'
    Assert-Match 'accounts\\A\.new' $state.Banner 'recovery guidance must mention accounts A.new'
    Assert-Match 'accounts\\B\.previous' $state.Banner 'recovery guidance must mention accounts B.previous'
    Assert-Match '不要删除|请勿删除' $state.Banner 'recovery guidance must tell the user to preserve unverified material'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui running state allows observation without mutation or launch' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $active = '0a20a892-df4d-4c74-bad6-68f854441fe9'
    $result = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson -Current 'A' -Phase 'running' -ActiveOperationId $active -TransactionPhase 'copyingToB' -Success $false) -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId
    $state = Get-LegacyStatusPresentation -Result $result
    Assert-True $state.IsRunning 'running must be an explicit observed state'
    Assert-True $state.CanRefresh 'status observation must remain available'
    Assert-False $state.CanFix 'running must disable fix'
    Assert-False $state.CanSwitch 'running must disable A/B'
    Assert-False $state.CanLaunch 'running must disable launch'
    Assert-Match '运行|执行|完成未确认' $state.Banner 'running must explain that completion is not confirmed'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui running switch uses explicit running presentation with operation metadata' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $running = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson -Command 'switch' -Current 'A' -Phase 'running' -ActiveOperationId '0a20a892-df4d-4c74-bad6-68f854441fe9' -TransactionPhase 'copyingToB' -Success $false) -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B'
    $presentation = Get-LegacySwitchPhasePresentation -Result $running
    Assert-True $presentation.IsRunning 'a running switch response must use the running state'
    Assert-False $presentation.IsRecovery 'a running switch must not be mislabeled recovery'
    Assert-Equal '处理中' $presentation.StatusText 'running switch status must be explicit'
    Assert-Equal '0a20a892-df4d-4c74-bad6-68f854441fe9' $presentation.ActiveOperationId 'running switch must retain active operation ID'
    Assert-Equal 'copyingToB' $presentation.TransactionPhase 'running switch must retain transaction phase'
    Assert-True $presentation.CanRefresh 'running switch must permit status observation'
    Assert-False $presentation.CanFix 'running switch must disable fix'
    Assert-False $presentation.CanSwitch 'running switch must disable A/B switching'
    Assert-False $presentation.CanLaunch 'running switch must disable launch'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui pending check rows replace stale prior green rows' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $rows = New-Object System.Collections.ArrayList
    foreach ($id in $script:LegacyUiCheckIds) {
        [void]$rows.Add([pscustomobject]@{ Id = $id; Name = "old-$id"; Detail = 'old green result'; Icon = '✓'; Color = '#FF22C55E' })
    }
    Set-LegacyPendingCheckRows -Rows $rows -Names $script:LegacyUiCheckIds
    Assert-Equal 14 $rows.Count 'pending replacement must preserve the fourteen-row grid'
    Assert-Equal ($script:LegacyUiCheckIds -join '|') (@($rows | ForEach-Object { $_.Id }) -join '|') 'pending rows must retain check order'
    Assert-True (@($rows | Where-Object { $_.Icon -eq '…' -and $_.Color -eq '#FF6B7280' -and -not $_.Detail }).Count -eq 14) 'all prior green details and accents must be cleared'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui switch handler renders running response without a fresh check or mutation' {
    $running = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson -Command 'switch' -Phase 'running' -Success $false -ActiveOperationId $script:LegacyUiOperationId -TransactionPhase 'copyingToB') -ExitCode 2 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B'
    Invoke-LegacyUiHandlerFixture -Responder { param($command) [pscustomobject]@{ TimedOut = $false; Result = $running } } -Action {
        Switch-To 'B'
        Assert-Equal '处理中' $controls.StatusText.Text 'the click handler must use explicit running presentation'
        Assert-Match $script:LegacyUiOperationId $controls.ActionHint.Text 'the operation ID must be rendered'
        Assert-Match 'copyingToB' $controls.ActionHint.Text 'the transaction phase must be rendered'
        Assert-Equal 'switch' ($calls -join '|') 'a running switch must not start another command'
        Assert-True $controls.BtnRefresh.IsEnabled 'observation must remain available'
        Assert-False $controls.BtnA.IsEnabled 'switch A must remain disabled'
        Assert-False $controls.BtnB.IsEnabled 'switch B must remain disabled'
        Assert-False $controls.BtnFix.IsEnabled 'fix must remain disabled'
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui malformed post-switch result clears old rows and retains completed target' {
    $completed = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson -Command 'switch' -Current 'B' -Phase 'completed') -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B'
    Invoke-LegacyUiHandlerFixture -Responder {
        param($command)
        if ($command -eq 'checkdetail') { throw 'synthetic malformed JSON' }
        [pscustomobject]@{ TimedOut = $false; Result = $completed }
    } -Action {
        Switch-To 'B'
        Assert-Equal 'B' $controls.CurrentAccount.Text 'the verified completed target must be retained'
        Assert-Equal 14 $rows.Count 'all check rows must remain visible'
        Assert-Equal 14 @($rows | Where-Object { $_.Icon -eq '…' -and $_.Blocking -and -not $_.Detail }).Count 'no stale green detail may survive malformed fresh checks'
        Assert-True $controls.BtnRefresh.IsEnabled 'retry must be possible'
        Assert-False $controls.BtnFix.IsEnabled 'malformed evidence must not authorize fix'
        Assert-False $controls.BtnB.IsEnabled 'malformed evidence must not authorize switching'
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui refresh handler stops after unavailable status timeout' {
    Invoke-LegacyUiHandlerFixture -Responder { param($command) [pscustomobject]@{ TimedOut = $true; Result = $null } } -Action {
        Refresh-Checks
        Assert-Equal '状态不可用' $controls.StatusText.Text 'a killed status query is not a running transaction'
        Assert-Match '状态查询.*超时' $controls.Banner.Text 'the actual timeout must be identified'
        Assert-Equal 'status' ($calls -join '|') 'unavailable transaction status must stop checks'
        Assert-Equal '' $controls.ActionHint.Text 'unknown status must not invent operation metadata'
        Assert-False $controls.BtnFix.IsEnabled 'unknown transaction state must disable mutations'
        Assert-False $controls.BtnA.IsEnabled 'unknown transaction state must disable switches'
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui refresh replaces placeholders with exactly fourteen fresh rows' {
    $statusResult = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson) -ExitCode 0 -ExpectedCommand 'status' -ExpectedOperationId $script:LegacyUiOperationId
    $checkResult = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    Invoke-LegacyUiHandlerFixture -Responder {
        param($command)
        [pscustomobject]@{ TimedOut = $false; Result = $(if ($command -eq 'status') { $statusResult } else { $checkResult }) }
    } -Action {
        Refresh-Checks
        Assert-Equal 14 $rows.Count 'fresh results must replace rather than append to placeholders'
        Assert-Equal 14 @($rows | Where-Object { $_.Icon -eq '✓' }).Count 'all fourteen rows must be current results'
    }
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui completed switch requires exit zero success completed target and fresh check' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $completedJson = New-LegacyUiStateJson -Command 'switch' -Current 'B' -Phase 'completed'
    $completed = ConvertFrom-LegacyCoreJson -Stdout $completedJson -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B'
    Assert-True (Test-LegacySwitchCompletion -Result $completed -Target 'B') 'a strict completed switch must pass the completion gate'
    Assert-False (Test-LegacySwitchReady -SwitchResult $completed -Target 'B' -FreshCheckResult $null) 'completed switch without a fresh check must not be ready'

    $fresh = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    Assert-True (Test-LegacySwitchReady -SwitchResult $completed -Target 'B' -FreshCheckResult $fresh) 'completed switch with a fresh all-ok check may become ready'

    $blockedFresh = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiCheckDetailJson -States @{ dns = @{ status = 'fail'; blocking = $true } }) -ExitCode 0 -ExpectedCommand 'checkdetail' -ExpectedOperationId $script:LegacyUiOperationId
    Assert-False (Test-LegacySwitchReady -SwitchResult $completed -Target 'B' -FreshCheckResult $blockedFresh) 'a blocked fresh check must keep switch completion non-ready'

    $running = ConvertFrom-LegacyCoreJson -Stdout (New-LegacyUiStateJson -Command 'switch' -Current 'A' -Phase 'running' -ActiveOperationId '0a20a892-df4d-4c74-bad6-68f854441fe9' -TransactionPhase 'copyingToB' -Success $false) -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B'
    Assert-False (Test-LegacySwitchCompletion -Result $running -Target 'B') 'running switch results must not count as completed'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui rejects wrong-current switch and nonzero success claims' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $wrongCurrent = New-LegacyUiStateJson -Command 'switch' -Current 'A' -Phase 'completed'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout $wrongCurrent -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B' } 'current|target' 'completed switch must report the requested target'

    $successAtNonzero = New-LegacyUiStateJson -Command 'switch' -Current 'B' -Phase 'completed'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout $successAtNonzero -ExitCode 1 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B' } 'exit|non-zero|nonzero' 'nonzero switch output must never be trusted as success'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui completed state permits optional metadata while switch completion stays strict' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $active = '0a20a892-df4d-4c74-bad6-68f854441fe9'
    $lingering = New-LegacyUiStateJson -Command 'switch' -Current 'B' -Phase 'completed' -ActiveOperationId $active -TransactionPhase 'cleanup'
    $completed = ConvertFrom-LegacyCoreJson -Stdout $lingering -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B'
    Assert-True (Test-LegacySwitchCompletion -Result $completed -Target 'B') 'completed results may retain optional metadata without invalidating a verified switch'

    $unknownCurrent = New-LegacyUiStateJson -Command 'switch' -Current 'none' -Phase 'completed'
    Assert-LegacyUiThrows { ConvertFrom-LegacyCoreJson -Stdout $unknownCurrent -ExitCode 0 -ExpectedCommand 'switch' -ExpectedOperationId $script:LegacyUiOperationId -Target 'B' } 'current|target' 'completed switch requires the requested current account'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui process startup failure is untrusted and does not crash the UI helper' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $invocation = New-LegacyCoreInvocation -Command 'status' -CorePath 'C:\synthetic\claude-switch.ps1' -OperationId $script:LegacyUiOperationId
    $result = Invoke-LegacyUiProcess -Invocation $invocation -TimeoutPolicy (Get-LegacyUiTimeoutPolicy 'status') -ProcessFactory { throw 'synthetic start failure' }
    Assert-True $result.StartFailed 'process startup failure must be explicit'
    Assert-False $result.TimedOut 'process startup failure is not a timeout'
    Assert-Equal 0 $result.StandardOutput.Length 'startup failure must not synthesize success output'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui operation consumes child JSON rather than last-check cache' {
    if ($script:LegacyUiLoadError) { throw $script:LegacyUiLoadError }
    $script:LegacyUiCapturedInvocation = $null
    $script:LegacyUiCapturedPolicy = $null
    $runner = {
        param($invocation, $policy)
        $script:LegacyUiCapturedInvocation = $invocation
        $script:LegacyUiCapturedPolicy = $policy
        return [pscustomobject]@{
            ExitCode = 0
            StandardOutput = New-LegacyUiCheckDetailJson -OperationId $invocation.OperationId
            StandardError = ''
            TimedOut = $false
            StillRunning = $false
            Killed = $false
        }
    }
    $outcome = Invoke-LegacyCoreOperation -Command 'checkdetail' -CorePath 'C:\synthetic\claude-switch.ps1' -ProcessRunner $runner
    Assert-Equal 'checkdetail' $script:LegacyUiCapturedInvocation.Command 'the operation must pass the fixed command to the process hook'
    Assert-Equal 90 $script:LegacyUiCapturedPolicy.TimeoutSeconds 'checkdetail must use its hard timeout'
    Assert-Equal 14 @($outcome.Result.Checks).Count 'the operation must consume the child JSON result'
    $uiText = Get-Content -LiteralPath $script:LegacyUiPath -Raw
    Assert-False ($uiText -match 'last-check\.txt') 'the UI must not read or trust last-check.txt'
} -Tag 'LegacyUi'

Add-CoreTest 'legacy-ui fix preserves migration guidance without refreshing it away' {
    Invoke-LegacyUiHandlerFixture -Responder {
        param($command, $target)
        if ($command -ne 'fix') { throw 'Unexpected refresh after rejected fix.' }
        [pscustomobject]@{
            TimedOut = $false
            Result = [pscustomobject]@{
                TrustedSuccess = $false; Success = $false; ExitCode = 5
                Code = 'migration-required'; Phase = $null
                Message = '检测到旧版保镖，请运行配置向导完成受保护迁移。'
            }
        }
    } -Action {
        Invoke-LegacyFixAction
        Assert-Match '受保护迁移' $controls.Banner.Text 'the core migration guidance must remain visible'
        Assert-Equal 'fix' (@($calls) -join ',') 'failed fix must not immediately refresh away its guidance'
        Assert-True $controls.BtnRefresh.IsEnabled 'status can be refreshed explicitly'
        Assert-False $controls.BtnA.IsEnabled 'migration cannot authorize account launch'
        Assert-False $controls.BtnB.IsEnabled 'migration cannot authorize account launch'
        Assert-Equal 0 @($rows | Where-Object { $_.Icon -eq '✓' }).Count 'failed fix clears stale green checks'
    }
} -Tag 'LegacyUi'
