# Isolated installer/user-setup tests. This file never invokes system-setting cmdlets.
$ErrorActionPreference = 'Stop'
$script:Tests = New-Object System.Collections.ArrayList
$script:Failures = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-switcher-user-setup-tests-' + [guid]::NewGuid().Guid)
$script:HelperPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers\UserSetup.ps1'
$script:LeasePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers\OperationLease.ps1'
$script:MaintenancePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers\InstallerMaintenance.ps1'
. $script:HelperPath
if (Test-Path -LiteralPath $script:LeasePath -PathType Leaf) { . $script:LeasePath }
if (Test-Path -LiteralPath $script:MaintenancePath -PathType Leaf) { . $script:MaintenancePath }

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

Add-Test 'operation lease protocol records owner identity and expires fail closed' {
    Assert-True (Test-Path -LiteralPath $script:LeasePath -PathType Leaf) 'operation lease helper must be present'
    Assert-True ($null -ne (Get-Command New-OperationLease -ErrorAction SilentlyContinue)) 'lease creation function must be exported'
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $id = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $created = New-OperationLease -BasePath $base -OperationId $id -OwnerSid 'S-1-5-21-1-2-3-1001' -SessionId 7 -OwnerPid 4321 -Phase 'setup' -TtlSeconds 30
    Assert-True $created.Success $created.Error
    Assert-Equal 'active' $created.Code 'new lease is active'
    $leasePath = Join-Path $base 'operation.lease.json'
    Assert-True (Test-Path -LiteralPath $leasePath -PathType Leaf) 'lease file must be written beside the core lock'
    $record = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json
    foreach ($field in @('schemaVersion','operationId','ownerSid','sessionId','ownerPid','phase','acquiredAt','heartbeatAt','expiresAt')) {
        Assert-True ($null -ne $record.PSObject.Properties[$field]) "lease must include $field"
    }
    Assert-Equal 1 $record.schemaVersion 'lease schema is versioned'
    Assert-Equal $id $record.operationId 'lease keeps canonical operation identity'
    Assert-Equal 'S-1-5-21-1-2-3-1001' $record.ownerSid 'lease is bound to the owner SID'
    Assert-Equal 7 $record.sessionId 'lease is bound to the interactive session'
    Assert-Equal 4321 $record.ownerPid 'lease records the owner process'

    $second = New-OperationLease -BasePath $base -OperationId '4f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f' -OwnerSid 'S-1-5-21-1-2-3-1002' -SessionId 8 -OwnerPid 4322 -Phase 'other' -TtlSeconds 30
    Assert-False $second.Success 'a live lease cannot be replaced'
    Assert-Equal 'lease-busy' $second.Code 'live lease contention is stable'

    $renewed = Renew-OperationLease -Lease $created.Lease -Phase 'system'
    Assert-True $renewed.Success $renewed.Error
    Assert-Equal 'active' $renewed.Code 'owner can renew a live lease'
    Assert-Equal 'system' $renewed.Lease.phase 'renewal updates the phase'

    $wrongRenew = Renew-OperationLease -Lease ([pscustomobject]@{ BasePath=$base; OperationId=$id; OwnerSid='S-1-5-21-1-2-3-1002'; SessionId=8; OwnerPid=4322 }) -Phase 'hijack'
    Assert-False $wrongRenew.Success 'another identity cannot renew the lease'
    Assert-Equal 'lease-owner-mismatch' $wrongRenew.Code 'wrong owner renewal is rejected'

    $closed = Close-OperationLease -Lease $created.Lease
    Assert-True $closed.Success $closed.Error
    Assert-Equal 'closed' $closed.Code 'owner can close its lease'
    Assert-False (Test-Path -LiteralPath $leasePath) 'closed lease must be removed'
}

Add-Test 'expired and malformed leases block setup without destructive replacement' {
    Assert-True (Test-Path -LiteralPath $script:LeasePath -PathType Leaf) 'operation lease helper must be present'
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $expired = [ordered]@{
        schemaVersion=1; operationId='3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'; ownerSid='S-1-5-21-1-2-3-1001'; sessionId=7; ownerPid=4321; phase='setup';
        acquiredAt='2026-01-01T00:00:00.0000000Z'; heartbeatAt='2026-01-01T00:00:00.0000000Z'; expiresAt='2026-01-01T00:00:01.0000000Z'
    }
    [IO.File]::WriteAllText((Join-Path $base 'operation.lease.json'), ($expired | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    $stale = Get-OperationLeaseStatus -BasePath $base
    Assert-Equal 'stale' $stale.Status 'expired lease is observable as stale'
    $blocked = Enter-UserSetupOperation -BasePath $base
    Assert-False $blocked.Success 'setup must fail closed on a stale lease'
    Assert-Equal 'core-recovery-required' $blocked.Code 'stale lease requires recovery review'
    Assert-True (Test-Path -LiteralPath (Join-Path $base 'operation.lease.json')) 'stale lease must not be deleted automatically'

    [IO.File]::WriteAllText((Join-Path $base 'operation.lease.json'), '{"schemaVersion":1,"operationId":"bad"}', (New-Object Text.UTF8Encoding($false)))
    $malformed = Get-OperationLeaseStatus -BasePath $base
    Assert-Equal 'invalid' $malformed.Status 'malformed lease is observable as invalid'
    $blockedAgain = Enter-UserSetupOperation -BasePath $base
    Assert-False $blockedAgain.Success 'malformed lease must block setup'
    Assert-Equal 'core-recovery-required' $blockedAgain.Code 'malformed lease requires recovery review'
}

Add-Test 'setup operation renews its lease across phase boundaries' {
    Assert-True ($null -ne (Get-Command Renew-UserSetupOperation -ErrorAction SilentlyContinue)) 'setup must expose a lease renewal boundary'
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $operation = Enter-UserSetupOperation -BasePath $base
    Assert-True $operation.Success $operation.Error
    try {
        $renewed = Renew-UserSetupOperation -Operation $operation -Phase 'system' -TtlSeconds 300
        Assert-True $renewed.Success $renewed.Error
        Assert-Equal 'active' $renewed.Code 'phase renewal must keep the lease active'
        Assert-Equal 'system' $renewed.Lease.Phase 'renewal must publish the current setup phase'
        $status = Get-OperationLeaseStatus -BasePath $base
        Assert-Equal 'active' $status.Status 'renewed lease remains active'
        Assert-Equal 'system' $status.Lease.Phase 'status must observe the renewed phase'
        $renewedFromHandle = Renew-UserSetupOperation -Operation $operation.Handle -Phase 'system-returned' -TtlSeconds 300
        Assert-True $renewedFromHandle.Success $renewedFromHandle.Error
        Assert-Equal 'system-returned' $renewedFromHandle.Lease.Phase 'legacy raw handle renewal must remain compatible'
    } finally {
        Exit-UserSetupOperation -Handle $operation.Handle -Lease $operation.Lease
    }
}

Add-Test 'stale lease cannot be closed by the ordinary exit path' {
    Assert-True ($null -ne (Get-Command Close-OperationLease -ErrorAction SilentlyContinue)) 'lease close function must be exported'
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $stale = [ordered]@{
        schemaVersion=1; operationId='3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'; ownerSid='S-1-5-21-1-2-3-1001'; sessionId=7; ownerPid=4321; phase='setup';
        acquiredAt='2026-01-01T00:00:00.0000000Z'; heartbeatAt='2026-01-01T00:00:00.0000000Z'; expiresAt='2026-01-01T00:00:01.0000000Z'
    }
    $leasePath = Join-Path $base 'operation.lease.json'
    [IO.File]::WriteAllText($leasePath, ($stale | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    $lease = [pscustomobject]@{ BasePath=$base; OperationId=$stale.operationId; OwnerSid=$stale.ownerSid; SessionId=7; OwnerPid=4321 }
    $closed = Close-OperationLease -Lease $lease
    Assert-False $closed.Success 'ordinary close must not delete stale recovery material'
    Assert-Equal 'lease-stale' $closed.Code 'stale close must require explicit recovery'
    Assert-True (Test-Path -LiteralPath $leasePath) 'stale lease must remain for recovery review'
}

Add-Test 'lease mutations fail closed under mutation lock contention' {
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $id = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $created = New-OperationLease -BasePath $base -OperationId $id -OwnerSid 'S-1-5-21-1-2-3-1001' -SessionId 7 -OwnerPid 4321 -Phase 'setup' -TtlSeconds 30
    Assert-True $created.Success $created.Error
    $leasePath = Join-Path $base 'operation.lease.json'
    $mutexPath = Join-Path $base 'operation.lease.mutex'
    $mutex = [IO.File]::Open($mutexPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $renewed = Renew-OperationLease -Lease $created.Lease -Phase 'blocked' -TtlSeconds 300
        Assert-False $renewed.Success 'renew must fail closed while the mutation lock is held'
        Assert-Equal 'lease-lock-busy' $renewed.Code 'renew contention must be observable'
        Assert-Equal 'setup' ((Get-OperationLeaseStatus -BasePath $base).Lease.Phase) 'renew contention must not change the lease'

        $closed = Close-OperationLease -Lease $created.Lease
        Assert-False $closed.Success 'close must fail closed while the mutation lock is held'
        Assert-Equal 'lease-lock-busy' $closed.Code 'close contention must be observable'
        Assert-True (Test-Path -LiteralPath $leasePath -PathType Leaf) 'close contention must preserve the lease'
    } finally {
        $mutex.Dispose()
    }

    Remove-Item -LiteralPath $mutexPath -Force
    $status = Get-OperationLeaseStatus -BasePath $base
    Assert-Equal 'active' $status.Status 'status remains read-only'
    Assert-False (Test-Path -LiteralPath $mutexPath) 'status must not create the mutation lock'

    $closed = Close-OperationLease -Lease $created.Lease
    Assert-True $closed.Success $closed.Error
    $mutex = [IO.File]::Open($mutexPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $new = New-OperationLease -BasePath $base -OperationId '4f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f' -OwnerSid 'S-1-5-21-1-2-3-1002' -SessionId 8 -OwnerPid 4322 -Phase 'other' -TtlSeconds 30
        Assert-False $new.Success 'creation must fail closed while the mutation lock is held'
        Assert-Equal 'lease-lock-busy' $new.Code 'creation contention must be observable'
        Assert-False (Test-Path -LiteralPath $leasePath) 'creation contention must not write a lease'
    } finally {
        $mutex.Dispose()
    }
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

Add-Test 'Inno upgrade and uninstall preserve per-user data by default' {
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
    Assert-Equal 3 $filesEntries.Count 'app payload and temporary maintenance broker are staged'
    $entry = [string](@($filesEntries | Where-Object { $_ -match '^Source: "\{#StageDir\}\\\*"; DestDir: "\{app\}";' })[0])
    Assert-True $entry.StartsWith('Source: "{#StageDir}\*"; DestDir: "{app}";') 'payload must be staged directly under the app directory'
    Assert-Match 'recursesubdirs\s+createallsubdirs' $entry 'payload subdirectories must be installed under the app directory'
    Assert-False ($entry -imatch 'uninsneveruninstall') 'program payload must be removed on uninstall'
    Assert-False $hasUninstallDelete 'uninstaller must not declare extra filesystem deletion outside managed app payload'
    $template = ($lines -join "`n") + "`n" + [IO.File]::ReadAllText((Join-Path $repoRoot 'windows/InstallerLifecycle.iss'))
    Assert-Match '(?im)^\s*Uninstallable=yes\s*$' $template 'uninstall must remain available'
    Assert-Match '(?im)^\s*DisableDirPage=yes\s*$' $template 'install location must stay fixed'
    Assert-Match '(?im)^\s*UsePreviousAppDir=no\s*$' $template 'a previous custom install path must not be reused'
    Assert-Match '(?s)function PrepareToInstall.*?\\ClaudeSwitcher.*?fixed Program Files directory' $template 'custom /DIR paths must fail before files are installed'
    Assert-Match '(?s)procedure CurPageChanged.*?wpFinished.*?ordinary desktop session' $template 'setup must guide elevated-terminal users back to their desktop session'
    Assert-False ($template -imatch '\.claude-switcher') 'uninstaller must not reference per-user switcher data'
    Assert-False ($template -imatch '(?im)(?:^|[\\/])accounts(?:[\\/]|$)') 'uninstaller must not reference account archives'
    Assert-False ($template -imatch '(?i)(?:\{userappdata\}|\{appdata\}|%APPDATA%)\\Claude(?:\\|"|$)') 'uninstaller must not reference the Claude data directory'
    Assert-Match '(?im)^\s*CloseApplications=yes\s*$' $template 'Setup must not replace payload while the WPF executable is in use'
    Assert-Match '(?s)function InitializeSetup.*?Result\s*:=\s*True;' $template 'existing installation must enter a validated maintenance path'
    Assert-Match '(?i)maintenance|broker|operation\.lock' $template 'upgrade must coordinate the operation lock'
    Assert-False ($template -imatch 'does not support safe in-place upgrades') 'upgrade must not be blanket-rejected'
    Assert-Match '(?s)function InitializeUninstall.*?Result\s*:=\s*True;' $template 'uninstall must remain available after preflight'
    Assert-Match '(?i)preserve|user data|delete' $template 'uninstall must state the data policy'
    Assert-False ($template -imatch '(?im)^\s*\[UninstallDelete\]') 'user data deletion must not use declarative Inno cleanup'
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

Add-Test 'installer maintenance preserves user data unless deletion is explicitly confirmed' {
    Assert-True (Test-Path -LiteralPath $script:MaintenancePath -PathType Leaf) 'maintenance broker must be present'
    Assert-True ($null -ne (Get-Command Invoke-InstallerUserDataCleanup -ErrorAction SilentlyContinue)) 'cleanup function must be exported'
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $claude = Join-Path $root 'Claude'
    New-Item -ItemType Directory -Force -Path $base, $claude | Out-Null
    Set-Content -LiteralPath (Join-Path $base 'config.json') -Value '{}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $claude 'session.json') -Value 'session' -Encoding utf8

    $withoutConfirmation = Invoke-InstallerUserDataCleanup -BasePath $base -ClaudeDataPath $claude
    Assert-False $withoutConfirmation.Success 'cleanup must require explicit confirmation'
    Assert-Equal 'confirmation-required' $withoutConfirmation.Code 'missing confirmation must be explicit'
    Assert-True (Test-Path -LiteralPath $base) 'default cleanup must preserve switcher data'
    Assert-True (Test-Path -LiteralPath $claude) 'default cleanup must preserve Claude data'

    $deleted = Invoke-InstallerUserDataCleanup -BasePath $base -ClaudeDataPath $claude -ConfirmDeleteUserData
    Assert-True $deleted.Success $deleted.Error
    Assert-False (Test-Path -LiteralPath $base) 'confirmed cleanup removes switcher data'
    Assert-False (Test-Path -LiteralPath $claude) 'confirmed cleanup removes Claude data'
}

Add-Test 'installer maintenance rejects reparse points before deleting user data' {
    Assert-True ($null -ne (Get-Command Invoke-InstallerUserDataCleanup -ErrorAction SilentlyContinue)) 'cleanup function must be exported'
    $root = New-Workspace
    $base = Join-Path $root '.claude-switcher'
    $claude = Join-Path $root 'Claude'
    New-Item -ItemType Directory -Force -Path $base, $claude | Out-Null
    Set-Content -LiteralPath (Join-Path $base 'config.json') -Value '{}' -Encoding utf8
    $link = Join-Path $base 'linked'
    try {
        New-Item -ItemType Junction -Path $link -Target $claude -ErrorAction Stop | Out-Null
    } catch {
        return
    }

    $result = Invoke-InstallerUserDataCleanup -BasePath $base -ClaudeDataPath $claude -ConfirmDeleteUserData
    Assert-False $result.Success 'reparse data must fail closed'
    Assert-Equal 'unsafe-user-data' $result.Code 'reparse rejection must be classified'
    Assert-True (Test-Path -LiteralPath $base) 'reparse rejection must preserve switcher data'
    Assert-True (Test-Path -LiteralPath $claude) 'reparse rejection must preserve Claude data'
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
