param()

# This file is dot-sourced by install.ps1 and test harnesses. Keep it side-effect free at load time.

$script:ClaudeSwitcherSetupSchemaVersion = 1
$script:ClaudeSwitcherProxyModes = @('auto','clash-verge','sing-box','clashx','surge','wireguard','other')
$script:ClaudeSwitcherCountryCultures = [ordered]@{
    US = 'en-US'
    JP = 'ja-JP'
    TW = 'zh-TW'
    HK = 'zh-HK'
    SG = 'en-SG'
    GB = 'en-GB'
    DE = 'de-DE'
    FR = 'fr-FR'
    KR = 'ko-KR'
    AU = 'en-AU'
    CA = 'en-CA'
}
$script:ClaudeSwitcherTimeZoneMap = @{
    'America/New_York' = 'Eastern Standard Time'
    'America/Chicago' = 'Central Standard Time'
    'America/Denver' = 'Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'America/Toronto' = 'Eastern Standard Time'
    'America/Vancouver' = 'Pacific Standard Time'
    'America/Phoenix' = 'Mountain Standard Time'
    'America/Anchorage' = 'Alaskan Standard Time'
    'Pacific/Honolulu' = 'Hawaiian Standard Time'
    'Asia/Singapore' = 'Singapore Standard Time'
    'Asia/Tokyo' = 'Tokyo Standard Time'
    'Asia/Seoul' = 'Korea Standard Time'
    'Asia/Taipei' = 'Taipei Standard Time'
    'Asia/Hong_Kong' = 'China Standard Time'
    'Europe/London' = 'GMT Standard Time'
    'Europe/Berlin' = 'W. Europe Standard Time'
    'Europe/Paris' = 'Romance Standard Time'
    'Australia/Sydney' = 'AUS Eastern Standard Time'
    'Australia/Melbourne' = 'AUS Eastern Standard Time'
    'America/St_Johns' = 'Newfoundland Standard Time'
    'America/Halifax' = 'Atlantic Standard Time'
    'America/Winnipeg' = 'Central Standard Time'
    'America/Edmonton' = 'Mountain Standard Time'
}

function New-UserSetupResult {
    param(
        [bool]$Success,
        [string]$Error = '',
        [hashtable]$Data = @{}
    )
    $result = @{ Success = $Success; Error = $Error }
    foreach ($key in $Data.Keys) { $result[$key] = $Data[$key] }
    return [pscustomobject]$result
}

function Get-UserSetupProperty {
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-SafeConfigurationText {
    param([AllowNull()][string]$Value, [int]$MaximumLength = 128)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value.Length -gt $MaximumLength -or $Value -ne $Value.Trim()) { return $false }
    if ($Value -match '[\x00-\x1f\x7f;`$"''<>|&{}\\/]') { return $false }
    if ($Value.Contains('..')) { return $false }
    return $true
}

function Get-CultureTarget {
    param([AllowNull()][string]$Country)
    if ([string]::IsNullOrWhiteSpace($Country)) { return '' }
    $normalized = $Country.ToUpperInvariant()
    if (-not $script:ClaudeSwitcherCountryCultures.Contains($normalized)) { return '' }
    return [string]$script:ClaudeSwitcherCountryCultures[$normalized]
}

function Get-WindowsTimeZoneId {
    param([AllowNull()][string]$TimeZoneId)
    if ([string]::IsNullOrWhiteSpace($TimeZoneId)) { return '' }
    if ($script:ClaudeSwitcherTimeZoneMap.ContainsKey($TimeZoneId)) {
        return [string]$script:ClaudeSwitcherTimeZoneMap[$TimeZoneId]
    }
    if (-not (Test-SafeConfigurationText $TimeZoneId 128)) { return '' }
    try {
        [void][TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
        return $TimeZoneId
    } catch {
        return ''
    }
}

function Test-UserSidForSetup {
    param([AllowNull()][string]$UserSid)
    if ([string]::IsNullOrWhiteSpace($UserSid) -or $UserSid -cnotmatch '^S-1-(?:5-21|12-1)(?:-[0-9]+){4}$') { return $false }
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($UserSid)
        return -not $sid.IsWellKnown([System.Security.Principal.WellKnownSidType]::LocalSystemSid) -and
            -not $sid.IsWellKnown([System.Security.Principal.WellKnownSidType]::NetworkServiceSid) -and
            -not $sid.IsWellKnown([System.Security.Principal.WellKnownSidType]::LocalServiceSid) -and
            -not $sid.IsWellKnown([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid) -and
            -not $sid.IsWellKnown([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid)
    } catch {
        return $false
    }
}

function Resolve-ProxyConfiguration {
    param(
        [AllowNull()][string]$DetectedMode,
        [AllowNull()][string]$RequestedMode,
        [AllowNull()][string]$ProxyGroup,
        [bool]$NonInteractive = $false,
        [scriptblock]$ReadHost
    )
    $mode = $RequestedMode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = $DetectedMode }
    if ([string]::IsNullOrWhiteSpace($mode)) {
        if ($NonInteractive -or $null -eq $ReadHost) {
            return New-UserSetupResult $false 'ProxyMode is required; proxy detection did not identify a supported client.'
        }
        $answer = & $ReadHost 'Proxy mode (auto|clash-verge|sing-box|clashx|surge|wireguard|other):'
        $mode = [string]$answer
    }
    $mode = $mode.Trim().ToLowerInvariant()
    if ($script:ClaudeSwitcherProxyModes -cnotcontains $mode) {
        return New-UserSetupResult $false 'ProxyMode must be one of the supported values.'
    }
    if ($mode -eq 'clash-verge') {
        if ([string]::IsNullOrWhiteSpace($ProxyGroup)) {
            if ($NonInteractive -or $null -eq $ReadHost) {
                return New-UserSetupResult $false 'ProxyGroup is required for clash-verge.'
            }
            $ProxyGroup = [string](& $ReadHost 'Clash Verge proxy group:')
        }
        if (-not (Test-SafeConfigurationText $ProxyGroup 128)) {
            return New-UserSetupResult $false 'ProxyGroup is invalid.'
        }
        $ProxyGroup = $ProxyGroup.Trim()
    } else {
        $ProxyGroup = ''
    }
    return New-UserSetupResult $true '' @{ ProxyMode = $mode; ProxyGroup = $ProxyGroup }
}

function Test-UserSetupConfiguration {
    param([object]$InputObject, [scriptblock]$ReadHost)
    $nonInteractive = [bool](Get-UserSetupProperty $InputObject 'NonInteractive')
    $proxy = Resolve-ProxyConfiguration -DetectedMode ([string](Get-UserSetupProperty $InputObject 'ProxyMode')) -RequestedMode ([string](Get-UserSetupProperty $InputObject 'ProxyMode')) -ProxyGroup ([string](Get-UserSetupProperty $InputObject 'ProxyGroup')) -NonInteractive $nonInteractive -ReadHost $ReadHost
    if (-not $proxy.Success) { return $proxy }
    $country = ([string](Get-UserSetupProperty $InputObject 'Country')).ToUpperInvariant()
    if ($country -eq 'CN' -or [string]::IsNullOrWhiteSpace($country)) {
        return New-UserSetupResult $false 'Country must be a supported non-CN two-letter country code.'
    }
    $culture = Get-CultureTarget $country
    if ([string]::IsNullOrWhiteSpace($culture)) {
        return New-UserSetupResult $false 'Country is not supported or has no deterministic culture mapping.'
    }
    $requestedCulture = [string](Get-UserSetupProperty $InputObject 'Culture')
    if (-not [string]::IsNullOrWhiteSpace($requestedCulture) -and $requestedCulture -cne $culture) {
        return New-UserSetupResult $false 'Culture does not match the reviewed country.'
    }
    $timeZone = Get-WindowsTimeZoneId ([string](Get-UserSetupProperty $InputObject 'TimeZoneId'))
    if ([string]::IsNullOrWhiteSpace($timeZone)) {
        return New-UserSetupResult $false 'TimeZoneId must be a known Windows time zone or mapped IANA time zone.'
    }
    return New-UserSetupResult $true '' @{
        ProxyMode = $proxy.ProxyMode
        ProxyGroup = $proxy.ProxyGroup
        Country = $country
        TimeZoneId = $timeZone
        Culture = $culture
    }
}

function Get-CoreRecoveryResiduePaths {
    param([string]$BasePath)
    $dataPath = Join-Path $env:APPDATA 'Claude'
    return @(
        (Join-Path $BasePath 'transaction.json'),
        ($dataPath + '.new'),
        ($dataPath + '.previous'),
        ($dataPath + '.claude-switch-staging'),
        (Join-Path $BasePath 'accounts\A.new'),
        (Join-Path $BasePath 'accounts\A.previous'),
        (Join-Path $BasePath 'accounts\B.new'),
        (Join-Path $BasePath 'accounts\B.previous')
    )
}

function Enter-UserSetupOperation {
    param([string]$BasePath)
    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        return New-UserSetupResult $false 'BasePath is required.'
    }
    if (-not [IO.Path]::IsPathRooted($BasePath)) {
        return New-UserSetupResult $false 'BasePath must be absolute.'
    }
    try {
        $resolvedBase = [IO.Path]::GetFullPath($BasePath)
    } catch {
        return New-UserSetupResult $false 'BasePath is invalid.'
    }

    $handle = $null
    try {
        if (-not [IO.Directory]::Exists($resolvedBase)) {
            [void][IO.Directory]::CreateDirectory($resolvedBase)
        }
        $lockPath = Join-Path $resolvedBase 'operation.lock'
        $residues = @(Get-CoreRecoveryResiduePaths $resolvedBase | Where-Object { Test-Path -LiteralPath $_ })
        if ($residues.Count -gt 0) {
            return New-UserSetupResult $false 'A pending core transaction or recovery residue blocks user setup.' @{ Code = 'core-recovery-required'; RecoveryRequired = $true }
        }

        try {
            $handle = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            return New-UserSetupResult $false 'The core operation lock is busy; retry after the current operation completes.' @{ Code = 'core-busy'; Retryable = $true }
        } catch [UnauthorizedAccessException] {
            return New-UserSetupResult $false 'The core operation lock cannot be opened safely.' @{ Code = 'core-lock-denied' }
        }

        $residues = @(Get-CoreRecoveryResiduePaths $resolvedBase | Where-Object { Test-Path -LiteralPath $_ })
        if ($residues.Count -gt 0) {
            $handle.Dispose()
            $handle = $null
            return New-UserSetupResult $false 'A pending core transaction or recovery residue blocks user setup.' @{ Code = 'core-recovery-required'; RecoveryRequired = $true }
        }
        return New-UserSetupResult $true '' @{ Handle = $handle }
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        return New-UserSetupResult $false 'The core operation lock could not be acquired safely.' @{ Code = 'core-lock-failed' }
    }
}

function Exit-UserSetupOperation {
    param($Handle)
    if ($null -ne $Handle -and $Handle -is [IO.FileStream]) {
        $Handle.Dispose()
    }
}

function Assert-NoCoreTransaction {
    param([string]$BasePath)
    $operation = Enter-UserSetupOperation -BasePath $BasePath
    if (-not $operation.Success) { return $operation }
    try {
        return New-UserSetupResult $true
    } finally {
        Exit-UserSetupOperation -Handle $operation.Handle
    }
}

function Read-UserConfiguration {
    param([string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath) -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return New-UserSetupResult $false 'Configuration file is missing.'
    }
    try {
        $item = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction Stop
        if ($item.Length -gt 65536 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return New-UserSetupResult $false 'Configuration file is unsafe.'
        }
        $config = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -is [array]) { return New-UserSetupResult $false 'Configuration root is invalid.' }
        $expected = @('schemaVersion','proxyMode','proxyGroup','country','timeZoneId','culture')
        $properties = @($config.PSObject.Properties)
        if ($properties.Count -ne $expected.Count) { return New-UserSetupResult $false 'Configuration properties are not the exact schema.' }
        foreach ($name in $expected) {
            if ($properties.Name -cnotcontains $name) { return New-UserSetupResult $false 'Configuration properties are not the exact schema.' }
        }
        $schema = $config.schemaVersion
        if (($schema -isnot [int] -and $schema -isnot [long]) -or [int64]$schema -ne 1) {
            return New-UserSetupResult $false 'Configuration schemaVersion is invalid.'
        }
        foreach ($name in @('proxyMode','proxyGroup','country','timeZoneId','culture')) {
            if ($config.$name -isnot [string]) { return New-UserSetupResult $false 'Configuration values must be strings.' }
        }
        $validated = Test-UserSetupConfiguration -InputObject ([ordered]@{
            NonInteractive = $true
            ProxyMode = $config.proxyMode
            ProxyGroup = $config.proxyGroup
            Country = $config.country
            TimeZoneId = $config.timeZoneId
            Culture = $config.culture
        })
        if (-not $validated.Success) { return $validated }
        return New-UserSetupResult $true '' @{ Configuration = $config }
    } catch {
        return New-UserSetupResult $false 'Configuration file is invalid JSON.'
    }
}

function ConvertTo-UserConfigurationJson {
    param($Validated)
    $config = [ordered]@{
        schemaVersion = 1
        proxyMode = [string]$Validated.ProxyMode
        proxyGroup = [string]$Validated.ProxyGroup
        country = [string]$Validated.Country
        timeZoneId = [string]$Validated.TimeZoneId
        culture = [string]$Validated.Culture
    }
    return (ConvertTo-Json -InputObject $config -Compress)
}

function Write-UserConfiguration {
    param([string]$ConfigPath, [object]$InputObject)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return New-UserSetupResult $false 'ConfigPath is required.' }
    $validated = Test-UserSetupConfiguration -InputObject $InputObject
    if (-not $validated.Success) { return $validated }
    $json = ConvertTo-UserConfigurationJson $validated
    $base = Split-Path -Parent $ConfigPath
    if ([string]::IsNullOrWhiteSpace($base)) { return New-UserSetupResult $false 'Configuration directory is invalid.' }
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        try {
            $existing = [IO.File]::ReadAllText($ConfigPath)
            if ($existing -ceq $json) { return New-UserSetupResult $true '' @{ Changed = $false; Configuration = $validated } }
        } catch {
            return New-UserSetupResult $false 'Existing configuration could not be read.'
        }
    }
    try {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) {
            New-Item -ItemType Directory -Path $base -Force -ErrorAction Stop | Out-Null
        }
        $temp = Join-Path $base ('.config.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
                [IO.File]::Replace($temp, $ConfigPath, $null)
            } else {
                [IO.File]::Move($temp, $ConfigPath)
            }
        } finally {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
        return New-UserSetupResult $true '' @{ Changed = $true; Configuration = $validated }
    } catch {
        return New-UserSetupResult $false 'Configuration could not be written atomically.'
    }
}

function Import-LegacyUserConfiguration {
    param([string]$LegacyScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($LegacyScriptPath) -and (Test-Path -LiteralPath $LegacyScriptPath)) {
        return New-UserSetupResult $false 'Legacy script configuration requires explicit review and is not executed.'
    }
    return New-UserSetupResult $false 'Legacy configuration was not found or cannot be imported automatically.'
}

function Invoke-OriginalUserSetup {
    param(
        [object]$InputObject,
        [string]$ConfigPath,
        [scriptblock]$ReadHost
    )
    $validated = Test-UserSetupConfiguration -InputObject $InputObject -ReadHost $ReadHost
    if (-not $validated.Success) { return $validated }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return New-UserSetupResult $false 'ConfigPath is required.' }
    $base = Split-Path -Parent $ConfigPath
    if ([string]::IsNullOrWhiteSpace($base)) { return New-UserSetupResult $false 'Configuration directory is invalid.' }

    $operation = Enter-UserSetupOperation -BasePath $base
    if (-not $operation.Success) { return $operation }
    try {
        return Write-UserConfiguration -ConfigPath $ConfigPath -InputObject $validated
    } finally {
        Exit-UserSetupOperation -Handle $operation.Handle
    }
}

function Invoke-ElevatedSystemSetup {
    param(
        [string]$HelperPath,
        [ValidateSet('set-time-zone','disable-ipv6','flush-dns','register-bodyguard-task','remove-bodyguard-task','repair-system')]
        [string]$Operation,
        [string]$UserSid,
        [int]$SessionId = 0,
        [AllowNull()][string]$TimeZoneId,
        [scriptblock]$Invoker
    )
    if (-not (Test-UserSidForSetup $UserSid)) {
        return New-UserSetupResult $false 'A supported non-service user SID is required.'
    }
    if ($SessionId -le 0) { return New-UserSetupResult $false 'A positive interactive session id is required.' }
    if ([string]::IsNullOrWhiteSpace($HelperPath) -or -not [IO.Path]::IsPathRooted($HelperPath)) {
        return New-UserSetupResult $false 'The protected helper path is required.'
    }
    $arguments = @('--operation', $Operation, '--user-sid', $UserSid, '--session-id', [string]$SessionId)
    if ($Operation -in @('set-time-zone','repair-system') -and -not [string]::IsNullOrWhiteSpace($TimeZoneId)) {
        $resolvedTimeZone = Get-WindowsTimeZoneId $TimeZoneId
        if ([string]::IsNullOrWhiteSpace($resolvedTimeZone)) { return New-UserSetupResult $false 'TimeZoneId is invalid.' }
        $arguments += @('--time-zone-id', ('"' + $resolvedTimeZone.Replace('"','""') + '"'))
    } elseif ($Operation -eq 'set-time-zone') {
        return New-UserSetupResult $false 'TimeZoneId is required for set-time-zone.'
    }
    $startInfo = [pscustomobject]@{ FilePath = $HelperPath; Arguments = ($arguments -join ' ') }
    try {
        if ($null -ne $Invoker) {
            $outcome = & $Invoker $startInfo
        } else {
            $process = Start-Process -FilePath $HelperPath -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
            $outcome = [pscustomobject]@{ Started = $true; Cancelled = $false; ExitCode = $process.ExitCode; Message = '' }
        }
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception) {
            $nativeErrorCode = Get-UserSetupProperty $exception 'NativeErrorCode'
            if ($exception.HResult -eq 1223 -or $null -ne $nativeErrorCode -and [int]$nativeErrorCode -eq 1223) {
                return New-UserSetupResult $false 'UAC was cancelled; the elevated stage can be retried.' @{ Cancelled = $true; Retryable = $true }
            }
            $exception = $exception.InnerException
        }
        return New-UserSetupResult $false 'The elevated system stage could not be started.' @{ Cancelled = $false; Retryable = $true }
    }
    if ($null -eq $outcome) { return New-UserSetupResult $false 'The elevated system stage returned no result.' @{ Retryable = $true } }
    if ([bool](Get-UserSetupProperty $outcome 'Cancelled')) {
        return New-UserSetupResult $false 'UAC was cancelled; the elevated stage can be retried.' @{ Cancelled = $true; Retryable = $true }
    }
    $exitCode = [int](Get-UserSetupProperty $outcome 'ExitCode')
    if ($exitCode -ne 0) {
        return New-UserSetupResult $false ('The elevated system stage failed with exit code ' + $exitCode + '.') @{ Retryable = $true; ExitCode = $exitCode }
    }
    return New-UserSetupResult $true
}
