# Claude 账号切换器 - Windows 核心脚本
# 用法: powershell -NoProfile -File claude-switch.ps1 check|status|switch A|B|checkdetail|fix|check-update|update-now
param([Parameter(Position=0)][string]$Command, [Parameter(Position=1)][string]$Target, [switch]$Json, [string]$OperationId)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============ 安装时可配置项(安装器自动改写) ============
$PROXY_MODE = "clash-verge"            # 代理客户端: clash-verge|sing-box|clashx|surge|wireguard|other|auto
$COUNTRY_TARGET = "US"                 # 目标出口国家(安装时按出口自动识别)
$TZ_TARGET = "Eastern Standard Time"   # Windows 时区ID
$PROXY_GROUP = "GLOBAL"                # Clash 代理组名
$LOCALE_TARGET = "en-US"               # 旧版默认值；版本化用户配置会覆盖
# =======================================================

$BASE = Join-Path $env:USERPROFILE ".claude-switcher"
$DATA = Join-Path $env:APPDATA "Claude"
$LOG  = Join-Path $BASE "claude-switch.log"
$CLASH_DIR = @(
    (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
    (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $CLASH_DIR) { $CLASH_DIR = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev" }

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $(Protect-CoreText ([string]$m))" | Out-File -Append -Encoding utf8 $LOG }

function Import-CoreConfiguration {
    # Configuration is data, never dot-sourced or interpolated into executable code.
    $path = Join-Path $BASE 'config.json'
    if (-not (Test-Path -LiteralPath $path)) {
        $script:CoreConfigurationKind='Legacy'
        return $true
    }
    $script:CoreConfigurationKind='Invalid'
    try {
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -gt 65536 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        $config = [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -is [array]) { return $false }
        $fields = @('schemaVersion','proxyMode','proxyGroup','country','timeZoneId','culture')
        $properties = @($config.PSObject.Properties)
        if ($properties.Count -ne $fields.Count) { return $false }
        foreach ($property in $properties) { if ($fields -cnotcontains $property.Name) { return $false } }
        if ($config.schemaVersion -isnot [int] -and $config.schemaVersion -isnot [long]) { return $false }
        if ($config.schemaVersion -ne 1) { return $false }
        foreach ($field in @('proxyMode','proxyGroup','country','timeZoneId','culture')) {
            if ($config.$field -isnot [string]) { return $false }
        }
        if ($config.proxyMode -cnotin @('auto','clash-verge','sing-box','clashx','surge','wireguard','other')) { return $false }
        $group = $config.proxyGroup
        if ($group.Length -gt 128 -or $group -match '[\x00-\x1f\x7f;`$"''<>|&{}\\/]' -or $group.Contains('..')) { return $false }
        if ($config.proxyMode -eq 'clash-verge' -and [string]::IsNullOrWhiteSpace($group)) { return $false }
        $cultures = @{ US='en-US'; JP='ja-JP'; TW='zh-TW'; HK='zh-HK'; SG='en-SG'; GB='en-GB'; DE='de-DE'; FR='fr-FR'; KR='ko-KR'; AU='en-AU'; CA='en-CA' }
        if ($config.country -cnotmatch '^[A-Z]{2}$' -or -not $cultures.ContainsKey($config.country) -or $config.culture -cne $cultures[$config.country]) { return $false }
        if ($config.timeZoneId.Length -gt 128 -or $config.timeZoneId -notmatch '^[A-Za-z0-9 .()+-]+$') { return $false }
        $null = [TimeZoneInfo]::FindSystemTimeZoneById($config.timeZoneId)
        $null = [Globalization.CultureInfo]::GetCultureInfo($config.culture)
        # Apply only after the whole record validates, so partial records cannot mix targets.
        $script:PROXY_MODE = $config.proxyMode
        $script:PROXY_GROUP = $group
        $script:COUNTRY_TARGET = $config.country
        $script:TZ_TARGET = $config.timeZoneId
        $script:LOCALE_TARGET = $config.culture
        $script:CoreConfigurationKind='Native'
        return $true
    } catch { $script:CoreConfigurationKind='Invalid'; return $false }
}

function Get-CoreCallerIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $sid = $identity.User.Value
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        if ($sid -cnotmatch '^S-1-(?:5-21|12-1)(?:-[0-9]+){4}$' -or $session -le 0) { throw '普通用户交互会话不可确认' }
        return [pscustomobject]@{ Sid=$sid; SessionId=$session }
    } finally { $identity.Dispose() }
}

function Test-UnsafeWindowsAllow([string]$Sid, $Rights, $PropagationFlags) {
    if ($PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { return $false }
    if ($Sid -in @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')) { return $false }
    $mutation=[Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor [Security.AccessControl.FileSystemRights]::WriteAttributes -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    $bits=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Rights),0)
    return [bool](($Rights -band $mutation) -or ($bits -band [uint32]0x50000000))
}

function Test-ProtectedWindowsPath([string]$Path, [string]$ProgramFiles) {
    try {
        $full=[IO.Path]::GetFullPath($Path)
        $boundary=[IO.Path]::GetFullPath($ProgramFiles).TrimEnd('\')
        if (-not $full.StartsWith($boundary+'\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
        $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        $cursor=$full
        while ($true) {
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            $acl=Get-Acl -LiteralPath $cursor -ErrorAction Stop
            if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
            foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -eq 'Allow' -and (Test-UnsafeWindowsAllow $rule.IdentityReference.Value $rule.FileSystemRights $rule.PropagationFlags)) { return $false }
            }
            if ($cursor.TrimEnd('\').Equals($boundary,[StringComparison]::OrdinalIgnoreCase)) { break }
            $cursor=Split-Path -Parent $cursor
        }
        return $true
    } catch { return $false }
}

function Get-ProtectedWindowsPayload([switch]$ForElevation) {
    $programFiles=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $root=Join-Path $programFiles 'ClaudeSwitcher'
    $helper=Join-Path $root 'helpers\ClaudeSwitcher.Admin.exe'
    $bodyguard=Join-Path $root 'scripts\claude-bodyguard.ps1'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf) -or -not (Test-Path -LiteralPath $bodyguard -PathType Leaf)) { return $null }
    foreach($path in @($helper,$bodyguard,(Join-Path $root 'scripts\claude-switch.ps1'))) {
        if (-not (Test-ProtectedWindowsPath $path $programFiles)) { return $null }
    }
    # The self-contained helper loads its own runtime; writable dependency files are unsafe too.
    if ($ForElevation) {
        foreach($file in @(Get-ChildItem -LiteralPath (Split-Path $helper -Parent) -File -Recurse -Force -ErrorAction Stop)) {
            if (-not (Test-ProtectedWindowsPath $file.FullName $programFiles)) { return $null }
        }
    }
    return [pscustomobject]@{ Root=$root; Helper=$helper; Script=$bodyguard; PowerShell=(Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'WindowsPowerShell\v1.0\powershell.exe') }
}

function Invoke-ProtectedBodyguardMigration {
    try {
        $payload=Get-ProtectedWindowsPayload -ForElevation
        if ($null -eq $payload) { return 1 }
        $caller=Get-CoreCallerIdentity
        $arguments='--operation migrate-legacy-bodyguard --user-sid '+$caller.Sid+' --session-id '+$caller.SessionId
        $helper=Start-Process -FilePath $payload.Helper -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList $arguments -ErrorAction Stop
        if ($helper.ExitCode -eq 0) { return 0 }
        return 1
    } catch {
        $errorObject=$_.Exception
        while ($errorObject) {
            if ($errorObject -is [ComponentModel.Win32Exception] -and $errorObject.NativeErrorCode -eq 1223) { return 4 }
            $errorObject=$errorObject.InnerException
        }
        return 1
    }
}

function Invoke-ProtectedSystemRepair {
    try {
        $payload=Get-ProtectedWindowsPayload -ForElevation
        if ($null -eq $payload) { return 1 }
        $caller=Get-CoreCallerIdentity
        if ($TZ_TARGET -notmatch '^[A-Za-z0-9 .()+-]{1,128}$') { return 1 }
        $null=[TimeZoneInfo]::FindSystemTimeZoneById($TZ_TARGET)
        $arguments='--operation repair-system --user-sid '+$caller.Sid+' --session-id '+$caller.SessionId+' --time-zone-id "'+$TZ_TARGET+'"'
        $helper=Start-Process -FilePath $payload.Helper -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList $arguments -ErrorAction Stop
        if ($helper.ExitCode -eq 0) { return 0 }
        return 1
    } catch {
        $errorObject=$_.Exception
        while ($errorObject) {
            if ($errorObject -is [ComponentModel.Win32Exception] -and $errorObject.NativeErrorCode -eq 1223) { return 4 }
            $errorObject=$errorObject.InnerException
        }
        return 1
    }
}

function Get-BodyguardPowerShellPath {
    $system=[Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    return Join-Path $system 'WindowsPowerShell\v1.0\powershell.exe'
}

function Get-BodyguardArguments([string]$ScriptPath) {
    return '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$ScriptPath+'"'
}

function Get-BodyguardLegacyArguments([string]$ScriptPath) {
    return '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$ScriptPath+'"'
}

function Get-BodyguardAccountSid([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -cmatch '^S-1-(?:5-21|12-1)(?:-[0-9]+){4}$') { return $Value }
    try {
        $account=New-Object -TypeName Security.Principal.NTAccount -ArgumentList $Value
        $sid=$account.Translate([Security.Principal.SecurityIdentifier])
        return $sid.Value
    } catch { return $null }
}

function Get-BodyguardTriggerKind($Trigger) {
    if ($null -eq $Trigger) { return '' }
    try {
        $class=$Trigger.CimClass
        if ($null -ne $class -and -not [string]::IsNullOrEmpty([string]$class.CimClassName)) { return [string]$class.CimClassName }
    } catch {}
    foreach($name in @($Trigger.PSObject.TypeNames)) {
        if ($name -like 'MSFT_Task*Trigger') { return $name }
    }
    return ''
}

function Test-BodyguardLogonTrigger($Trigger, [string]$Sid, [switch]$AllowUnscopedUser) {
    if ((Get-BodyguardTriggerKind $Trigger) -cne 'MSFT_TaskLogonTrigger') { return $false }
    $enabled=$Trigger.PSObject.Properties['Enabled']
    if ($null -eq $enabled -or $enabled.Value -isnot [bool] -or $enabled.Value -ne $true) { return $false }
    $user=$Trigger.PSObject.Properties['UserId']
    if ($null -eq $user) { return [bool]$AllowUnscopedUser }
    if ([string]::IsNullOrWhiteSpace([string]$user.Value)) { return $false }
    $resolved=Get-BodyguardAccountSid ([string]$user.Value)
    return $resolved -ceq $Sid
}

function Get-BodyguardTaskSetting($Settings, [string]$Name) {
    if ($null -eq $Settings) { return $null }
    $property=$Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-BodyguardTaskSetting($Settings, [string]$Name, $Expected) {
    if ($null -eq $Settings) { return $false }
    $property=$Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $false }
    if ($Expected -is [bool]) {
        if ($property.Value -isnot [bool]) { return $false }
        return $property.Value -eq $Expected
    }
    return ([string]$property.Value) -ceq ([string]$Expected)
}

function Test-BodyguardUnlimitedExecution($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [TimeSpan]) { return $Value -eq [TimeSpan]::Zero }
    return ([string]$Value) -ceq 'PT0S'
}

function Test-ProtectedBodyguardTaskSettings($Settings) {
    if (-not (Test-BodyguardTaskSetting $Settings 'Enabled' $true)) { return $false }
    if (-not (Test-BodyguardTaskSetting $Settings 'AllowDemandStart' $true)) { return $false }
    if (-not (Test-BodyguardTaskSetting $Settings 'MultipleInstances' 'IgnoreNew')) { return $false }
    if (-not (Test-BodyguardTaskSetting $Settings 'DisallowStartIfOnBatteries' $false)) { return $false }
    if (-not (Test-BodyguardTaskSetting $Settings 'StopIfGoingOnBatteries' $false)) { return $false }
    $limit=$Settings.PSObject.Properties['ExecutionTimeLimit']
    if ($null -eq $limit) { return $false }
    return Test-BodyguardUnlimitedExecution $limit.Value
}

function Test-BodyguardOwnedFile([string]$Path, [string]$Sid, [long]$MaxBytes) {
    try {
        $item=Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $item -or $item.PSIsContainer -or $item.Length -gt $MaxBytes -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($null -eq $acl) { return $false }
        $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        return $owner -ceq $Sid
    } catch { return $false }
}

function Get-BodyguardTaskLastRunTime($Task) {
    $info=Get-ScheduledTaskInfo -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
    if ($null -eq $info) { throw 'Scheduled task run time is unavailable.' }
    $property=$info.PSObject.Properties['LastRunTime']
    if ($null -eq $property -or $null -eq $property.Value) { throw 'Scheduled task run time is unavailable.' }
    $value=$property.Value
    $lastRun=if ($value -is [DateTime]) { [DateTimeOffset]$value } elseif ($value -is [DateTimeOffset]) { $value } else { [DateTimeOffset]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture) }
    if ($lastRun -le [DateTimeOffset]::MinValue.AddDays(1)) { throw 'Scheduled task has no verified run instance.' }
    return $lastRun
}

function Test-BodyguardProcessMatchesRun($Process, [DateTimeOffset]$LastRunTime) {
    if ($null -eq $Process) { return $false }
    $startProperty=$Process.PSObject.Properties['StartTime']
    if ($null -eq $startProperty -or $null -eq $startProperty.Value) { return $false }
    try { $start=[DateTimeOffset]$startProperty.Value } catch { return $false }
    $offset=($start-$LastRunTime).TotalSeconds
    return $offset -ge -15 -and $offset -le 60
}

function Test-BodyguardCimOwner($Info, [string]$Sid) {
    if ($null -eq $Info) { return $false }
    try {
        $owner=Invoke-CimMethod -InputObject $Info -MethodName GetOwnerSid -ErrorAction Stop
        return $null -ne $owner -and $owner.ReturnValue -eq 0 -and -not [string]::IsNullOrEmpty([string]$owner.Sid) -and ([string]$owner.Sid) -ceq $Sid
    } catch { return $false }
}

function Test-BodyguardPrincipal($Principal, $Caller) {
    if ($null -eq $Principal -or $null -eq $Caller) { return $false }
    $user=$Principal.PSObject.Properties['UserId']
    $runLevel=$Principal.PSObject.Properties['RunLevel']
    $logonType=$Principal.PSObject.Properties['LogonType']
    if ($null -eq $user -or $null -eq $runLevel -or $null -eq $logonType) { return $false }
    $resolved=Get-BodyguardAccountSid ([string]$user.Value)
    if ($resolved -cne $Caller.Sid) { return $false }
    if ([string]$runLevel.Value -cnotin @('Limited','LeastPrivilege')) { return $false }
    return [string]$logonType.Value -cin @('Interactive','InteractiveToken')
}

function Test-ProtectedBodyguardTask($Task, $Caller, $Payload) {
    if ($null -eq $Task -or $null -eq $Caller -or $null -eq $Payload) { return $false }
    $name='ClaudeSwitcher.Bodyguard.'+$Caller.Sid
    $arguments=Get-BodyguardArguments $Payload.Script
    if ([string]$Task.TaskName -cne $name -or [string]$Task.TaskPath -cne '\' -or [string]$Task.State -notin @('Running','4')) { return $false }
    if (-not (Test-BodyguardPrincipal $Task.Principal $Caller)) { return $false }
    if (-not (Test-ProtectedBodyguardTaskSettings $Task.Settings)) { return $false }
    if (@($Task.Actions).Count -ne 1 -or @($Task.Triggers).Count -ne 1) { return $false }
    if (-not (Test-BodyguardLogonTrigger $Task.Triggers[0] $Caller.Sid)) { return $false }
    if ([string]$Task.Actions[0].Execute -ine $Payload.PowerShell -or [string]$Task.Actions[0].Arguments -cne $arguments) { return $false }
    $lastRun=Get-BodyguardTaskLastRunTime $Task
    $path=Join-Path $BASE 'bodyguard-heartbeat.json'
    if (-not (Test-BodyguardOwnedFile $path $Caller.Sid 4096)) { return $false }
    $heartbeat=[IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $heartbeat -or $heartbeat -is [array]) { return $false }
    foreach($field in @('schemaVersion','userSid','sessionId','processId','updatedAt')) {
        if ($null -eq $heartbeat.PSObject.Properties[$field]) { return $false }
    }
    if ($heartbeat.schemaVersion -ne 1 -or $heartbeat.userSid -cne $Caller.Sid -or $heartbeat.sessionId -ne $Caller.SessionId -or ($heartbeat.processId -isnot [int] -and $heartbeat.processId -isnot [long]) -or $heartbeat.processId -le 0 -or $heartbeat.processId -gt [int]::MaxValue) { return $false }
    # PowerShell 7.6 materializes ISO JSON timestamps as DateTime; 5.1 keeps strings.
    $updated=if ($heartbeat.updatedAt -is [DateTime]) { [DateTimeOffset]$heartbeat.updatedAt } else { [DateTimeOffset]::ParseExact($heartbeat.updatedAt,'o',[Globalization.CultureInfo]::InvariantCulture) }
    $age=([DateTimeOffset]::UtcNow-$updated).TotalSeconds
    if ($age -lt -5 -or $age -gt 45) { return $false }
    $process=Get-Process -Id $heartbeat.processId -ErrorAction Stop
    if ($null -eq $process -or $process.Id -ne $heartbeat.processId -or $process.SessionId -ne $Caller.SessionId -or $process.Path -ine $Payload.PowerShell) { return $false }
    if (-not (Test-BodyguardProcessMatchesRun $process $lastRun)) { return $false }
    $infos=@(Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId='+$heartbeat.processId) -ErrorAction Stop)
    if ($infos.Count -ne 1 -or -not (Test-BodyguardCimOwner $infos[0] $Caller.Sid)) { return $false }
    $command=[string]$infos[0].CommandLine
    return $command -ieq ('"'+$Payload.PowerShell+'" '+$arguments) -or $command -ieq ($Payload.PowerShell+' '+$arguments)
}

function Get-BodyguardExactTasks([string]$TaskName) {
    return @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object {
        [string]$_.TaskName -ceq $TaskName -and [string]$_.TaskPath -ceq '\'
    })
}

function Get-LegacyBodyguardTask {
    try {
        $tasks=@(Get-BodyguardExactTasks 'ClaudeBodyguard')
        if ($tasks.Count -ne 1) { return $null }
        return $tasks[0]
    } catch { return $null }
}

function Test-LegacyBodyguardTask($Task, $Caller, [string]$PowerShellPath) {
    if ($null -eq $Task -or $null -eq $Caller -or [string]::IsNullOrWhiteSpace($PowerShellPath)) { return $false }
    if ([string]$Task.TaskName -cne 'ClaudeBodyguard' -or [string]$Task.TaskPath -cne '\' -or [string]$Task.State -cnotin @('Running','4')) { return $false }
    if (-not (Test-BodyguardPrincipal $Task.Principal $Caller)) { return $false }
    if (-not (Test-ProtectedBodyguardTaskSettings $Task.Settings)) { return $false }
    if (@($Task.Actions).Count -ne 1 -or @($Task.Triggers).Count -ne 1) { return $false }
    if (-not (Test-BodyguardLogonTrigger $Task.Triggers[0] $Caller.Sid -AllowUnscopedUser)) { return $false }
    $scriptPath=Join-Path $BASE 'claude-bodyguard.ps1'
    $arguments=Get-BodyguardLegacyArguments $scriptPath
    $execute=[string]$Task.Actions[0].Execute
    if ($execute -ine 'powershell.exe' -and $execute -ine $PowerShellPath) { return $false }
    if ([string]$Task.Actions[0].Arguments -cne $arguments) { return $false }
    if (-not (Test-BodyguardOwnedFile $scriptPath $Caller.Sid 1048576)) { return $false }
    $lastRun=Get-BodyguardTaskLastRunTime $Task
    $expectedCommands=@(
        ('"{0}" {1}' -f $PowerShellPath,$arguments),
        ('{0} {1}' -f $PowerShellPath,$arguments),
        ('"powershell.exe" {0}' -f $arguments),
        ('powershell.exe {0}' -f $arguments)
    )
    $candidateCount=0
    $matches=@()
    foreach($info in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)) {
        if ($null -eq $info) { continue }
        $command=[string]$info.CommandLine
        # Windows executable paths are case-insensitive; the full command remains exact otherwise.
        if (-not @($expectedCommands | Where-Object { $_ -ieq $command }).Count) { continue }
        $candidateCount++
        try { $process=Get-Process -Id $info.ProcessId -ErrorAction Stop } catch { return $false }
        if ($null -eq $process -or $process.Id -ne $info.ProcessId -or $process.SessionId -ne $Caller.SessionId -or $process.Path -ine $PowerShellPath) { return $false }
        if (-not (Test-BodyguardCimOwner $info $Caller.Sid)) { return $false }
        if (Test-BodyguardProcessMatchesRun $process $lastRun) { $matches += $process }
    }
    return $candidateCount -eq 1 -and @($matches).Count -eq 1
}

function Get-BodyguardTaskAssessment {
    $caller=Get-CoreCallerIdentity
    $kind=[string]$script:CoreConfigurationKind
    if ($kind -notin @('Legacy','Native','Invalid')) {
        $configured=Import-CoreConfiguration
        $kind=[string]$script:CoreConfigurationKind
        if ($kind -notin @('Legacy','Native','Invalid')) {
            if ($configured) {
                if (Test-Path -LiteralPath (Join-Path $BASE 'config.json')) { $kind='Native' } else { $kind='Legacy' }
            } else { $kind='Invalid' }
        }
    }
    if ($kind -eq 'Invalid') { return [pscustomobject]@{ Kind='Invalid'; Task=$null; Reason='configuration-invalid' } }
    $protectedName='ClaudeSwitcher.Bodyguard.'+$caller.Sid
    try { $protectedTasks=@(Get-BodyguardExactTasks $protectedName) } catch { return [pscustomobject]@{ Kind='Invalid'; Task=$null; Reason='protected-task-query-failed' } }
    if ($protectedTasks.Count -gt 1) { return [pscustomobject]@{ Kind='Invalid'; Task=$null; Reason='duplicate-protected-task' } }
    if ($protectedTasks.Count -eq 1) {
        $payload=$null
        try { $payload=Get-ProtectedWindowsPayload } catch {}
        if ($null -ne $payload -and (Test-ProtectedBodyguardTask $protectedTasks[0] $caller $payload)) {
            return [pscustomobject]@{ Kind='Protected'; Task=$protectedTasks[0]; Reason='verified' }
        }
        return [pscustomobject]@{ Kind='Invalid'; Task=$protectedTasks[0]; Reason='protected-task-invalid' }
    }
    if ($kind -ne 'Legacy') { return [pscustomobject]@{ Kind='Invalid'; Task=$null; Reason='legacy-not-allowed' } }
    try { $legacyTasks=@(Get-BodyguardExactTasks 'ClaudeBodyguard') } catch { return [pscustomobject]@{ Kind='Invalid'; Task=$null; Reason='legacy-task-query-failed' } }
    if ($legacyTasks.Count -eq 0) { return [pscustomobject]@{ Kind='Invalid'; Task=$null; Reason='bodyguard-task-missing' } }
    if ($legacyTasks.Count -ne 1) { return [pscustomobject]@{ Kind='LegacyMigration'; Task=$null; Reason='duplicate-legacy-task' } }
    if (Test-LegacyBodyguardTask $legacyTasks[0] $caller (Get-BodyguardPowerShellPath)) {
        return [pscustomobject]@{ Kind='Legacy'; Task=$legacyTasks[0]; Reason='verified-legacy' }
    }
    return [pscustomobject]@{ Kind='LegacyMigration'; Task=$legacyTasks[0]; Reason='legacy-task-invalid' }
}

function Test-BodyguardHealth {
    try { return (Get-BodyguardTaskAssessment).Kind -in @('Protected','Legacy') } catch { return $false }
}
function Test-SystemRepairRequired {
    if ((Get-TimeZone).Id -ne $TZ_TARGET) { return $true }
    if (@(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true }).Count -gt 0) { return $true }
    return -not (Test-BodyguardHealth) -or -not (Test-DNS)
}

function Test-DNS {
    try {
        $addresses=@(Resolve-DnsName claude.ai -Type A -ErrorAction Stop | Where-Object { $_.IPAddress })
        return $addresses.Count -gt 0 -and @($addresses | Where-Object { $_.IPAddress -notlike '198.18.*' }).Count -eq 0
    } catch { return $false }
}

function Get-OwnedClaudeProcesses {
    $caller=Get-CoreCallerIdentity
    foreach($process in @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) {
        if ($process.SessionId -ne $caller.SessionId) { continue }
        $info=Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId='+$process.Id) -ErrorAction Stop
        $owner=Invoke-CimMethod -InputObject $info -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrEmpty($owner.Sid)) { throw '无法验证 Claude 进程归属' }
        if ($owner.Sid -eq $caller.Sid) { $process }
    }
}

# 当前安装版本(安装器/更新器写入 version.txt,缺失视为 unknown)
function Get-AppVersion {
    $vf = Join-Path $BASE "version.txt"
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

# 版本号按 . 分段比较,每段只取前导数字(忽略 -beta 等后缀);unknown 视为最旧
function ConvertTo-VersionParts([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return @() }
    $clean = $v.Trim().TrimStart('v', 'V')
    if ($clean -eq 'unknown') { return @() }
    return @($clean.Split('.'))
}

function Compare-Version([string]$a, [string]$b) {
    $pa = @(ConvertTo-VersionParts $a)
    $pb = @(ConvertTo-VersionParts $b)
    $ua = ($pa.Count -eq 0)
    $ub = ($pb.Count -eq 0)
    if ($ua -and $ub) { return 0 }
    if ($ua) { return -1 }
    if ($ub) { return 1 }
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $na = 0; $nb = 0
        if ($i -lt $pa.Count) {
            $m = [regex]::Match([string]$pa[$i], '^\d+')
            if ($m.Success) { $na = [int64]$m.Value }
        }
        if ($i -lt $pb.Count) {
            $m = [regex]::Match([string]$pb[$i], '^\d+')
            if ($m.Success) { $nb = [int64]$m.Value }
        }
        if ($na -lt $nb) { return -1 }
        if ($na -gt $nb) { return 1 }
    }
    return 0
}

# 只允许从 GitHub 官方域名下载更新资产
function Test-GitHubDownloadUrl([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return $false }
    try { $u = [Uri]$url } catch { return $false }
    if ($u.Scheme -ne 'https') { return $false }
    $allowed = @('github.com', 'api.github.com', 'objects.githubusercontent.com',
                 'github-releases.githubusercontent.com', 'codeload.github.com')
    return ($allowed -contains $u.Host.ToLowerInvariant())
}

function Get-ScriptConfigValue([string]$text, [string]$name) {
    $m = [regex]::Match($text, '(?m)^[ \t]*\$' + [regex]::Escape($name) + '[ \t]*=[ \t]*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Set-ScriptConfigValue([string]$text, [string]$name, [string]$value) {
    $pattern = '(?m)^([ \t]*\$' + [regex]::Escape($name) + '[ \t]*=[ \t]*")[^"]*(")'
    $replacement = '${1}' + $value.Replace('$', '$$') + '${2}'
    return [regex]::Replace($text, $pattern, $replacement)
}

# 代理客户端显示名(供检查细节输出)
function Get-ProxyName {
    switch ($PROXY_MODE) {
        'clash-verge' { return 'Clash Verge' }
        'sing-box'    { return 'sing-box' }
        'clashx'      { return 'ClashX' }
        'surge'       { return 'Surge' }
        'wireguard'   { return 'WireGuard' }
        'other'       { return '其他代理客户端' }
        'auto'        { return '代理客户端(auto)' }
        default       { return $PROXY_MODE }
    }
}

# 代理客户端在线判定:按安装时识别的客户端分派;auto 任一命中即活,other 只依赖 TUN
function Test-ProxyAlive {
    switch ($PROXY_MODE) {
        'clash-verge' { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
        'sing-box'    { return [bool](Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) }
        'clashx'      { return [bool](Get-Process -Name 'ClashX' -ErrorAction SilentlyContinue) }
        'surge'       { return [bool](Get-Process -Name 'Surge' -ErrorAction SilentlyContinue) }
        'wireguard'   { return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') }
        'other'       { return $true }
        'auto' {
            if (Get-Process -Name 'verge-mihomo','sing-box','ClashX','Surge' -ErrorAction SilentlyContinue) { return $true }
            return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
        }
        default { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
    }
}

# TUN 在线判定:198.18 假IP段优先,否则回退到任意 Up 状态的虚拟网卡(兼容 Astrill/WireGuard/OpenVPN 等)
function Get-TunStatus {
    if (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '198.18.*' }) {
        return @{ up = $true; detail = '198.18 假IP段' }
    }
    $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'TAP|TUN|WireGuard|Wintun|VPN|Tailscale') }
    if ($nic) { return @{ up = $true; detail = '通用虚拟网卡' } }
    return @{ up = $false; detail = '不在线' }
}
function Test-TunUp {
    $t = Get-TunStatus
    return [bool]$t.up
}

function Get-Egress {
    $trace = & curl.exe -s --max-time 8 "https://www.cloudflare.com/cdn-cgi/trace" 2>$null
    $ip  = (($trace -split "`n" | Where-Object { $_ -like 'ip=*' })  -replace 'ip=','').Trim()
    $loc = (($trace -split "`n" | Where-Object { $_ -like 'loc=*' }) -replace 'loc=','').Trim()
    return @{ ip = $ip; loc = $loc }
}

# STUN 探针(纯 .NET UDP,手工构造 RFC5389 报文)
function Get-StunPublicIP([string]$server, [int]$port, [int]$timeoutMs = 2000) {
    try {
        $addr = ([System.Net.Dns]::GetHostAddresses($server) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1)
        if (-not $addr) { return @{ State = 'no-response'; Ip = $null } }
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $timeoutMs
        try {
            $txn = New-Object byte[] 12
            (New-Object System.Random).NextBytes($txn)
            $req = [byte[]](0x00, 0x01, 0x00, 0x00) + [byte[]](0x21, 0x12, 0xA4, 0x42) + $txn
            $udp.Connect($addr, $port)
            [void]$udp.Send($req, $req.Length)
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$remote)
            if ($null -eq $resp) { return @{ State = 'no-response'; Ip = $null } }
            if ($resp.Length -lt 20 -or $resp[0] -ne 0x01 -or $resp[1] -ne 0x01 -or
                $resp[4] -ne 0x21 -or $resp[5] -ne 0x12 -or $resp[6] -ne 0xA4 -or $resp[7] -ne 0x42) {
                return @{ State = 'malformed'; Ip = $null }
            }
            for ($i = 0; $i -lt 12; $i++) {
                if ($resp[8 + $i] -ne $txn[$i]) { return @{ State = 'malformed'; Ip = $null } }
            }
            $messageLength = ([int]$resp[2] -shl 8) -bor $resp[3]
            if (($messageLength % 4) -ne 0 -or (20 + $messageLength) -ne $resp.Length) {
                return @{ State = 'malformed'; Ip = $null }
            }
            $pos = 20
            while ($pos + 4 -le $resp.Length) {
                $atype = ([int]$resp[$pos] -shl 8) -bor $resp[$pos + 1]
                $alen  = ([int]$resp[$pos + 2] -shl 8) -bor $resp[$pos + 3]
                $next = $pos + 4 + $alen + ((4 - ($alen % 4)) % 4)
                if ($next -gt $resp.Length) { return @{ State = 'malformed'; Ip = $null } }
                if ($atype -eq 0x0020 -and $alen -eq 8 -and $resp[$pos + 5] -eq 0x01) {
                    $ipBytes = @($resp[$pos + 8], $resp[$pos + 9], $resp[$pos + 10], $resp[$pos + 11])
                    $cookie = [byte[]](0x21, 0x12, 0xA4, 0x42)
                    for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] = $ipBytes[$i] -bxor $cookie[$i] }
                    $ip = $ipBytes -join '.'
                    if (-not (Test-IPv4Literal $ip)) { return @{ State = 'malformed'; Ip = $null } }
                    return @{ State = 'response'; Ip = $ip }
                }
                $pos = $next
            }
            return @{ State = 'malformed'; Ip = $null }
        } catch {
            if ($_.Exception -is [System.Net.Sockets.SocketException] -and
                $_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                return @{ State = 'no-response'; Ip = $null }
            }
            return @{ State = 'error'; Ip = $null }
        } finally {
            if ($udp) { $udp.Close() }
        }
    } catch {
        return @{ State = 'error'; Ip = $null }
    }
}

function Get-StunAssessment([string]$ExitIp) {
    if (-not (Test-PublicIPv4Address $ExitIp)) {
        return @{ Ok = $false; Code = 'unknown'; Detail = '当前出口地址无效，无法验证 UDP 暴露' }
    }
    $servers = @(@("stun.miwifi.com", 3478), @("stun.chat.bilibili.com", 3478), @("stun.l.google.com", 19302), @("stun.cloudflare.com", 3478))
    $responses = @()
    $probeError = $false
    foreach ($s in $servers) {
        try { $probe = Get-StunPublicIP $s[0] $s[1] } catch { $probeError = $true; continue }
        if ($probe -is [string]) {
            if (Test-PublicIPv4Address $probe) { $responses += $probe } else { $probeError = $true }
        } elseif ($probe -is [hashtable] -and $probe.State -eq 'response') {
            if (Test-PublicIPv4Address ([string]$probe.Ip)) { $responses += [string]$probe.Ip } else { $probeError = $true }
        } elseif ($probe -is [hashtable] -and $probe.State -in @('error', 'malformed')) {
            $probeError = $true
        }
    }
    if ($responses.Count -eq 0) {
        if ($probeError) { return @{ Ok = $false; Code = 'fail'; Detail = 'STUN 探测异常，无法确认 UDP 暴露状态' } }
        return @{ Ok = $false; Code = 'unknown'; Detail = 'STUN 无响应，无法确认 UDP 暴露状态' }
    }
    $mismatch = @($responses | Where-Object { $_ -ne $ExitIp })
    if ($mismatch.Count -gt 0) {
        return @{ Ok = $false; Code = 'fail'; Detail = 'STUN 观察到与当前出口不一致的公网地址' }
    }
    return @{ Ok = $true; Code = 'ok'; Detail = 'STUN 响应与当前代理出口一致' }
}

function Test-IPv4Literal([string]$Value) {
    $address = $null
    if ($Value -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') { return $false }
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address)) { return $false }
    return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-PublicIPv4Address([string]$Value) {
    if (-not (Test-IPv4Literal $Value)) { return $false }
    $b = [System.Net.IPAddress]::Parse($Value).GetAddressBytes()
    # IANA IPv4 Special-Purpose Address Registry (checked 2026-10-27):
    # https://www.iana.org/assignments/iana-ipv4-special-registry/
    # Reject non-global/reserved source ranges, including multicast; no DNS/network lookup.
    if ($b[0] -in @(0, 10, 127) -or $b[0] -ge 224) { return $false }
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
    if ($b[0] -eq 192) {
        if ($b[1] -eq 0 -and $b[2] -eq 0) { return $b[3] -in @(9, 10) }
        if (($b[1] -eq 0 -and $b[2] -eq 2) -or ($b[1] -eq 88 -and $b[2] -eq 99) -or $b[1] -eq 168) { return $false }
    }
    if ($b[0] -eq 198 -and ($b[1] -in @(18, 19) -or ($b[1] -eq 51 -and $b[2] -eq 100))) { return $false }
    if ($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113) { return $false }
    return $true
}

function Test-WebRTC($exitIp) {
    $assessment = Get-StunAssessment -ExitIp $exitIp
    return @{ code = $assessment.Code; detail = $assessment.Detail }
}

function Find-ClashVerge {
    # 优先取正在运行进程的真实路径(最可靠),再回退到常见安装目录
    $running = Get-Process -Name 'clash-verge','Clash Verge' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path } | Select-Object -First 1
    if ($running) { return $running.Path }
    $roots = @("$env:LOCALAPPDATA\Programs", $env:ProgramFiles,
               [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $hit = Get-ChildItem $root -Recurse -Filter "Clash Verge*.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# 切换器管理的 13 个 Claude 域名 + 3 个 STUN 端口
$CLAUDE_DOMAINS = @(
    'claude.ai', 'claude.com', 'anthropic.com', 'claudeusercontent.com',
    'challenges.cloudflare.com', 'datadoghq.com', 'segment.io', 'stripe.com',
    'stripe.network', 'stripecdn.com', 'intercom.io', 'intercomcdn.com', 'intercomassets.com'
)
$CLAUDE_PORTS = @('3478', '5349', '19302')

# 读取 YAML 中第一个 key: value 标量(只用于 clash-verge.yaml / verge.yaml 的顶层字段)
function Get-YamlScalar([string]$path, [string]$key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop) {
            if ($line -match ('^\s*' + [regex]::Escape($key) + '\s*:\s*(.*?)\s*$')) {
                $v = $Matches[1].Trim()
                $v = $v -replace '\s+#.*$', ''
                $v = $v.Trim('"').Trim("'")
                return $v
            }
        }
    } catch {}
    return $null
}

# 解析 Clash 控制接口;Windows 版不使用 unix socket
function Get-ClashApi {
    foreach ($name in @('clash-verge.yaml', 'config.yaml')) {
        $yaml = Join-Path $CLASH_DIR $name
        $addr = Get-YamlScalar $yaml 'external-controller'
        if ([string]::IsNullOrWhiteSpace($addr)) { continue }
        if ($addr -match '^unix://' -or $addr -match '^/') { continue }
        $addr = $addr -replace '^0\.0\.0\.0:', '127.0.0.1:'
        $addr = $addr -replace '^:', '127.0.0.1:'
        if ($addr -notmatch '^https?://') { $addr = 'http://' + $addr }
        $base = $addr.TrimEnd('/')
        $secret = Get-YamlScalar $yaml 'secret'
        $headers = @{}
        if (-not [string]::IsNullOrWhiteSpace($secret)) { $headers['Authorization'] = 'Bearer ' + $secret }
        return @{ base = $base; headers = $headers }
    }
    return $null
}

# 返回 global|rule|direct|unknown;API 优先,失败再读 YAML
function Get-ClashMode {
    try {
        $api = Get-ClashApi
        if ($api) {
            try {
                $params = @{ Uri = ($api.base + '/configs'); TimeoutSec = 3; ErrorAction = 'Stop' }
                if ($api.headers.Count -gt 0) { $params['Headers'] = $api.headers }
                $resp = Invoke-RestMethod @params
                $m = ([string]$resp.mode).Trim().ToLowerInvariant()
                if ($m -eq 'global' -or $m -eq 'rule' -or $m -eq 'direct') { return $m }
            } catch {}
        }
        foreach ($name in @('clash-verge.yaml', 'verge.yaml')) {
            $p = Join-Path $CLASH_DIR $name
            if (-not (Test-Path -LiteralPath $p)) { continue }
            foreach ($line in Get-Content -LiteralPath $p -Encoding UTF8 -ErrorAction SilentlyContinue) {
                if ($line -match '(?m)^mode:\s*[''"]?(\w+)') {
                    $m = $Matches[1].ToLowerInvariant()
                    if ($m -eq 'global' -or $m -eq 'rule' -or $m -eq 'direct') { return $m }
                }
            }
        }
    } catch {}
    return 'unknown'
}

function Get-ClashRules {
    try {
        $api = Get-ClashApi
        if (-not $api) { return @{ available = $false; rules = @() } }
        $params = @{ Uri = ($api.base + '/rules'); TimeoutSec = 3; ErrorAction = 'Stop' }
        if ($api.headers.Count -gt 0) { $params['Headers'] = $api.headers }
        $resp = Invoke-RestMethod @params
        return @{ available = $true; rules = @($resp.rules) }
    } catch {
        return @{ available = $false; rules = @() }
    }
}

# 内核前 16 条必须包含 13 个域名 + 3 个端口;兼容 DOMAIN-SUFFIX/DomainSuffix 与 AND(...DST-PORT...) 形式
function Test-PinnedRules($rules) {
    $head = @($rules | Select-Object -First 16)
    if ($head.Count -lt 16) { return $false }
    $domainHits = @($head | Where-Object {
        (([string]$_.type).ToLowerInvariant() -replace '[-_]', '') -eq 'domainsuffix' -and
        ($CLAUDE_DOMAINS -contains [string]$_.payload)
    } | ForEach-Object { ([string]$_.payload).ToLowerInvariant() } | Sort-Object -Unique).Count
    $portHits = @($head | ForEach-Object {
        $type = ([string]$_.type).ToLowerInvariant() -replace '[-_]', ''
        $payload = [string]$_.payload
        if ($type -eq 'dstport' -and ($CLAUDE_PORTS -contains $payload)) { $payload }
        elseif ($payload -match ('DST-PORT,(' + ($CLAUDE_PORTS -join '|') + ')(?:[,)]|$)')) {
            foreach ($p in $CLAUDE_PORTS) {
                if ($payload -match ('DST-PORT,' + [regex]::Escape($p) + '(?:[,)]|$)')) { $p }
            }
        }
    } | Sort-Object -Unique).Count
    return ($domainHits -eq $CLAUDE_DOMAINS.Count -and $portHits -eq $CLAUDE_PORTS.Count)
}

# 规则模式只写 profiles\Script.js 托管块,不再碰 Merge.yaml
function Write-ClashScriptRules {
    $result = @{ ok = $false; changed = $false; existed = $false; backup = ''; message = '' }
    $scriptPath = Join-Path $CLASH_DIR 'profiles\Script.js'
    $backup = ''
    $existed = Test-Path -LiteralPath $scriptPath
    $result.existed = $existed
    try {
        if ([string]::IsNullOrWhiteSpace($PROXY_GROUP) -or $PROXY_GROUP -match '[,\r\n]') {
            $result.message = '代理组名为空或包含逗号/换行'
            return $result
        }
        $rules = @()
        foreach ($d in $CLAUDE_DOMAINS) { $rules += "DOMAIN-SUFFIX,$d,$PROXY_GROUP" }
        foreach ($p in $CLAUDE_PORTS) { $rules += "DST-PORT,$p,$PROXY_GROUP" }
        $json = ConvertTo-Json -InputObject @($rules) -Compress
        $managed = "// >>> claude-switcher managed rules >>>`r`n" +
            "  const pinnedRules = $json;`r`n" +
            "  config.rules = pinnedRules.concat((config.rules||[]).filter(r=>!pinnedRules.includes(r)));`r`n" +
            "// <<< claude-switcher managed rules <<<"

        if (-not $existed) {
            $dir = Split-Path -Parent $scriptPath
            New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
            $content = "function main(config) {`r`n" + $managed + "`r`n  return config;`r`n}`r`n"
            [System.IO.File]::WriteAllText($scriptPath, $content, (New-Object System.Text.UTF8Encoding($false)))
            $result.ok = $true
            $result.changed = $true
            $result.message = '已创建 Script.js'
            return $result
        }

        $existing = [System.IO.File]::ReadAllText($scriptPath)
        if ($existing -notmatch 'function\s+main\s*\(') {
            $result.message = 'Script.js 已存在但没有 function main(...),未改写,请手动合并'
            return $result
        }
        if ($existing -match '// >>> claude-switcher managed rules >>>') {
            $pattern = '(?s)// >>> claude-switcher managed rules >>>.*?// <<< claude-switcher managed rules <<<'
            $replacement = $managed.Replace('$', '$$')
            $updated = [regex]::Replace($existing, $pattern, $replacement)
        } else {
            $fn = [regex]::Match($existing, 'function\s+main\s*\(')
            $braceMatch = [regex]::Match($existing, 'function\s+main\s*\([^)]*\)\s*\{')
            if ($braceMatch.Success) {
                $brace = $braceMatch.Index + $braceMatch.Length - 1
            } else {
                $brace = $existing.IndexOf('{', $fn.Index + $fn.Length)
            }
            if ($brace -lt 0) {
                $result.message = 'Script.js 的 function main 缺少函数体,未改写'
                return $result
            }
            $updated = $existing.Substring(0, $brace + 1) + "`r`n" + $managed + "`r`n" + $existing.Substring($brace + 1)
        }
        if ($updated -ceq $existing) {
            $result.ok = $true
            $result.changed = $false
            $result.message = '规则已是当前版本'
            return $result
        }
        $backup = "$scriptPath.bak.$((Get-Date).ToString('yyyyMMddHHmmss'))"
        Copy-Item -LiteralPath $scriptPath -Destination $backup -Force -ErrorAction Stop
        [System.IO.File]::WriteAllText($scriptPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
        $result.ok = $true
        $result.changed = $true
        $result.backup = $backup
        $result.message = '规则已写入 Script.js'
        return $result
    } catch {
        $result.ok = $false
        $result.message = $_.Exception.Message
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $backup -Destination $scriptPath -Force -ErrorAction SilentlyContinue
        } elseif (-not $existed) {
            Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        }
        return $result
    }
}

# 清理旧版写进 Merge.yaml 的规则、多文档分隔符和重复顶层键
function Remove-LegacyMergeRules {
    $result = @{ changed = $false; backup = ''; removedRules = 0; removedDocs = 0; removedDupes = 0; message = '' }
    $mergePath = Join-Path $CLASH_DIR 'profiles\Merge.yaml'
    if (-not (Test-Path -LiteralPath $mergePath)) { return $result }
    $backup = ''
    try {
        $lines = @(Get-Content -LiteralPath $mergePath -Encoding UTF8 -ErrorAction Stop)
        $text = $lines -join "`n"
        $domainAlt = ($CLAUDE_DOMAINS | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $portAlt = ($CLAUDE_PORTS | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $ruleRe = '(?m)^\s*-\s*((DOMAIN-SUFFIX,(' + $domainAlt + '),)|(DST-PORT,(' + $portAlt + '),))'
        $hasRules = $text -match $ruleRe
        $hasDocs = [bool](@($lines | Where-Object { $_ -match '^\s*---\s*(#.*)?$' }).Count)
        $topKeys = @($lines | Where-Object { $_ -match '^[A-Za-z0-9_.-]+:' } | ForEach-Object { ($_ -split ':', 2)[0] })
        $hasDupes = [bool](@($topKeys | Group-Object | Where-Object { $_.Count -gt 1 }).Count)
        # 用户可能已经手动删了规则行但留下空的 prepend-rules:,同样需要清理
        $hasEmptyPrepend = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*prepend-rules:\s*(#.*)?$') {
                $hasItem = $false
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    $next = [string]$lines[$j]
                    if ($next -match '^\s*$') { continue }
                    if ($next -match '^\s*#') { continue }
                    if ($next -match '^\s*-\s+') { $hasItem = $true }
                    break
                }
                if (-not $hasItem) { $hasEmptyPrepend = $true; break }
            }
        }
        if (-not $hasRules -and -not $hasDocs -and -not $hasDupes -and -not $hasEmptyPrepend) { return $result }

        $backup = "$mergePath.bak.$((Get-Date).ToString('yyyyMMddHHmmss'))"
        Copy-Item -LiteralPath $mergePath -Destination $backup -Force -ErrorAction Stop

        $out = @()
        $removedRules = 0
        $removedDocs = 0
        foreach ($line in $lines) {
            if ($line -match '^\s*---\s*(#.*)?$') { $removedDocs++; continue }
            if ($line -match $ruleRe) { $removedRules++; continue }
            $out += $line
        }

        $cleaned = @()
        for ($i = 0; $i -lt $out.Count; $i++) {
            $line = $out[$i]
            if ($line -match '^\s*prepend-rules:\s*(#.*)?$') {
                $hasItem = $false
                for ($j = $i + 1; $j -lt $out.Count; $j++) {
                    $next = [string]$out[$j]
                    if ($next -match '^\s*$') { continue }
                    if ($next -match '^\s*#') { continue }
                    if ($next -match '^\s*-\s+') { $hasItem = $true }
                    break
                }
                if (-not $hasItem) { continue }
            }
            $cleaned += $line
        }

        $final = @()
        $seen = @{}
        $skip = $false
        $removedDupes = 0
        foreach ($line in $cleaned) {
            if ($line -match '^([A-Za-z0-9_.-]+):') {
                $key = $Matches[1]
                if ($seen.ContainsKey($key)) {
                    $skip = $true
                    $removedDupes++
                    continue
                }
                $seen[$key] = $true
                $skip = $false
                $final += $line
                continue
            }
            if ($skip) { continue }
            $final += $line
        }

        $before = ($lines -join "`n")
        $after = ($final -join "`n")
        if ($after -ceq $before) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
            return $result
        }

        if ([string]::IsNullOrWhiteSpace($after)) {
            Remove-Item -LiteralPath $mergePath -Force -ErrorAction Stop
        } else {
            [System.IO.File]::WriteAllText($mergePath, ($final -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        }
        $result.changed = $true
        $result.backup = $backup
        $result.removedRules = $removedRules
        $result.removedDocs = $removedDocs
        $result.removedDupes = $removedDupes
        $result.message = '已清理历史遗留 Merge 规则'
        return $result
    } catch {
        $result.message = $_.Exception.Message
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $backup -Destination $mergePath -Force -ErrorAction SilentlyContinue
        }
        return $result
    }
}

function Restart-ClashVerge {
    $cv = Find-ClashVerge
    if (-not $cv) { return $false }
    Get-Process -Name 'clash-verge','Clash Verge' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
    try { Start-Process $cv } catch { return $false }
    return $true
}

function Wait-Tun([int]$seconds) {
    for ($i = 0; $i -lt $seconds; $i++) {
        if (Test-TunUp) { return $true }
        Start-Sleep 1
    }
    return [bool](Test-TunUp)
}

function Wait-ClashRules([int]$seconds) {
    $last = @{ available = $false; rules = @() }
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $last = Get-ClashRules
        if ($last.available -and (Test-PinnedRules $last.rules)) { return $last }
        Start-Sleep 1
    }
    return $last
}

function Restore-ClashScriptChange($write) {
    if (-not $write.changed) { return }
    $scriptPath = Join-Path $CLASH_DIR 'profiles\Script.js'
    if ($write.backup -and (Test-Path -LiteralPath $write.backup)) {
        Copy-Item -LiteralPath $write.backup -Destination $scriptPath -Force -ErrorAction SilentlyContinue
    } elseif (-not $write.existed) {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-ClashScriptManaged {
    $p = Join-Path $CLASH_DIR 'profiles\Script.js'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    try { return ([System.IO.File]::ReadAllText($p)) -match '// >>> claude-switcher managed rules >>>' } catch { return $false }
}

function Get-RulesStatus {
    $mode = Get-ClashMode
    if ($mode -eq 'global') { return '规则置顶=ok:全局模式(规则不适用)' }
    if ($mode -eq 'direct') { return '规则置顶=ok:直连模式(规则不适用)' }
    if ($mode -eq 'unknown') { return '规则置顶=warn:无法确认 Clash 模式,未检查规则' }
    $rulesInfo = Get-ClashRules
    if ($rulesInfo.available) {
        if (Test-PinnedRules $rulesInfo.rules) { return '规则置顶=ok' }
        return '规则置顶=fail:内核未加载置顶规则'
    }
    if (Test-ClashScriptManaged) { return '规则置顶=warn:规则已写入但无法验证内核加载' }
    return '规则置顶=fail:未配置'
}

function Invoke-CheckDetail {
    if (-not (Import-CoreConfiguration)) {
        foreach ($definition in @(Get-CoreCheckDefinitions)) { "$($definition.name)=fail:用户配置无效，请重新配置" }
        return
    }
    $pname = Get-ProxyName
    if (Test-ProxyAlive) {
        if ($PROXY_MODE -eq 'other') { "代理内核=ok:$pname(仅校验TUN)" }
        else { "代理内核=ok:$pname 运行中" }
    } else { "代理内核=fail:$pname 未运行" }

    $tun = Get-TunStatus
    if ($tun.up) {
        if ($tun.detail -eq '198.18 假IP段') { "TUN网卡=ok" }
        else { "TUN网卡=ok:$($tun.detail)" }
    } else { "TUN网卡=fail:不在线" }

    $e = Get-Egress
    if ($e.loc -eq $COUNTRY_TARGET) { "出口IP=ok:$($e.ip)" } else { "出口IP=fail:$($e.ip)/$($e.loc)(期望$COUNTRY_TARGET)" }

    $lastipFile = "$BASE\lastip.txt"
    $lastip = if (Test-Path $lastipFile) { (Get-Content $lastipFile -Raw).Trim() } else { '' }
    if (-not $e.ip) { "IP一致=fail:未获取到出口IP" }
    elseif (-not $lastip) { "IP一致=ok:首次记录" }
    elseif ($e.ip -eq $lastip) { "IP一致=ok" }
    else { "IP一致=warn:$lastip → $($e.ip)" }
    if ($e.ip) { Write-AtomicState $lastipFile $e.ip }

    $tz = (Get-TimeZone).Id
    if ($tz -eq $TZ_TARGET) { "时区=ok" } else { "时区=fail:$tz" }

    $cult = (Get-Culture).Name
    if ($cult -eq $LOCALE_TARGET) { "地区=ok" } else { "地区=fail:$cult" }

    $v6off = [bool](Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true })
    if (-not $v6off) { "IPv6=ok:已关闭" } else { "IPv6=fail:未关闭" }

    $dns = (Resolve-DnsName claude.ai -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if ($dns -like '198.18.*') { "DNS=ok:走隧道" } else { "DNS=fail:未走隧道($dns)" }

    $w = Test-WebRTC $e.ip
    "WebRTC=$($w.code):$($w.detail)"

    if (Test-BodyguardHealth) { "保镖=ok" } else { "保镖=fail:任务归属、运行状态或存活证据未验证；请重新配置" }

    Get-RulesStatus

    # 客户端语言: Windows 端 Claude 跟随系统区域格式,地区检查已覆盖
    "客户端语言=ok:跟随系统"

    $org = ''
    try { $org = ((& curl.exe -s --max-time 6 "https://ipinfo.io/json" 2>$null) | ConvertFrom-Json).org } catch {}
    if (-not $org) { "ASN属性=warn:未获取" }
    elseif ($org -match 'Comcast|AT&T|Verizon|Spectrum|Charter|Cox|T-Mobile|Cable|esidential') { "ASN属性=ok:$org" }
    else { "ASN属性=warn:疑似机房($org)" }

    $r1 = & curl.exe -s --max-time 8 -o NUL -w '%{http_code}' "https://claude.ai/" 2>$null
    $r2 = & curl.exe -s --max-time 8 -o NUL -w '%{http_code}' "https://api.anthropic.com/v1/models" 2>$null
    if ($r1 -ne '000' -and $r2 -ne '000') { "生态可达性=ok:claude.ai:$r1 api:$r2" } else { "生态可达性=fail:claude.ai:$r1 api:$r2" }
}

function Invoke-Fix {
    $script:FixExitCode=0
    if (-not (Import-CoreConfiguration)) { $script:FixExitCode=1; 'FIX:用户配置无效，请重新配置；未执行修复'; return }
    $assessment=Get-BodyguardTaskAssessment
    if ($assessment.Kind -eq 'Legacy') {
        'FIX:检测到可迁移的旧版 ClaudeBodyguard；正在通过受保护助手完成迁移...'
        $migrationResult=Invoke-ProtectedBodyguardMigration
        if ($migrationResult -ne 0) {
            $script:FixExitCode=if ($migrationResult -eq 4) { 4 } else { 5 }
            if ($migrationResult -eq 4) {
                'FIX:旧版 ClaudeBodyguard 迁移需要管理员授权；授权已取消，不会停止或删除旧任务'
            } else {
                'FIX:旧版 ClaudeBodyguard 迁移失败；不会停止或删除旧任务，也不会执行旧脚本或导入旧配置。请重新运行修复并检查迁移校验结果。'
            }
            return
        }
        'FIX:旧版 ClaudeBodyguard 迁移完成，继续执行常规修复检查'
    } elseif ($assessment.Kind -eq 'LegacyMigration') {
        $script:FixExitCode=5
        'FIX:检测到旧版 ClaudeBodyguard，但任务归属、触发、设置或运行实例无法完整验证；当前构建不支持自动迁移，也不会停止或删除旧任务。请先按兼容迁移指引处理旧任务/进程，再配置受保护任务。'
        return
    }
    "FIX:开始一键修复"

    # A. 拉起代理客户端并等待内核+TUN(仅 Clash Verge 可自动拉起)
    if ($PROXY_MODE -eq 'clash-verge') {
        if (-not (Test-ProxyAlive)) {
            "FIX:正在启动 Clash Verge..."
            $cv = Find-ClashVerge
            if ($cv) { Start-Process $cv } else { "FIX:未找到 Clash Verge 可执行文件,请手动启动" }
        }
        $ok = $false
        for ($i = 0; $i -lt 40; $i++) { if ((Test-ProxyAlive) -and (Test-TunUp)) { $ok = $true; break }; Start-Sleep 1 }
        if ($ok) { "FIX:代理内核+TUN ✓" } else { "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路及 TUN 开关)" }
    } else {
        $pname = Get-ProxyName
        if ((Test-ProxyAlive) -and (Test-TunUp)) { "FIX:代理客户端($pname)+TUN ✓" }
        elseif (-not (Test-ProxyAlive)) { "FIX:代理客户端($pname)未运行,请手动启动并开启 TUN 模式" }
        else { "FIX:TUN 未在线($pname),请检查客户端 TUN 开关" }
    }

    # B. One fixed protected helper owns all elevated system changes.
    if (Test-SystemRepairRequired) {
        'FIX:修复时区/IPv6/DNS/保镖(需要管理员授权)...'
        $script:FixExitCode=Invoke-ProtectedSystemRepair
        if ($script:FixExitCode -ne 0) {
            if ($script:FixExitCode -eq 4) { 'FIX:管理员授权已取消；请重新检查实际状态' }
            else { 'FIX:系统修复未完成；请安装原生版本或检查受保护助手，已完成的步骤不会标成全部成功' }
            return
        }
        'FIX:时区/IPv6/DNS/保镖 ✓'
    } else {
        'FIX:时区/IPv6/保镖无需修复 ✓'
    }

    # B2. 置顶规则:先识别 Clash 模式,绝不盲目写 Merge.yaml
    if ($PROXY_MODE -ne 'clash-verge') {
        "FIX:请在 $(Get-ProxyName) 中自行添加 Claude 域名置顶/直连规则"
    } else {
        $clashMode = Get-ClashMode
        if ($clashMode -eq 'unknown') {
            "FIX:无法确认 Clash 模式，已跳过规则修改"
        } elseif ($clashMode -eq 'global' -or $clashMode -eq 'direct') {
            $modeLabel = if ($clashMode -eq 'global') { '全局模式' } else { '直连模式' }
            "FIX:Clash 模式=$clashMode"
            $legacy = Remove-LegacyMergeRules
            if ($legacy.message -and -not $legacy.changed) {
                "FIX:Merge.yaml 清理提示: $($legacy.message)"
            }
            if ($legacy.changed) {
                "FIX:发现历史遗留 Merge 规则,已清理并备份: $($legacy.backup)"
                if (Restart-ClashVerge) {
                    "FIX:已重启 Clash Verge 以重新加载配置"
                    if ($clashMode -eq 'global') {
                        $tunOk = Wait-Tun 40
                        if ((Test-ProxyAlive) -and $tunOk) { "FIX:代理/TUN 已恢复 ✓" } else { "FIX:代理/TUN 未完全恢复,请手动检查 Clash 和 TUN 开关" }
                    }
                } else {
                    "FIX:未找到 Clash Verge 可执行文件,请手动重启以完成清理"
                }
                "FIX:$modeLabel,规则不适用,未写入任何规则,已清理历史遗留配置 ✓"
            } else {
                "FIX:$modeLabel,规则不适用,未改动任何配置 ✓"
            }
        } else {
            "FIX:Clash 模式=rule"
            $legacy = Remove-LegacyMergeRules
            if ($legacy.message -and -not $legacy.changed) {
                "FIX:Merge.yaml 清理提示: $($legacy.message)"
            }
            if ($legacy.changed) {
                "FIX:已清理历史遗留 Merge 规则并备份: $($legacy.backup)"
            }

            $write = Write-ClashScriptRules
            if (-not $write.ok) {
                "FIX:置顶规则 FAIL: $($write.message)"
                if ($legacy.changed) {
                    if (Restart-ClashVerge) {
                        Wait-Tun 20 | Out-Null
                        "FIX:已重启 Clash Verge 应用 Merge 清理"
                    } else {
                        "FIX:请手动重启 Clash Verge 应用 Merge 清理"
                    }
                }
            } else {
                $current = Get-ClashRules
                $alreadyOk = $current.available -and (Test-PinnedRules $current.rules)
                if (-not $write.changed -and -not $legacy.changed -and $alreadyOk) {
                    "FIX:置顶规则已是当前版本,内核已加载 ✓"
                } else {
                    if ($write.changed) {
                        "FIX:已写入 Script.js 规则并备份: $($write.backup)"
                    }
                    if (Restart-ClashVerge) {
                        $rulesInfo = Wait-ClashRules 40
                        if (-not $rulesInfo.available) {
                            "FIX:规则已写入但无法验证内核加载(控制接口不可用)"
                        } elseif (Test-PinnedRules $rulesInfo.rules) {
                            "FIX:置顶规则 ✓"
                            Wait-Tun 20 | Out-Null
                        } else {
                            "FIX:置顶规则验证失败,正在回滚 Script.js..."
                            Restore-ClashScriptChange $write
                            Restart-ClashVerge | Out-Null
                            Wait-Tun 20 | Out-Null
                            "FIX:置顶规则 FAIL: 验证失败,已回滚 Script.js,请确认 Clash Verge 已启用全局扩展脚本"
                        }
                    } else {
                        "FIX:规则已写入但未找到 Clash Verge 可执行文件,请手动重启后验证"
                    }
                }
            }
        }
    }

    # C. 出口IP最终验证
    Start-Sleep 2
    $e = Get-Egress
    if ($e.loc -eq $COUNTRY_TARGET) { "FIX:出口IP ✓ ($($e.ip))" } else { "FIX:出口IP ✗ ($($e.ip)/$($e.loc),期望$COUNTRY_TARGET) — 请换节点/线路" }
    "FIX:修复流程结束"
}

function Invoke-Status {
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }
    $hasA = if (Test-Path "$BASE\accounts\A") { 1 } else { 0 }
    $hasB = if (Test-Path "$BASE\accounts\B") { 1 } else { 0 }
    "current=$cur hasA=$hasA hasB=$hasB"
}

function Test-LaunchGate {
    if (-not (Import-CoreConfiguration)) {
        return [pscustomobject]@{ CanLaunch=$false; Checks=@{}; BlockingReason='configuration-invalid' }
    }
    $required = @(
        '代理内核', 'TUN网卡', '出口IP', 'IP一致', '时区', '地区', 'IPv6',
        'DNS', 'WebRTC', '保镖', '规则置顶', '客户端语言', 'ASN属性', '生态可达性'
    )
    $checks = @{}
    $seen = @{}
    try {
        foreach ($line in @(Invoke-CheckDetail)) {
            $row = [string]$line
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            $parts = $row -split '=', 2
            if ($parts.Count -ne 2) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-malformed'
                }
            }
            $name = [string]$parts[0]
            if ($required -notcontains $name) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-unknown'
                }
            }
            if ($seen.ContainsKey($name)) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-duplicate'
                }
            }
            $state = $parts[1] -split ':', 2
            if ($state.Count -lt 1 -or -not $state[0]) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-malformed'
                }
            }
            $seen[$name] = $true
            $checks[$name] = [string]$state[0]
        }
    } catch {
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'checks-error'
        }
    }
    foreach ($name in $required) {
        if (-not $checks.ContainsKey($name)) {
            return [pscustomobject]@{
                CanLaunch = $false
                Checks = $checks
                BlockingReason = 'checks-incomplete'
            }
        }
    }
    if ($checks['出口IP'] -ne 'ok') {
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'egress'
        }
    }
    if ($checks['WebRTC'] -eq 'unknown') {
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'stun-unknown'
        }
    }
    $warningAllowlist = @('IP一致', 'ASN属性')
    foreach ($name in $required) {
        if ($checks[$name] -eq 'ok') { continue }
        if ($checks[$name] -eq 'warn' -and $warningAllowlist -contains $name) { continue }
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'check-failed'
        }
    }
    return [pscustomobject]@{
        CanLaunch = $true
        Checks = $checks
        BlockingReason = ''
    }
}

function Stop-ClaudeApp {
    $p = @(Get-OwnedClaudeProcesses)
    if (-not $p) { return $true }
    $p | Stop-Process -Force
    for ($i = 0; $i -lt 15; $i++) { if (-not @(Get-OwnedClaudeProcesses).Count) { return $true }; Start-Sleep 1 }
    return $false
}

function Test-CoreRecoveryEntry([string]$Path) {
    try { $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop; return $true }
    catch [Management.Automation.ItemNotFoundException] { return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { return $true }
}

function Enter-OperationLock([int]$WaitMilliseconds = 2000) {
    $maintenanceMutex=$null
    try {
        $maintenanceMutex=[Threading.Mutex]::OpenExisting('Global\ClaudeSwitcher.InstallerMaintenance')
        if(-not $maintenanceMutex.WaitOne(0)){return $null}
        $maintenanceMutex.ReleaseMutex()
    } catch [Threading.WaitHandleCannotBeOpenedException] {
    } catch [Threading.AbandonedMutexException] {
        if($null -ne $maintenanceMutex){$maintenanceMutex.ReleaseMutex()}
    } catch {return $null}
    finally {if($null -ne $maintenanceMutex){$maintenanceMutex.Dispose()}}
    if (Test-CoreRecoveryEntry (Join-Path $BASE 'installer-maintenance.json')) { return $null }
    if (Test-CoreRecoveryEntry (Join-Path $BASE 'operation.lease.json')) { return $null }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open((Join-Path $BASE 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { if ($timer.ElapsedMilliseconds -ge $WaitMilliseconds) { return $null }; Start-Sleep -Milliseconds 25 }
    } while ($true)
}

function Exit-OperationLock($Handle) { if ($null -ne $Handle) { $Handle.Dispose() } }

function Write-AtomicState([string]$Path, [string]$Text) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding $true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-CurrentAccount {
    $current = if (Test-Path -LiteralPath "$BASE\current.txt") { ([IO.File]::ReadAllText("$BASE\current.txt")).Trim() } else { 'none' }
    if ($current -cnotin @('A', 'B', 'none')) { throw 'Invalid current account marker.' }
    return $current
}

function Get-AccountTreeManifest([string]$Path) {
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid account tree.' }
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($root.FullName)
    $prefix = $root.FullName.TrimEnd('\') + '\'
    $manifest = @()
    while ($pending.Count) {
        $dir = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not supported in account trees.' }
            $relative = $item.FullName.Substring($prefix.Length)
            if ($item.PSIsContainer) {
                $manifest += [pscustomobject][ordered]@{ path=$relative; kind='directory'; length=0; hash='' }
                $pending.Push($item.FullName)
            } else {
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                $manifest += [pscustomobject][ordered]@{ path=$relative; kind='file'; length=$item.Length; hash=$hash }
            }
        }
    }
    return @($manifest | Sort-Object -Property path)
}

function Test-AccountTree([string]$Path, $Manifest) {
    try {
        $actual = @(Get-AccountTreeManifest $Path)
        $expected = @($Manifest)
        if ($actual.Count -ne $expected.Count) { return $false }
        for ($i=0; $i -lt $actual.Count; $i++) {
            foreach ($field in @('path', 'kind', 'length', 'hash')) {
                if ([string]$actual[$i].$field -cne [string]$expected[$i].$field) { return $false }
            }
        }
        return $true
    } catch { return $false }
}

function Invoke-AccountCopy([string]$Source, [string]$Destination) {
    # /R and /W are bounded; terminate only this child on timeout, then wait before recovery.
    $copy = New-Object Diagnostics.Process
    $copy.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $copy.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $copy.StartInfo.Arguments = '"' + $Source.TrimEnd('\') + '" "' + $Destination.TrimEnd('\') + '" /E /R:1 /W:1 /XJ /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /NP'
    $copy.StartInfo.UseShellExecute = $false
    $copy.StartInfo.CreateNoWindow = $true
    $copy.StartInfo.RedirectStandardOutput = $true
    $copy.StartInfo.RedirectStandardError = $true
    try {
        if (-not $copy.Start()) { return 16 }
        $stdoutDrain = $copy.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
        $stderrDrain = $copy.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $timedOut = -not $copy.WaitForExit(600000)
        if ($timedOut) { $copy.Kill(); $copy.WaitForExit() }
        $drains = [Threading.Tasks.Task[]]@($stdoutDrain,$stderrDrain)
        try {
            if (-not [Threading.Tasks.Task]::WaitAll($drains, 5000)) { return 16 }
        } catch {
            # WaitAll observes faults; never report a copy as successful after a drain failure.
            foreach ($drain in $drains) { if ($drain.IsFaulted) { $null = $drain.Exception } }
            return 16
        }
        if ($timedOut) { return 16 }
        return $copy.ExitCode
    } finally { $copy.Dispose() }
}

function Invoke-TransactionCheckpoint([string]$Phase) { }

function New-TransactionResult($OperationId, [string]$Current, [bool]$Success, [bool]$RecoveryRequired, [string]$Code) {
    $phase = if ($RecoveryRequired) { 'recoveryRequired' } elseif ($Success) { 'completed' } else { 'idle' }
    return [pscustomobject]@{ operationId=[string]$OperationId; phase=$phase; current=$Current; success=$Success; recoveryRequired=$RecoveryRequired; code=$Code }
}

function Save-TransactionRecord($Record) {
    Write-AtomicState "$BASE\transaction.json" (ConvertTo-Json -InputObject $Record -Depth 8 -Compress)
}

function Remove-VerifiedTransactionArtifacts($Record) {
    # Validate every sidecar before deleting any of them. A valid committed target
    # does not prove that an unrelated .previous directory belongs to this operation.
    if (-not (Test-AccountTree $DATA $Record.targetManifest)) { throw 'Committed target verification failed.' }
    if ($Record.source -in @('A','B') -and -not (Test-AccountTree "$BASE\accounts\$($Record.source)" $Record.sourceManifest)) { throw 'Source archive verification failed.' }
    $verified = @()
    if (Test-Path -LiteralPath "$DATA.new") { throw 'Unexpected active staging tree must be preserved.' }
    if (Test-Path -LiteralPath "$DATA.previous") {
        if (-not $Record.hadActive -or -not (Test-AccountTree "$DATA.previous" $Record.sourceManifest)) { throw 'Previous active tree cannot be verified.' }
        $verified += "$DATA.previous"
    }
    if ($Record.source -in @('A','B')) {
        $archive = "$BASE\accounts\$($Record.source)"
        if (Test-Path -LiteralPath "$archive.new") { throw 'Unexpected archive staging tree must be preserved.' }
        if (Test-Path -LiteralPath "$archive.previous") {
            if ($Record.hadArchive -isnot [bool] -or -not $Record.hadArchive -or
                $null -eq $Record.priorArchiveManifest -or -not (Test-AccountTree "$archive.previous" $Record.priorArchiveManifest)) { throw 'Previous archive cannot be verified.' }
            $verified += "$archive.previous"
        }
    }
    Invoke-TransactionCheckpoint -Phase beforeCleanup
    foreach ($path in $verified) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
    [IO.File]::Delete("$BASE\transaction.json")
    Invoke-TransactionCheckpoint -Phase afterCleanup
}

function Recover-PendingTransactionCore {
    $journal = "$BASE\transaction.json"
    $current = 'none'
    try { $current = Get-CurrentAccount } catch { return (New-TransactionResult '' $current $false $true 'invalid-current') }
    if (-not (Test-Path -LiteralPath $journal)) {
        $residue = @("$DATA.new", "$DATA.previous", "$DATA.claude-switch-staging", "$BASE\accounts\A.new", "$BASE\accounts\A.previous", "$BASE\accounts\B.new", "$BASE\accounts\B.previous")
        if (@($residue | Where-Object { Test-Path -LiteralPath $_ }).Count) { return (New-TransactionResult '' $current $false $true 'unowned-residue') }
        return (New-TransactionResult '' $current $true $false 'idle')
    }
    try {
        $tx = [IO.File]::ReadAllText($journal) | ConvertFrom-Json -ErrorAction Stop
        $id = [guid]::Empty
        if ($tx.schemaVersion -ne 1 -or -not [guid]::TryParse([string]$tx.operationId, [ref]$id) -or $id -eq [guid]::Empty -or
            $tx.source -cnotin @('A','B','none') -or $tx.target -cnotin @('A','B') -or
            $tx.phase -cnotin @('started','archived','prepared','replacing','activeReplaced','committed')) { throw 'Invalid transaction record.' }
        if ($tx.phase -eq 'committed' -or ($current -eq $tx.target -and $tx.phase -eq 'activeReplaced')) {
            if (-not (Test-AccountTree $DATA $tx.targetManifest)) { throw 'Committed tree cannot be verified.' }
            Write-AtomicState "$BASE\current.txt" $tx.target
            Remove-VerifiedTransactionArtifacts $tx
            return (New-TransactionResult $tx.operationId $tx.target $true $false 'recovered-commit')
        }
        # Before marker commit, restore only from the verified original active tree.
        if ($tx.hadActive) {
            if (-not (Test-AccountTree $DATA $tx.sourceManifest)) {
                if (-not (Test-AccountTree "$DATA.previous" $tx.sourceManifest)) { throw 'Original active tree cannot be verified.' }
                if (Test-Path -LiteralPath $DATA) {
                    if ((Test-Path -LiteralPath "$DATA.new") -or -not (Test-AccountTree $DATA $tx.targetManifest)) { throw 'Unknown active data must be preserved.' }
                    [IO.Directory]::Move($DATA, "$DATA.new")
                }
                [IO.Directory]::Move("$DATA.previous", $DATA)
            }
        } elseif (Test-Path -LiteralPath $DATA) {
            # A fresh profile has no source; preserve every tree and require explicit recovery.
            throw 'Fresh account transaction requires recovery.'
        }
        Write-AtomicState "$BASE\current.txt" $tx.source
        # Preserve all stage/archive data on rollback. A later mutation is blocked until reviewed.
        $tx.phase = 'started'
        Save-TransactionRecord $tx
        return (New-TransactionResult $tx.operationId $tx.source $false $true 'rolled-back-review-required')
    } catch { return (New-TransactionResult '' $current $false $true 'recovery-required') }
}

function Invoke-AccountTransactionCore([ValidateSet('A','B')][string]$Target, [guid]$OperationId = [guid]::NewGuid()) {
    $current = Get-CurrentAccount
    $prior = Recover-PendingTransactionCore
    if ($prior.recoveryRequired) { return $prior }
    $current = Get-CurrentAccount
    $hadActive = Test-Path -LiteralPath $DATA
    $source = $current
    if ($source -eq 'none' -and $hadActive -and @(Get-ChildItem -LiteralPath $DATA -Force -ErrorAction Stop).Count) { $source = 'A' }
    $tx = [ordered]@{ schemaVersion=1; operationId=$OperationId.ToString('D'); source=$source; target=$Target; phase='started'; hadActive=[bool]$hadActive; sourceManifest=@(); targetManifest=@(); hadArchive=$false; priorArchiveManifest=@() }
    try {
        if ($hadActive) { $tx.sourceManifest = @(Get-AccountTreeManifest $DATA) }
        Save-TransactionRecord $tx
        if ($source -in @('A','B') -and $hadActive) {
            $archive = "$BASE\accounts\$source"
            if (Test-Path -LiteralPath $archive) {
                $tx.hadArchive = $true
                $tx.priorArchiveManifest = @(Get-AccountTreeManifest $archive)
                Save-TransactionRecord $tx
            }
            $copyCode = Invoke-AccountCopy -Source $DATA -Destination "$archive.new"
            if ($copyCode -lt 0 -or $copyCode -ge 8 -or -not (Test-AccountTree "$archive.new" $tx.sourceManifest)) { throw 'Archive copy failed verification.' }
            if (Test-Path -LiteralPath $archive) {
                Invoke-TransactionCheckpoint -Phase beforeArchiveBackup
                [IO.Directory]::Move($archive, "$archive.previous")
                Invoke-TransactionCheckpoint -Phase afterArchiveBackup
            }
            Invoke-TransactionCheckpoint -Phase beforeArchivePromote
            [IO.Directory]::Move("$archive.new", $archive)
            Invoke-TransactionCheckpoint -Phase afterArchivePromote
        }
        $tx.phase = 'archived'; Save-TransactionRecord $tx
        $targetArchive = "$BASE\accounts\$Target"
        if (Test-Path -LiteralPath $targetArchive) {
            $tx.targetManifest = @(Get-AccountTreeManifest $targetArchive)
            $copyCode = Invoke-AccountCopy -Source $targetArchive -Destination "$DATA.new"
            if ($copyCode -lt 0 -or $copyCode -ge 8 -or -not (Test-AccountTree "$DATA.new" $tx.targetManifest)) { throw 'Target copy failed verification.' }
        } else { [void][IO.Directory]::CreateDirectory("$DATA.new") }
        $tx.phase = 'prepared'; Save-TransactionRecord $tx; Invoke-TransactionCheckpoint -Phase prepared
        $tx.phase = 'replacing'; Save-TransactionRecord $tx
        if ($hadActive) {
            Invoke-TransactionCheckpoint -Phase beforeActiveBackup
            [IO.Directory]::Move($DATA, "$DATA.previous")
            Invoke-TransactionCheckpoint -Phase afterActiveBackup
        }
        Invoke-TransactionCheckpoint -Phase beforeTargetPromote
        [IO.Directory]::Move("$DATA.new", $DATA)
        Invoke-TransactionCheckpoint -Phase afterTargetPromote
        $tx.phase = 'activeReplaced'; Save-TransactionRecord $tx; Invoke-TransactionCheckpoint -Phase activeReplaced
        Write-AtomicState "$BASE\current.txt" $Target
        $tx.phase = 'committed'; Save-TransactionRecord $tx; Invoke-TransactionCheckpoint -Phase committed
        if (-not (Test-AccountTree $DATA $tx.targetManifest)) { throw 'Committed target failed verification.' }
        Remove-VerifiedTransactionArtifacts $tx
        return (New-TransactionResult $OperationId $Target $true $false 'ok')
    } catch {
        $script:TransactionFailure = $_.Exception.Message
        $recovered = Recover-PendingTransactionCore
        return (New-TransactionResult $OperationId $recovered.current $false $recovered.recoveryRequired 'transaction-failed')
    }
}

function Recover-PendingTransaction([int]$WaitMilliseconds = 2000) {
    $handle = Enter-OperationLock -WaitMilliseconds $WaitMilliseconds
    if ($null -eq $handle) { return (New-TransactionResult '' (Get-CurrentAccount) $false $true 'busy') }
    try { return Recover-PendingTransactionCore }
    finally { Exit-OperationLock -Handle $handle }
}

function Invoke-AccountTransaction([ValidateSet('A','B')][string]$Target, [guid]$OperationId = [guid]::NewGuid(), [int]$WaitMilliseconds = 2000) {
    $handle = Enter-OperationLock -WaitMilliseconds $WaitMilliseconds
    if ($null -eq $handle) { return (New-TransactionResult $OperationId (Get-CurrentAccount) $false $false 'busy') }
    try { return Invoke-AccountTransactionCore -Target $Target -OperationId $OperationId }
    finally { Exit-OperationLock -Handle $handle }
}

function Save-Account($name) {
    robocopy "$DATA" "$BASE\accounts\$name" /MIR /NFL /NDL /NJH /NJS | Out-Null
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -lt 0 -or $copyExitCode -ge 8) {
        Log "账号$name 存档失败(robocopy=$copyExitCode)"
        return $false
    }
    Log "已存档账号$name"
    return $true
}

function Start-ClaudeApp {
    $exe = @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw 'Claude executable not found; no launch was performed.' }
    Start-Process -FilePath $exe -ErrorAction Stop | Out-Null
}

function Invoke-Switch([ValidateSet('A','B')][string]$Target, [guid]$OperationId = [guid]::NewGuid()) {
    $script:SwitchExitCode = 0
    $script:LastOperationResult = $null
    $handle = Enter-OperationLock
    if ($null -eq $handle) { $script:SwitchExitCode=2; 'FAIL:busy，另一个操作正在处理'; return }
    try {
        Write-CoreActivity $OperationId 'switch' 'checking'
        $recovery = Recover-PendingTransactionCore
        if ($recovery.recoveryRequired) {
            $script:LastOperationResult = $recovery
            $script:SwitchExitCode=3
            'FAIL:recoveryRequired，存在需要核实的账号恢复数据，未启动 Claude'
            return
        }
        $current = Get-CurrentAccount
        $gate = Test-LaunchGate
        if (-not $gate.CanLaunch) { $script:SwitchExitCode=1; "FAIL:切换前检查未通过($($gate.BlockingReason))，未修改账号数据且 Claude 未启动"; return }
        if ($current -ne $Target) {
            if (-not (Stop-ClaudeApp)) { $script:SwitchExitCode=1; 'FAIL:Claude 未能退出，请手动退出后重试'; return }
            $transaction = Invoke-AccountTransactionCore -Target $Target -OperationId $OperationId
            $script:LastOperationResult = $transaction
            if (-not $transaction.success -or $transaction.recoveryRequired) {
                $script:SwitchExitCode=if($transaction.recoveryRequired){3}else{1}
                "FAIL:账号切换未提交($($transaction.code))，当前账号$($transaction.current)，recoveryRequired=$($transaction.recoveryRequired)"
                return
            }
            $gate = Test-LaunchGate
            if (-not $gate.CanLaunch) { $script:SwitchExitCode=1; "FAIL:启动前检查未通过($($gate.BlockingReason))，当前账号$Target，Claude 未启动"; return }
        }
        Start-ClaudeApp
        $script:LastOperationResult = New-TransactionResult $OperationId $Target $true $false 'ok'
        "OK:已切换到账号$Target"
    } catch {
        $script:SwitchExitCode=1
        'FAIL:切换状态无法验证，Claude 未启动；请检查恢复状态'
    } finally { try{Remove-CoreActivity}catch{}; Exit-OperationLock -Handle $handle }
}

function Invoke-CheckCommand {
    $script:CoreExitCode=0
    $handle=Enter-OperationLock
    if ($null -eq $handle) { $script:CoreExitCode=2; 'FAIL:busy，另一个操作正在处理'; return }
    try {
        Write-CoreActivity ([guid]::NewGuid()) 'checkdetail' 'checking'
        $assessment=ConvertTo-CoreChecks @(Invoke-CheckDetail *>&1)
        $rows=@($assessment.checks | ForEach-Object { "$($_.name)=$($_.status):$($_.detail)" -replace '=unknown:', '=fail:' })
        if(-not $assessment.canLaunch){$script:CoreExitCode=1}
        Write-AtomicState "$BASE\last-check.txt" ($rows -join "`n")
        $rows
    } catch { $script:CoreExitCode=1; 'FAIL:检查未完成' }
    finally { try{Remove-CoreActivity}catch{}; Exit-OperationLock -Handle $handle }
}

function Invoke-FixCommand([guid]$OperationId=[guid]::NewGuid()) {
    $script:CoreExitCode=0
    $script:FixExitCode=0
    $handle=Enter-OperationLock
    if ($null -eq $handle) { $script:CoreExitCode=2; 'FAIL:busy，另一个操作正在处理'; return }
    try {
        Write-CoreActivity $OperationId 'fix' 'repairing'
        $recovery=Recover-PendingTransactionCore
        if($recovery.recoveryRequired){ $script:CoreExitCode=3; 'FAIL:recoveryRequired，先核实账号恢复数据'; return }
        Invoke-Fix
        if($script:FixExitCode){$script:CoreExitCode=$script:FixExitCode; return}
        if(-not (Test-LaunchGate).CanLaunch){$script:CoreExitCode=1; 'FAIL:修复后检查仍有阻断项'}
    } catch { $script:CoreExitCode=1; 'FAIL:修复未完成' }
    finally { try{Remove-CoreActivity}catch{}; Exit-OperationLock -Handle $handle }
}

function Get-CoreCheckDefinitions {
    $ids = @('proxy_engine','tun_interface','egress_country','ip_consistency','timezone','locale','ipv6','dns','webrtc','bodyguard','routing_rules','client_language','asn','ecosystem')
    $names = @('代理内核','TUN网卡','出口IP','IP一致','时区','地区','IPv6','DNS','WebRTC','保镖','规则置顶','客户端语言','ASN属性','生态可达性')
    for ($i=0; $i -lt $ids.Count; $i++) { [pscustomobject]@{ id=$ids[$i]; name=$names[$i] } }
}

function Protect-CoreText([string]$Text) {
    $value = [regex]::Replace($Text, '(?i)\b(https?|socks5h?)://[^/\s:@]+:[^/\s@]+@', '$1://[redacted]@')
    $value = [regex]::Replace($value, '(?i)\b(password|passwd|pwd|token|secret|api[_-]?key|authorization)\s*[:=]\s*[^\s,;]+', '$1=[redacted]')
    $value = [regex]::Replace($value, '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [redacted]')
    $value = [regex]::Replace($value, '(?<![0-9A-Za-z:])[0-9A-Za-z:.]*:[0-9A-Za-z:.]*(?![0-9A-Za-z:])', [Text.RegularExpressions.MatchEvaluator]{ param($m)
        $address = $null; $candidate = $m.Value.TrimEnd('.', ',')
        if ([Net.IPAddress]::TryParse($candidate, [ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { return '[redacted]' + $m.Value.Substring($candidate.Length) }
        return $m.Value
    })
    $value = [regex]::Replace($value, '\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b', '[redacted]')
    return [regex]::Replace($value, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[redacted]')
}

function ConvertTo-CoreChecks([object[]]$Rows) {
    $definitions = @(Get-CoreCheckDefinitions); $seen = @{}; $valid = $true
    foreach ($row in $Rows) {
        if ($row -isnot [string] -or [string]::IsNullOrWhiteSpace($row)) { $valid=$false; continue }
        $parts = $row -split '=', 2
        if ($parts.Count -ne 2 -or $definitions.name -cnotcontains $parts[0] -or $seen.ContainsKey($parts[0])) { $valid=$false; continue }
        $fields = $parts[1] -split ':', 2
        if ($fields[0] -cnotin @('ok','warn','fail','unknown')) { $valid=$false; continue }
        $seen[$parts[0]] = @{ status=$fields[0]; detail=$(if($fields.Count -eq 2){Protect-CoreText $fields[1]}else{''}) }
    }
    if ($seen.Count -ne 14) { $valid=$false }
    $checks = @(foreach ($definition in $definitions) {
        $status='unknown'; $detail='检查输出未通过完整性验证'
        if($valid) { $status=$seen[$definition.name].status; $detail=$seen[$definition.name].detail }
        $blocking=$status -ne 'ok' -and -not ($status -eq 'warn' -and $definition.id -in @('ip_consistency','asn'))
        [pscustomobject][ordered]@{ id=$definition.id; name=$definition.name; status=$status; blocking=[bool]$blocking; detail=$detail }
    })
    return [pscustomobject]@{ valid=$valid; checks=$checks; canLaunch=[bool]($valid -and @($checks | Where-Object blocking).Count -eq 0) }
}

function Write-CoreActivity([guid]$Id, [string]$Command, [string]$Phase) {
    $activity=[ordered]@{ schemaVersion=1; operationId=$Id.ToString('D'); command=$Command; phase=$Phase; ownerPid=$PID }
    Write-AtomicState "$BASE\operation.json" (ConvertTo-Json -InputObject $activity -Compress)
}

function Remove-CoreActivity { if([IO.File]::Exists("$BASE\operation.json")){ [IO.File]::Delete("$BASE\operation.json") } }

function Get-CoreOperationStatus {
    $state=[ordered]@{ current='none'; phase='idle'; recoveryRequired=$false; activeOperationId=$null; transactionPhase=$null }
    $invalid=$false
    try { $state.current=Get-CurrentAccount } catch { $invalid=$true }
    $handle=$null; $busy=$false
    if([IO.File]::Exists("$BASE\operation.lock")) {
        try { $handle=[IO.File]::Open("$BASE\operation.lock",[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch [IO.IOException] { $busy=$true }
        catch { $invalid=$true }
    }
    try {
        $journal=$null; $activity=$null
        if([IO.File]::Exists("$BASE\transaction.json")){ try{$journal=[IO.File]::ReadAllText("$BASE\transaction.json") | ConvertFrom-Json -ErrorAction Stop}catch{$invalid=$true} }
        if($busy -and [IO.File]::Exists("$BASE\operation.json")){ try{$activity=[IO.File]::ReadAllText("$BASE\operation.json") | ConvertFrom-Json -ErrorAction Stop}catch{} }
        $residue=@("$BASE\installer-maintenance.json","$BASE\operation.lease.json","$BASE\transaction.json","$DATA.new","$DATA.previous","$DATA.claude-switch-staging","$BASE\accounts\A.new","$BASE\accounts\A.previous","$BASE\accounts\B.new","$BASE\accounts\B.previous")
        $pending=$invalid -or @($residue | Where-Object{Test-CoreRecoveryEntry $_}).Count -gt 0
        if($busy -or $pending){
            $state.phase=if($busy){'running'}else{'recoveryRequired'}; $state.recoveryRequired=-not $busy
            $state.activeOperationId=[guid]::Empty.ToString('D'); $state.transactionPhase='unverified'
            foreach($record in @($journal,$activity)){
                $guid=[guid]::Empty
                if($null -ne $record -and $record.schemaVersion -eq 1 -and [guid]::TryParseExact([string]$record.operationId,'D',[ref]$guid) -and $guid -ne [guid]::Empty -and $record.operationId -ceq $guid.ToString('D')){
                    $state.activeOperationId=$guid.ToString('D')
                    if($record.phase -cin @('started','archived','prepared','replacing','activeReplaced','committed','checking','repairing')){$state.transactionPhase=$record.phase}
                    break
                }
            }
        }
        return [pscustomobject]$state
    } finally { if($null -ne $handle){$handle.Dispose()} }
}

function Invoke-CoreRequest([string]$Command, [string]$Target, [string]$OperationId) {
    $script:ProtocolExitCode=0; $id=[guid]::Empty
    $result=[ordered]@{ schemaVersion=1; operationId=$OperationId; command=$Command; success=$false; code='invalid-arguments'; message='请求参数无效' }
    if(-not [guid]::TryParseExact($OperationId,'D',[ref]$id) -or $id -eq [guid]::Empty -or $OperationId -cne $id.ToString('D') -or $Command -cnotin @('checkdetail','status','fix','switch') -or ($Command -eq 'switch' -and $Target -cnotin @('A','B')) -or ($Command -ne 'switch' -and $Target)){
        $script:ProtocolExitCode=64; return [pscustomobject]$result
    }
    $result.code='ok'; $result.message='操作完成'
    try {
        if($Command -eq 'status'){
            $state=Get-CoreOperationStatus
            foreach($property in $state.PSObject.Properties){$result[$property.Name]=$property.Value}
            $result.success=-not $state.recoveryRequired
            if($state.recoveryRequired){$script:ProtocolExitCode=3; $result.code='recovery-required'; $result.message='请保留账号及 .new/.previous 恢复材料，核实事务后再操作'}
        } elseif($Command -eq 'checkdetail'){
            New-Item -ItemType Directory -Force -Path "$BASE\accounts" -ErrorAction Stop | Out-Null
            $handle=Enter-OperationLock
            if($null -eq $handle){$script:ProtocolExitCode=2; $assessment=ConvertTo-CoreChecks @(); $result.code='busy'; $result.message='另一个操作正在处理'}
            else {
                try {
                    Write-CoreActivity $id $Command 'checking'
                    $assessment=ConvertTo-CoreChecks @(Invoke-CheckDetail *>&1)
                    $cache=@($assessment.checks | ForEach-Object{"$($_.name)=$($_.status):$($_.detail)"}) -join "`n"
                    Write-AtomicState "$BASE\last-check.txt" ($cache -replace '=unknown:', '=fail:')
                    $result.success=$assessment.canLaunch
                    if(-not $assessment.valid){$script:ProtocolExitCode=1; $result.code='invalid-checks'; $result.message='检查输出不完整或格式无效，禁止启动'}
                    elseif(-not $assessment.canLaunch){$script:ProtocolExitCode=1; $result.code='blocked'; $result.message='安全检查存在阻断项'}
                } finally { Remove-CoreActivity; Exit-OperationLock -Handle $handle }
            }
            $result.checks=@($assessment.checks); $result.canLaunch=[bool]($result.success -and $assessment.canLaunch)
        } elseif($Command -eq 'switch'){
            New-Item -ItemType Directory -Force -Path "$BASE\accounts" -ErrorAction Stop | Out-Null
            $null=@(Invoke-Switch -Target $Target -OperationId $id *>&1)
            $script:ProtocolExitCode=$script:SwitchExitCode
            $state=Get-CoreOperationStatus
            foreach($property in $state.PSObject.Properties){$result[$property.Name]=$property.Value}
            $result.success=$script:ProtocolExitCode -eq 0
            if($result.success){$result.phase='completed'; $result.message='账号已切换并通过当次启动检查'}
            elseif($state.recoveryRequired){$result.code='recovery-required'; $result.message='切换未完成；保留所有恢复材料，核实后重试'}
            elseif($script:ProtocolExitCode -eq 2){$result.code='busy'; $result.message='另一个操作正在处理'}
            else{$result.code='blocked'; $result.message='Claude 未启动；请重新检查，当前账号以返回状态为准'}
        } else {
            New-Item -ItemType Directory -Force -Path "$BASE\accounts" -ErrorAction Stop | Out-Null
            $fixOutput=@(Invoke-FixCommand -OperationId $id *>&1); $script:ProtocolExitCode=$script:CoreExitCode; $result.success=$script:ProtocolExitCode -eq 0
            if(-not $result.success){
                if($script:ProtocolExitCode -eq 4){$result.code='cancelled'; $result.message='修复未完成或授权取消；请重新检查实际状态'}
                elseif($script:ProtocolExitCode -eq 5){$result.code='migration-required'; $result.message='旧版 ClaudeBodyguard 迁移未完成；旧任务保持不变。请重新运行修复并检查管理员授权与迁移校验结果。'}
                elseif($script:ProtocolExitCode -eq 2){$result.code='busy'; $result.message='修复未完成或授权取消；请重新检查实际状态'}
                else{
                    $result.code='fix-failed'; $result.message='修复未完成或授权取消；请重新检查实际状态'
                    $diagnostic=@($fixOutput | Where-Object { $_ -is [string] -and $_ -match '^FIX:.*(FAIL|✗|无法|未恢复|未完全|未找到)' } | Select-Object -Last 1)
                    if ($diagnostic.Count -eq 1) { $result.message=Protect-CoreText $diagnostic[0] }
                }
            }
        }
    } catch {
        $script:ProtocolExitCode=1; $result.success=$false; $result.code='operation-failed'; $result.message='操作未完成；未验证的状态不能用于启动'
        if($Command -eq 'checkdetail'){$assessment=ConvertTo-CoreChecks @(); $result.checks=@($assessment.checks); $result.canLaunch=$false}
        if($Command -in @('status','switch')){$state=Get-CoreOperationStatus; foreach($property in $state.PSObject.Properties){$result[$property.Name]=$property.Value}}
    }
    return [pscustomobject]$result
}

function Get-ReleaseInfo {
    $current = Get-AppVersion
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # GitHub 要求 User-Agent;PowerShell 5.1 的 -Headers 不允许改它,-UserAgent 等价写入请求头
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/YOURSJEYO/claude-switcher/releases/latest' -UserAgent 'ClaudeSwitcher' -TimeoutSec 8
        $latest = ([string]$rel.tag_name).Trim() -replace '^[vV]', ''
        if (-not $latest) { throw '无法解析最新版本号' }

        $zip = @($rel.assets) | Where-Object { $_ -and $_.name -like '*-windows.zip' } | Select-Object -First 1
        $sums = @($rel.assets) | Where-Object { $_ -and $_.name -eq 'SHA256SUMS-release.txt' } | Select-Object -First 1
        $zipUrl = if ($zip) { [string]$zip.browser_download_url } else { '' }
        $sumsUrl = if ($sums) { [string]$sums.browser_download_url } else { '' }
        $pageUrl = [string]$rel.html_url
        $status = if ((Compare-Version $latest $current) -gt 0) { 'update_available' } else { 'latest' }

        if ($status -eq 'update_available' -and (-not (Test-GitHubDownloadUrl $zipUrl) -or -not (Test-GitHubDownloadUrl $sumsUrl))) {
            return @{ status = 'error'; current = $current; latest = $latest; zip = ''; sums = ''; page = ''; message = '更新资产缺失或下载地址不是 GitHub 官方域名' }
        }
        return @{ status = $status; current = $current; latest = $latest; zip = $zipUrl; sums = $sumsUrl; page = $pageUrl; message = '' }
    } catch {
        $msg = ([string]$_.Exception.Message) -replace '\r?\n', ' '
        if ($msg -match 'rate limit|API rate|403') { $msg = 'GitHub 接口限流，请稍后再试' }
        return @{ status = 'error'; current = $current; latest = ''; zip = ''; sums = ''; page = ''; message = $msg }
    }
}

function Write-ReleaseInfo($info) {
    switch ($info.status) {
        'update_available' {
            "STATUS=update_available"
            "CURRENT=$($info.current)"
            "LATEST=$($info.latest)"
            "ZIP_URL=$($info.zip)"
            "SUMS_URL=$($info.sums)"
            "PAGE_URL=$($info.page)"
        }
        'latest' {
            "STATUS=latest"
            "CURRENT=$($info.current)"
            "LATEST=$($info.latest)"
        }
        default {
            "STATUS=error"
            "MESSAGE=$(([string]$info.message) -replace '\r?\n', ' ')"
        }
    }
}

function Get-ScriptUpdateRestriction {
    if (-not (Import-CoreConfiguration)) {
        return [pscustomobject]@{Status='error';Message='用户配置无效，请先重新配置；未执行更新'}
    }
    if ($script:CoreConfigurationKind -ne 'Legacy') {
        return [pscustomobject]@{Status='unsupported';Message='原生安装不能使用脚本 ZIP 更新，请按原生版本升级说明操作'}
    }
    return $null
}

function Invoke-CheckUpdate {
    $restriction=Get-ScriptUpdateRestriction
    if ($null -ne $restriction) {
        "STATUS=$($restriction.Status)"
        "MESSAGE=$($restriction.Message)"
        return
    }
    Write-ReleaseInfo (Get-ReleaseInfo)
}

function Invoke-UpdateNow {
    $script:UpdateExitCode=1
    $restriction=Get-ScriptUpdateRestriction
    if ($null -ne $restriction) {
        "STATUS=$($restriction.Status)"
        "MESSAGE=$($restriction.Message)"
        return
    }
    $handle=Enter-OperationLock
    if ($null -eq $handle) {
        $script:UpdateExitCode=2
        'STATUS=busy'
        'MESSAGE=另一个核心操作正在运行，请稍后重试更新'
        return
    }
    try {
    # Setup can create config.json while this process waits for the same lock.
    $restriction=Get-ScriptUpdateRestriction
    if ($null -ne $restriction) {
        "STATUS=$($restriction.Status)"
        "MESSAGE=$($restriction.Message)"
        return
    }
    $residue=@("$BASE\installer-maintenance.json","$BASE\operation.lease.json","$BASE\transaction.json","$DATA.new","$DATA.previous","$DATA.claude-switch-staging","$BASE\accounts\A.new","$BASE\accounts\A.previous","$BASE\accounts\B.new","$BASE\accounts\B.previous")
    if (@($residue | Where-Object { Test-CoreRecoveryEntry $_ }).Count -gt 0) {
        $script:UpdateExitCode=3
        'STATUS=recovery_required'
        'MESSAGE=存在待恢复账号资料，已停止更新并保留恢复材料'
        return
    }
    $info = Get-ReleaseInfo
    if ($info.status -ne 'update_available') {
        if ($info.status -eq 'latest') { $script:UpdateExitCode=0 }
        Write-ReleaseInfo $info
        return
    }

    $previous = $info.current
    $tmp = Join-Path $env:TEMP ("claude-switcher-update-" + [guid]::NewGuid().ToString('N'))
    $files = @('claude-switch.ps1', 'claude-bodyguard.ps1', 'SwitcherUI.ps1')
    $backupDir = $null
    $backedUp = @{}
    $task = Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue
    $versionPath = Join-Path $BASE 'version.txt'
    $versionExisted = Test-Path -LiteralPath $versionPath
    $versionRaw = $null
    if ($versionExisted) {
        try { $versionRaw = [System.IO.File]::ReadAllText($versionPath) } catch { $versionExisted = $false }
    }

    try {
        New-Item -ItemType Directory -Force -Path $tmp -ErrorAction Stop | Out-Null

        $zipUrl = [string]$info.zip
        $sumsUrl = [string]$info.sums
        if (-not (Test-GitHubDownloadUrl $zipUrl)) { throw '更新包下载地址不是 GitHub 官方域名' }
        if (-not (Test-GitHubDownloadUrl $sumsUrl)) { throw '校验文件下载地址不是 GitHub 官方域名' }

        $zipName = [System.IO.Path]::GetFileName(([Uri]$zipUrl).AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($zipName)) { $zipName = 'windows-update.zip' }
        $zipPath = Join-Path $tmp $zipName
        $sumsPath = Join-Path $tmp 'SHA256SUMS-release.txt'
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop

        $expected = $null
        foreach ($line in Get-Content -LiteralPath $sumsPath -ErrorAction Stop) {
            if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') {
                $name = [System.IO.Path]::GetFileName($Matches[2].Trim())
                if ($name -eq $zipName) { $expected = $Matches[1].ToUpperInvariant(); break }
            }
        }
        if (-not $expected) { throw 'SHA256SUMS 中未找到更新包哈希' }
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        if ($actual -ne $expected) { throw '校验失败' }

        $extract = Join-Path $tmp 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force -ErrorAction Stop
        $newCore = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'claude-switch.ps1' -File -ErrorAction Stop | Select-Object -First 1
        if (-not $newCore) { throw '更新包中未找到 claude-switch.ps1' }
        $pkgDir = $newCore.Directory.FullName
        foreach ($fn in $files) {
            if (-not (Test-Path -LiteralPath (Join-Path $pkgDir $fn))) { throw "更新包缺少 $fn" }
        }

        # 保留当前安装的 4 项用户配置
        $currentText = [System.IO.File]::ReadAllText((Join-Path $BASE 'claude-switch.ps1'))
        $newText = [System.IO.File]::ReadAllText($newCore.FullName)
        foreach ($name in @('PROXY_MODE', 'COUNTRY_TARGET', 'TZ_TARGET', 'PROXY_GROUP')) {
            $value = Get-ScriptConfigValue $currentText $name
            if ($null -ne $value) { $newText = Set-ScriptConfigValue $newText $name ([string]$value) }
        }

        $safeVersion = if ($previous) { $previous -replace '[^0-9A-Za-z._-]', '_' } else { 'unknown' }
        $backupDir = Join-Path $BASE ("backup-" + $safeVersion + "-" + (Get-Date -Format 'yyyyMMddHHmmss'))
        New-Item -ItemType Directory -Force -Path $backupDir -ErrorAction Stop | Out-Null
        foreach ($fn in $files) {
            $src = Join-Path $BASE $fn
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $backupDir $fn) -Force -ErrorAction Stop
                $backedUp[$fn] = $true
            } else {
                $backedUp[$fn] = $false
            }
        }

        if ($task) { Stop-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue }

        $stagedCore = Join-Path $tmp 'claude-switch.new.ps1'
        [System.IO.File]::WriteAllText($stagedCore, $newText, (New-Object System.Text.UTF8Encoding($true)))
        Copy-Item -LiteralPath $stagedCore -Destination (Join-Path $BASE 'claude-switch.ps1') -Force -ErrorAction Stop
        foreach ($fn in @('claude-bodyguard.ps1', 'SwitcherUI.ps1')) {
            Copy-Item -LiteralPath (Join-Path $pkgDir $fn) -Destination (Join-Path $BASE $fn) -Force -ErrorAction Stop
        }
        [System.IO.File]::WriteAllText($versionPath, [string]$info.latest, (New-Object System.Text.UTF8Encoding($false)))
        if ($task) { Start-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction Stop }

        $script:UpdateExitCode=0
        "STATUS=updated"
        "LATEST=$($info.latest)"
        "PREVIOUS=$previous"
        "MESSAGE=更新完成"
    } catch {
        $reason = Protect-CoreText (([string]$_.Exception.Message) -replace '\r?\n', ' ')
        if ($backupDir -and (Test-Path -LiteralPath $backupDir)) {
            foreach ($fn in $files) {
                $dst = Join-Path $BASE $fn
                $bak = Join-Path $backupDir $fn
                if ($backedUp[$fn] -and (Test-Path -LiteralPath $bak)) {
                    Copy-Item -LiteralPath $bak -Destination $dst -Force -ErrorAction SilentlyContinue
                } elseif ($backedUp.ContainsKey($fn) -and -not $backedUp[$fn]) {
                    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                }
            }
            try {
                if ($versionExisted -and $null -ne $versionRaw) {
                    [System.IO.File]::WriteAllText($versionPath, $versionRaw, (New-Object System.Text.UTF8Encoding($false)))
                } else {
                    Remove-Item -LiteralPath $versionPath -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        if ($task) {
            try { Start-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue } catch {}
        }
        "STATUS=error"
        "MESSAGE=$reason"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    } finally { Exit-OperationLock -Handle $handle }
}


if($MyInvocation.InvocationName -ne '.') {
    if($Json){$response=Invoke-CoreRequest -Command $Command -Target $Target -OperationId $OperationId; ConvertTo-Json -InputObject $response -Depth 8 -Compress; exit $script:ProtocolExitCode}
    if($Command -cin @('checkdetail','fix','switch')){New-Item -ItemType Directory -Force -Path "$BASE\accounts" | Out-Null}
    switch -CaseSensitive ($Command) {
        'checkdetail' { Invoke-CheckCommand; exit $script:CoreExitCode }
        'status' { Invoke-Status; $state=Get-CoreOperationStatus; if($state.recoveryRequired){exit 3} }
        'fix' { Invoke-FixCommand | ForEach-Object{Protect-CoreText ([string]$_)}; exit $script:CoreExitCode }
        'switch' { Invoke-Switch -Target $Target | ForEach-Object{Protect-CoreText ([string]$_)}; exit $script:SwitchExitCode }
        'check-update' { Invoke-CheckUpdate }
        'update-now' { Invoke-UpdateNow; exit $script:UpdateExitCode }
        default { '用法: claude-switch.ps1 checkdetail|status|fix|switch A|B|check-update|update-now [-Json -OperationId <guid>]' }
    }
}
