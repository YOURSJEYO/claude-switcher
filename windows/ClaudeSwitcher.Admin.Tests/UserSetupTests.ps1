# Isolated installer/user-setup tests. This file never invokes system-setting cmdlets.
$ErrorActionPreference = 'Stop'
$script:Tests = New-Object System.Collections.ArrayList
$script:Failures = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-switcher-user-setup-tests-' + [guid]::NewGuid().Guid)
$script:HelperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers\UserSetup.ps1'

function Add-Test([string]$Name, [scriptblock]$Body) { [void]$script:Tests.Add([pscustomobject]@{ Name = $Name; Body = $Body }) }
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
function Assert-False([bool]$Condition, [string]$Message) { if ($Condition) { throw "ASSERT: $Message" } }
function Assert-Equal($Expected, $Actual, [string]$Message) { if ($Expected -ne $Actual) { throw "ASSERT: $Message (expected=$Expected actual=$Actual)" } }
function Assert-Match([string]$Pattern, [string]$Actual, [string]$Message) { if ($Actual -notmatch $Pattern) { throw "ASSERT: $Message (pattern=$Pattern actual=$Actual)" } }
function New-Workspace {
    $root = Join-Path $script:TestRoot ([guid]::NewGuid().Guid)
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}
function New-ValidationInput {
    return [ordered]@{
        NonInteractive = $true
        ProxyMode = 'clash-verge'
        ProxyGroup = 'Synthetic Group'
        Country = 'US'
        TimeZoneId = 'Eastern Standard Time'
        Culture = 'en-US'
    }
}

Add-Test 'noninteractive configuration never prompts' {
    $result = Test-UserSetupConfiguration -InputObject (New-ValidationInput) -ReadHost { throw 'must not prompt' }
    Assert-True $result.Success $result.Error
}

Add-Test 'noninteractive missing proxy mode fails before writes' {
    $root = New-Workspace
    $input = New-ValidationInput
    $input.ProxyMode = ''
    $result = Test-UserSetupConfiguration -InputObject $input -ReadHost { throw 'must not prompt' }
    Assert-False $result.Success 'missing proxy mode must fail'
    Assert-Match 'ProxyMode' $result.Error 'error must name the missing field'
    Assert-False (Test-Path (Join-Path $root '.claude-switcher')) 'validation must not write'
}

Add-Test 'proxy detection failure is not silently auto' {
    $result = Resolve-ProxyConfiguration -DetectedMode '' -RequestedMode '' -ProxyGroup '' -NonInteractive $true -ReadHost { throw 'must not prompt' }
    Assert-False $result.Success 'unresolved detection must fail'
    Assert-Match 'ProxyMode' $result.Error 'error must name ProxyMode'
    Assert-False ($result.ProxyMode -eq 'auto') 'auto must not be a silent fallback'
}

Add-Test 'missing clash proxy group fails' {
    $result = Resolve-ProxyConfiguration -DetectedMode 'clash-verge' -RequestedMode '' -ProxyGroup '' -NonInteractive $true -ReadHost { throw 'must not prompt' }
    Assert-False $result.Success 'missing clash group must fail'
    Assert-Match 'ProxyGroup' $result.Error 'error must name ProxyGroup'
}

Add-Test 'invalid clash proxy group fails' {
    foreach ($group in @('', ' ', "bad`nname", 'x;calc', '..\escape')) {
        $result = Resolve-ProxyConfiguration -DetectedMode 'clash-verge' -RequestedMode 'clash-verge' -ProxyGroup $group -NonInteractive $true -ReadHost { throw 'must not prompt' }
        Assert-False $result.Success ('invalid group must fail: ' + $group)
    }
}

Add-Test 'proxy mode must be a closed enum' {
    $result = Resolve-ProxyConfiguration -DetectedMode '' -RequestedMode 'made-up' -ProxyGroup 'G' -NonInteractive $true -ReadHost { throw 'must not prompt' }
    Assert-False $result.Success 'unknown mode must fail'
    Assert-Match 'ProxyMode' $result.Error 'error must name ProxyMode'
}

Add-Test 'CN or unknown country fails validation' {
    foreach ($country in @('CN', '', 'ZZZ', 'U1')) {
        $input = New-ValidationInput
        $input.Country = $country
        $result = Test-UserSetupConfiguration -InputObject $input -ReadHost { throw 'must not prompt' }
        Assert-False $result.Success ('country must fail: ' + $country)
        Assert-Match 'Country' $result.Error 'error must name Country'
    }
}

Add-Test 'unknown time zone fails validation' {
    $input = New-ValidationInput
    $input.TimeZoneId = 'Not A Real Time Zone'
    $result = Test-UserSetupConfiguration -InputObject $input -ReadHost { throw 'must not prompt' }
    Assert-False $result.Success 'unknown time zone must fail'
    Assert-Match 'TimeZoneId' $result.Error 'error must name TimeZoneId'
}

Add-Test 'culture mapping is deterministic and has no US fallback' {
    Assert-Equal 'en-US' (Get-CultureTarget -Country 'US') 'US mapping'
    Assert-Equal 'ja-JP' (Get-CultureTarget -Country 'JP') 'JP mapping'
    Assert-Equal 'zh-TW' (Get-CultureTarget -Country 'TW') 'TW mapping'
    Assert-Equal 'en-GB' (Get-CultureTarget -Country 'GB') 'GB mapping'
    Assert-Equal '' (Get-CultureTarget -Country 'ZZ') 'unknown must not default to US'
    Assert-Equal '' (Get-CultureTarget -Country 'CN') 'CN must not map'
}

Add-Test 'versioned config round-trips only validated scalar settings' {
    $root = New-Workspace
    $configPath = Join-Path $root '.claude-switcher\config.json'
    $input = New-ValidationInput
    $write = Write-UserConfiguration -ConfigPath $configPath -InputObject $input
    Assert-True $write.Success $write.Error
    $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-Equal 1 $json.schemaVersion 'schema version'
    Assert-Equal 'clash-verge' $json.proxyMode 'proxy mode'
    Assert-Equal 'Synthetic Group' $json.proxyGroup 'proxy group'
    Assert-Equal 'US' $json.country 'country'
    Assert-Equal 'Eastern Standard Time' $json.timeZoneId 'time zone'
    Assert-Equal 'en-US' $json.culture 'culture'
    Assert-False ($json.PSObject.Properties.Name -contains 'accounts') 'must not include account data'
    $read = Read-UserConfiguration -ConfigPath $configPath
    Assert-True $read.Success $read.Error
    Assert-Equal 'clash-verge' $read.Configuration.proxyMode 'round-trip mode'
}

Add-Test 'invalid configuration fails before creating its directory' {
    $root = New-Workspace
    $configPath = Join-Path $root '.claude-switcher\config.json'
    $input = New-ValidationInput
    $input.Country = 'CN'
    $write = Write-UserConfiguration -ConfigPath $configPath -InputObject $input
    Assert-False $write.Success 'CN config must not write'
    Assert-False (Test-Path (Join-Path $root '.claude-switcher')) 'directory must not be created'
}

Add-Test 'legacy script is never executed to migrate configuration' {
    $root = New-Workspace
    $legacy = Join-Path $root 'claude-switch.ps1'
    $marker = Join-Path $root 'executed.txt'
    Set-Content -LiteralPath $legacy -Value ("Set-Content -LiteralPath '" + $marker + "' -Value executed") -Encoding utf8
    $result = Import-LegacyUserConfiguration -LegacyScriptPath $legacy
    Assert-False $result.Success 'legacy migration must fail closed'
    Assert-False (Test-Path $marker) 'legacy script must not execute'
}

Add-Test 'transaction marker blocks operation acquisition' {
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    Set-Content -LiteralPath (Join-Path $base 'transaction.json') -Value '{}' -Encoding utf8
    $result = Enter-UserSetupOperation -BasePath $base
    Assert-False $result.Success 'pending transaction must block setup'
    Assert-Equal 'core-recovery-required' $result.Code 'transaction must be a recovery gate'
    Assert-True ($null -eq $result.Handle) 'failed acquisition must not expose a handle'
}

Add-Test 'operation lock is exclusive and nonblocking' {
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $first = Enter-UserSetupOperation -BasePath $base
    Assert-True $first.Success $first.Error
    Assert-True ($first.Handle -is [IO.FileStream]) 'successful acquisition must return a FileStream'
    $started = [Diagnostics.Stopwatch]::StartNew()
    $second = Enter-UserSetupOperation -BasePath $base
    $started.Stop()
    try {
        Assert-False $second.Success 'second acquisition must fail'
        Assert-Equal 'core-busy' $second.Code 'second acquisition must report busy'
        Assert-True ($started.ElapsedMilliseconds -lt 2000) 'busy acquisition must not wait'
    } finally {
        Exit-UserSetupOperation -Handle $first.Handle
    }
    $third = Enter-UserSetupOperation -BasePath $base
    try {
        Assert-True $third.Success $third.Error
    } finally {
        Exit-UserSetupOperation -Handle $third.Handle
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $base 'operation.lock') -PathType Leaf) 'lock filename must remain for core compatibility'
}

Add-Test 'core recovery residue blocks operation acquisition' {
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    New-Item -ItemType Directory -Force -Path (Join-Path $base 'accounts') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $base 'accounts\A.new') | Out-Null
    $result = Enter-UserSetupOperation -BasePath $base
    Assert-False $result.Success 'recovery residue must block setup'
    Assert-Equal 'core-recovery-required' $result.Code 'residue must be a recovery gate'
}

Add-Test 'operation lease remains unavailable until its identity lifecycle is safe' {
    $leasePath = Join-Path (Split-Path $script:HelperPath -Parent) 'OperationLease.ps1'
    Assert-False (Test-Path -LiteralPath $leasePath) 'do not ship an unverified operation lease helper'
}

Add-Test 'busy operation lock prevents setup writes' {
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $configPath = Join-Path $base 'config.json'
    $first = Enter-UserSetupOperation -BasePath $base
    Assert-True $first.Success $first.Error
    try {
        $result = Invoke-OriginalUserSetup -InputObject (New-ValidationInput) -ConfigPath $configPath -ReadHost { throw 'must not prompt' }
        Assert-False $result.Success 'busy lock must block setup'
        Assert-Equal 'core-busy' $result.Code 'setup must expose stable busy code'
        Assert-False (Test-Path -LiteralPath $configPath) 'config must remain absent'
    } finally {
        Exit-UserSetupOperation -Handle $first.Handle
    }
}

Add-Test 'repeated idempotent setup preserves valid config' {
    $root = New-Workspace
    $configPath = Join-Path $root '.claude-switcher\config.json'
    $first = Write-UserConfiguration -ConfigPath $configPath -InputObject (New-ValidationInput)
    Assert-True $first.Success $first.Error
    $before = Get-Content -LiteralPath $configPath -Raw
    $second = Write-UserConfiguration -ConfigPath $configPath -InputObject (New-ValidationInput)
    Assert-True $second.Success $second.Error
    $after = Get-Content -LiteralPath $configPath -Raw
    Assert-Equal $before $after 'idempotent write must be byte-identical'
}

Add-Test 'IANA time zones map only through the explicit table' {
    Assert-Equal 'Eastern Standard Time' (Get-WindowsTimeZoneId -TimeZoneId 'America/New_York') 'New York mapping'
    Assert-Equal 'Tokyo Standard Time' (Get-WindowsTimeZoneId -TimeZoneId 'Asia/Tokyo') 'Tokyo mapping'
    Assert-Equal 'Eastern Standard Time' (Get-WindowsTimeZoneId -TimeZoneId 'Eastern Standard Time') 'Windows ID accepted only when installed'
    Assert-Equal '' (Get-WindowsTimeZoneId -TimeZoneId 'Mars/Olympus_Mons') 'unknown IANA must fail'
    Assert-Equal '' (Get-WindowsTimeZoneId -TimeZoneId '') 'empty must fail'
}

Add-Test 'configuration rejects wrong schema and unknown properties before writes' {
    $root = New-Workspace
    $configPath = Join-Path $root '.claude-switcher\config.json'
    $base = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $badSchema = '{"schemaVersion":2,"proxyMode":"clash-verge","proxyGroup":"Synthetic Group","country":"US","timeZoneId":"Eastern Standard Time","culture":"en-US"}'
    Set-Content -LiteralPath $configPath -Value $badSchema -Encoding utf8
    $wrongSchema = Read-UserConfiguration -ConfigPath $configPath
    Assert-False $wrongSchema.Success 'wrong schema must fail'

    $unknown = '{"schemaVersion":1,"proxyMode":"clash-verge","proxyGroup":"Synthetic Group","country":"US","timeZoneId":"Eastern Standard Time","culture":"en-US","extra":true}'
    Set-Content -LiteralPath $configPath -Value $unknown -Encoding utf8
    $wrongProperties = Read-UserConfiguration -ConfigPath $configPath
    Assert-False $wrongProperties.Success 'unknown property must fail'
    Assert-Match 'properties' $wrongProperties.Error 'error must mention properties'
}

Add-Test 'original-user setup validates and writes config without prompting' {
    $root = New-Workspace
    $configPath = Join-Path $root '.claude-switcher\config.json'
    $result = Invoke-OriginalUserSetup -InputObject (New-ValidationInput) -ConfigPath $configPath -ReadHost { throw 'must not prompt' }
    Assert-True $result.Success $result.Error
    Assert-True (Test-Path -LiteralPath $configPath) 'config must be written'
}

Add-Test 'original-user setup blocks a pending transaction before any write' {
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    Set-Content -LiteralPath (Join-Path $base 'transaction.json') -Value '{}' -Encoding utf8
    $configPath = Join-Path $base 'config.json'
    $result = Invoke-OriginalUserSetup -InputObject (New-ValidationInput) -ConfigPath $configPath -ReadHost { throw 'must not prompt' }
    Assert-False $result.Success 'transaction must block setup'
    Assert-False (Test-Path -LiteralPath $configPath) 'config must not be written'
}

Add-Test 'Inno upgrade and uninstall fail closed while preserving per-user data' {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $issPath = Join-Path $repoRoot 'windows\ClaudeSwitcher.iss'
    Assert-True (Test-Path -LiteralPath $issPath -PathType Leaf) 'Inno template must exist'
    $lines = @([IO.File]::ReadAllLines($issPath))
    $filesEntries = New-Object System.Collections.ArrayList
    $inFiles = $false
    $hasUninstallDelete = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $inFiles = $matches[1] -ieq 'Files'
            if ($matches[1] -ieq 'UninstallDelete') { $hasUninstallDelete = $true }
            continue
        }
        if ($inFiles -and $trimmed -and -not $trimmed.StartsWith(';')) { [void]$filesEntries.Add($trimmed) }
    }
    Assert-Equal 1 $filesEntries.Count 'only the app payload is staged for a new installation'
    $entry = [string]$filesEntries[0]
    Assert-True $entry.StartsWith('Source: "{#StageDir}\*"; DestDir: "{app}";') 'payload must be staged directly under the app directory'
    Assert-Match 'recursesubdirs\s+createallsubdirs' $entry 'payload subdirectories must be installed under the app directory'
    Assert-False ($entry -imatch 'uninsneveruninstall') 'program payload must be removed on uninstall'
    Assert-False $hasUninstallDelete 'uninstaller must not declare extra filesystem deletion outside managed app payload'
    $template = $lines -join "`n"
    Assert-Match '(?im)^\s*Uninstallable=yes\s*$' $template 'uninstall must remain available'
    Assert-Match '(?im)^\s*DisableDirPage=yes\s*$' $template 'install location must stay fixed'
    Assert-Match '(?im)^\s*UsePreviousAppDir=no\s*$' $template 'a previous custom install path must not be reused'
    Assert-Match '(?s)function PrepareToInstall.*?\\ClaudeSwitcher.*?fixed Program Files directory' $template 'custom /DIR paths must fail before files are installed'
    Assert-Match '(?s)procedure CurPageChanged.*?wpFinished.*?ordinary desktop session' $template 'setup must guide elevated-terminal users back to their desktop session'
    Assert-False ($template -imatch '\.claude-switcher') 'uninstaller must not reference per-user switcher data'
    Assert-False ($template -imatch '(?im)(?:^|[\\/])accounts(?:[\\/]|$)') 'uninstaller must not reference account archives'
    Assert-False ($template -imatch '(?i)(?:\{userappdata\}|\{appdata\}|%APPDATA%)\\Claude(?:\\|"|$)') 'uninstaller must not reference the Claude data directory'
    Assert-Match '(?im)^\s*CloseApplications=yes\s*$' $template 'Setup must not replace payload while the WPF executable is in use'
    Assert-Match '(?s)function InitializeSetup.*?Result\s*:=\s*not\s+ExistingNativeInstall' $template 'existing installation must be refused before any wizard or file mutation'
    Assert-Match 'does not support safe in-place upgrades' $template 'upgrade refusal must explain the limitation'
    Assert-Match '(?s)function InitializeUninstall.*?Result\s*:=\s*False;.*?Safe uninstall is not supported' $template 'uninstall must be refused before mutation'
    Assert-Match 'No scheduled tasks or program files were changed' $template 'uninstall refusal must guarantee no task or app file changes'
    Assert-False ($template -imatch '(?i)OperationLease\.ps1|operation-lease\.|ExecAsOriginalUser.*?InitializeUninstall') 'unverified lease logic must not be advertised'
    Assert-False ($template -imatch '(?im)^\s*\[Uninstall(?:Run|Delete)\]') 'no uninstall mutation may be declared'
}
Add-Test 'UAC cancellation returns a visible retryable elevated-stage result' {
    $result = Invoke-ElevatedSystemSetup -HelperPath 'C:\synthetic\ClaudeSwitcher.Admin.exe' -Operation 'flush-dns' -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 1 -Invoker {
        param($startInfo)
        return [pscustomobject]@{ Started = $false; Cancelled = $true; ExitCode = 4; Message = 'UAC cancelled' }
    }
    Assert-False $result.Success 'cancelled UAC must not report success'
    Assert-True $result.Cancelled 'cancellation must remain visible'
    Assert-True $result.Retryable 'elevated stage must be retryable'
    Assert-Match 'elevated' $result.Error 'error must identify the elevated stage'
}

Add-Test 'nested UAC cancellation is detected through the exception chain' {
    $inner = New-Object ComponentModel.Win32Exception 1223
    $middle = New-Object InvalidOperationException 'launch wrapper', $inner
    $outer = New-Object Management.Automation.RuntimeException 'outer', $middle
    $result = Invoke-ElevatedSystemSetup -HelperPath 'C:\synthetic\ClaudeSwitcher.Admin.exe' -Operation 'repair-system' -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 1 -TimeZoneId 'Pacific Standard Time' -Invoker {
        param($startInfo)
        throw $outer
    }
    Assert-False $result.Success 'nested UAC cancellation must not report success'
    Assert-True $result.Cancelled 'nested UAC cancellation must remain visible'
    Assert-True $result.Retryable 'nested UAC cancellation must be retryable'
    Assert-Match 'UAC was cancelled' $result.Error 'nested cancellation must be explicit'
}

Add-Test 'operation acquisition rejects relative paths and leaves no handle' {
    $result = Enter-UserSetupOperation -BasePath '.claude-switcher'
    Assert-False $result.Success 'relative base path must fail'
    Assert-Equal 'BasePath must be absolute.' $result.Error 'relative path must fail closed'
    Assert-True ($null -eq $result.Handle) 'failed acquisition must not expose a handle'
}

Add-Test 'Entra user SID is accepted while service and well-known SIDs are rejected' {
    Assert-True (Test-UserSidForSetup 'S-1-12-1-1234567890-1234567890-1234567890-1234567890') 'Entra SID must be accepted'
    Assert-True (Test-UserSidForSetup 'S-1-5-21-1-2-3-1001') 'domain or local user SID must remain accepted'
    foreach ($sid in @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', 'S-1-5-32-544', 'S-1-5-32-545', 'S-1-12-1-1-2-3')) {
        Assert-False (Test-UserSidForSetup $sid) ('SID must be rejected: ' + $sid)
    }
}

Add-Test 'elevated invocation uses only the fixed scalar helper contract' {
    $captured = $null
    $result = Invoke-ElevatedSystemSetup -HelperPath 'C:\synthetic\ClaudeSwitcher.Admin.exe' -Operation 'set-time-zone' -UserSid 'S-1-5-21-1-2-3-1001' -SessionId 7 -TimeZoneId 'Pacific Standard Time' -Invoker {
        param($startInfo)
        $script:CapturedInvocation = $startInfo
        return [pscustomobject]@{ Started = $true; Cancelled = $false; ExitCode = 0; Message = '' }
    }
    Assert-True $result.Success $result.Error
    $captured = $script:CapturedInvocation
    Assert-Equal 'C:\synthetic\ClaudeSwitcher.Admin.exe' $captured.FilePath 'fixed helper path'
    Assert-Match '--operation set-time-zone' $captured.Arguments 'fixed operation'
    Assert-Match '--user-sid S-1-5-21-1-2-3-1001' $captured.Arguments 'scalar SID'
    Assert-Match '--session-id 7' $captured.Arguments 'scalar session'
    Assert-Match '--time-zone-id "Pacific Standard Time"' $captured.Arguments 'quoted scalar timezone'
    Assert-False ($captured.Arguments -match '--request-file|--path|--command|--script') 'no caller path or command flags'
}


New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null
try {
    . $script:HelperPath
    foreach ($test in $script:Tests) {
        try {
            & $test.Body
            Write-Host ('PASS {0}' -f $test.Name)
        } catch {
            $script:Failures++
            Write-Host ('FAIL {0}' -f $test.Name)
            Write-Host ('     {0}' -f $_.Exception.Message)
        }
    }
    $total = $script:Tests.Count
    Write-Host ('RESULT total={0} passed={1} failed={2}' -f $total, ($total - $script:Failures), $script:Failures)
    if ($script:Failures -gt 0) { exit 1 }
    exit 0
} finally {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
