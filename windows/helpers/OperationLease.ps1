# Operation lease protocol for serialized Windows setup work.
# This file is dot-sourced and must remain free of filesystem side effects at load time.

$script:OperationLeaseFileName = 'operation.lease.json'
$script:OperationLeaseMutexFileName = 'operation.lease.mutex'
$script:OperationLeaseSchemaVersion = 1
$script:OperationLeaseMinimumTtlSeconds = 0.0000001
$script:OperationLeaseMaximumTtlSeconds = 86400.0
$script:OperationLeaseMaximumFileBytes = 16384

function New-OperationLeaseResult {
    param(
        [bool]$Success,
        [string]$Code,
        [string]$Error = '',
        [object]$Lease = $null,
        [switch]$IncludeLease
    )
    $result = [ordered]@{
        Success = $Success
        Code = $Code
        Error = $Error
    }
    if ($IncludeLease) { $result['Lease'] = $Lease }
    return [pscustomobject]$result
}

function Get-OperationLeaseProperty {
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

function ConvertTo-OperationLeaseCanonicalBasePath {
    param([object]$BasePath)
    if ($BasePath -isnot [string] -or [string]::IsNullOrWhiteSpace($BasePath)) { return $null }
    if (-not [IO.Path]::IsPathRooted($BasePath)) { return $null }
    try {
        $resolved = [IO.Path]::GetFullPath($BasePath)
        $root = [IO.Path]::GetPathRoot($resolved)
        if ($resolved.Length -gt $root.Length) {
            $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $resolved = $resolved.TrimEnd($trimChars)
        }
        return $resolved
    } catch {
        return $null
    }
}

function Get-OperationLeasePath {
    param([string]$BasePath)
    return (Join-Path $BasePath $script:OperationLeaseFileName)
}

function Get-OperationLeaseMutexPath {
    param([string]$BasePath)
    return (Join-Path $BasePath $script:OperationLeaseMutexFileName)
}

function Enter-OperationLeaseMutationLock {
    param([string]$BasePath)
    $mutexPath = Get-OperationLeaseMutexPath $BasePath
    $stream = $null
    try {
        if ([IO.Directory]::Exists($mutexPath)) {
            return [pscustomobject]@{
                Success = $false
                Code = 'lease-lock-failed'
                Error = 'The operation lease mutation lock path is not a regular file.'
                Handle = $null
            }
        }
        $stream = [IO.File]::Open($mutexPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        return [pscustomobject]@{
            Success = $true
            Code = 'acquired'
            Error = ''
            Handle = $stream
        }
    } catch [IO.IOException] {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
        }
        return [pscustomobject]@{
            Success = $false
            Code = 'lease-lock-busy'
            Error = 'Another operation lease mutation is in progress.'
            Handle = $null
        }
    } catch {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
        }
        return [pscustomobject]@{
            Success = $false
            Code = 'lease-lock-failed'
            Error = 'The operation lease mutation lock could not be acquired safely.'
            Handle = $null
        }
    }
}

function Exit-OperationLeaseMutationLock {
    param([object]$Lock)
    if ($null -ne $Lock -and $null -ne $Lock.Handle -and $Lock.Handle -is [IO.FileStream]) {
        try { $Lock.Handle.Dispose() } catch { }
    }
}

function ConvertTo-OperationLeaseGuid {
    param([object]$Value)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -cnotmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $null }
    try {
        $guid = [Guid]::ParseExact($Value, 'D')
        return $guid.ToString('D')
    } catch {
        return $null
    }
}

function Test-OperationLeaseUserSid {
    param([object]$OwnerSid)
    if ($OwnerSid -isnot [string] -or [string]::IsNullOrWhiteSpace($OwnerSid)) { return $false }
    if ($OwnerSid -cnotmatch '^S-1-(?:5-21|12-1)(?:-[0-9]+){4}$') { return $false }
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($OwnerSid)
        $serviceOrGroupSids = @(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid,
            [System.Security.Principal.WellKnownSidType]::NetworkServiceSid,
            [System.Security.Principal.WellKnownSidType]::LocalServiceSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinUsersSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinGuestsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinPowerUsersSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinAccountOperatorsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinSystemOperatorsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinPrintOperatorsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinBackupOperatorsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinReplicatorSid,
            [System.Security.Principal.WellKnownSidType]::AccountRasAndIasServersSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinNetworkConfigurationOperatorsSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinRemoteDesktopUsersSid,
            [System.Security.Principal.WellKnownSidType]::AccountKrbtgtSid,
            [System.Security.Principal.WellKnownSidType]::AccountDomainAdminsSid,
            [System.Security.Principal.WellKnownSidType]::AccountDomainUsersSid,
            [System.Security.Principal.WellKnownSidType]::AccountDomainGuestsSid,
            [System.Security.Principal.WellKnownSidType]::AccountComputersSid,
            [System.Security.Principal.WellKnownSidType]::AccountControllersSid,
            [System.Security.Principal.WellKnownSidType]::AccountCertAdminsSid,
            [System.Security.Principal.WellKnownSidType]::AccountSchemaAdminsSid,
            [System.Security.Principal.WellKnownSidType]::AccountEnterpriseAdminsSid,
            [System.Security.Principal.WellKnownSidType]::AccountPolicyAdminsSid,
            [System.Security.Principal.WellKnownSidType]::AccountRasAndIasServersSid,
            [System.Security.Principal.WellKnownSidType]::WorldSid,
            [System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
            [System.Security.Principal.WellKnownSidType]::AnonymousSid
        )
        foreach ($wellKnownSid in $serviceOrGroupSids) {
            if ($sid.IsWellKnown($wellKnownSid)) { return $false }
        }

        return $true
    } catch {
        return $false
    }
}

function Test-OperationLeasePhase {
    param([object]$Phase)
    if ($Phase -isnot [string] -or [string]::IsNullOrWhiteSpace($Phase)) { return $false }
    if ($Phase.Length -gt 64 -or $Phase -cne $Phase.Trim()) { return $false }
    if ($Phase.Contains('..')) { return $false }
    return ($Phase -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$')
}

function ConvertTo-OperationLeasePositiveInt32 {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $type = $Value.GetType()
    if ($type -ne [int] -and $type -ne [long]) { return $null }
    try {
        $number = [int64]$Value
        if ($number -le 0 -or $number -gt [int]::MaxValue) { return $null }
        return [int]$number
    } catch {
        return $null
    }
}

function ConvertTo-OperationLeaseTtlSeconds {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $null }
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        if ($number -lt $script:OperationLeaseMinimumTtlSeconds -or $number -gt $script:OperationLeaseMaximumTtlSeconds) { return $null }
        return $number
    } catch {
        return $null
    }
}

function Get-OperationLeaseJsonTimestampValue {
    param([string]$Json, [string]$Name)
    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"([^"\\]*)"'
    $matches = [regex]::Matches($Json, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($matches.Count -ne 1) { return $null }
    return ConvertTo-OperationLeaseUtcTime $matches[0].Groups[1].Value
}

function ConvertTo-OperationLeaseUtcTime {
    param([object]$Value)
    if ($Value -isnot [string]) { return $null }
    if ($Value -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$') { return $null }
    try {
        $parsed = [DateTime]::MinValue
        $parsedOk = [DateTime]::TryParseExact(
            $Value,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )
        if (-not $parsedOk -or $parsed.Kind -ne [DateTimeKind]::Utc) { return $null }
        return $parsed.ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function ConvertTo-OperationLeaseUtcDateTime {
    param([string]$Value)
    try {
        $parsed = [DateTime]::MinValue
        $parsedOk = [DateTime]::TryParseExact(
            $Value,
            'O',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )
        if (-not $parsedOk -or $parsed.Kind -ne [DateTimeKind]::Utc) { return $null }
        return $parsed
    } catch {
        return $null
    }
}

function ConvertTo-OperationLeaseJson {
    param([object]$Lease)
    $record = [ordered]@{
        schemaVersion = 1
        operationId = [string]$Lease.OperationId
        ownerSid = [string]$Lease.OwnerSid
        sessionId = [int]$Lease.SessionId
        ownerPid = [int]$Lease.OwnerPid
        phase = [string]$Lease.Phase
        acquiredAt = [string]$Lease.AcquiredAt
        heartbeatAt = [string]$Lease.HeartbeatAt
        expiresAt = [string]$Lease.ExpiresAt
    }
    return (ConvertTo-Json -InputObject $record -Compress -Depth 3)
}

function Test-OperationLeaseStrictJsonText {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $false }
    $ws = '[ \t\r\n]*'
    $stringValue = '"(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*"'
    $numberValue = '-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?'
    $value = '(?:' + $stringValue + '|' + $numberValue + '|true|false|null)'
    $pattern = '^' + $ws + '\{' + $ws + '(?:' + $stringValue + $ws + ':' + $ws + $value + '(?:' + $ws + ',' + $ws + $stringValue + $ws + ':' + $ws + $value + ')*)?' + $ws + '\}' + $ws + '$'
    return [regex]::IsMatch($Json, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Read-OperationLeaseRecord {
    param([string]$BasePath)
    $leasePath = Get-OperationLeasePath $BasePath
    if (-not [IO.File]::Exists($leasePath)) {
        if ([IO.Directory]::Exists($leasePath)) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The lease path is not a regular file.' }
        }
        return [pscustomobject]@{ Status = 'missing'; Lease = $null; Error = 'No operation lease exists.' }
    }

    try {
        $file = New-Object IO.FileInfo($leasePath)
        if ($file.Length -le 0 -or $file.Length -gt $script:OperationLeaseMaximumFileBytes) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease size is invalid.' }
        }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease cannot be a reparse point.' }
        }

        $bytes = [IO.File]::ReadAllBytes($leasePath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease must not contain a UTF-8 BOM.' }
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $json = $utf8.GetString($bytes)
        if (-not (Test-OperationLeaseStrictJsonText $json)) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease must be strict JSON without comments, trailing commas, or unquoted keys.' }
        }
        $record = $json | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $record -or $record -is [array]) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease root must be an object.' }
        }

        $expectedProperties = @(
            'schemaVersion',
            'operationId',
            'ownerSid',
            'sessionId',
            'ownerPid',
            'phase',
            'acquiredAt',
            'heartbeatAt',
            'expiresAt'
        )
        $actualProperties = @($record.PSObject.Properties | ForEach-Object { $_.Name })
        if ($actualProperties.Count -ne $expectedProperties.Count) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease properties do not match schema version 1.' }
        }
        foreach ($name in $expectedProperties) {
            if ($actualProperties -cnotcontains $name) {
                return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease properties do not match schema version 1.' }
            }
            $keyPattern = '"' + [regex]::Escape($name) + '"\s*:'
            if ([regex]::Matches($json, $keyPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -ne 1) {
                return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease must not contain duplicate properties.' }
            }
        }

        $schemaVersion = $record.schemaVersion
        if (($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) -or [int64]$schemaVersion -ne 1) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease schema version is invalid.' }
        }

        $operationId = ConvertTo-OperationLeaseGuid $record.operationId
        if ($null -eq $operationId) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation id is not a canonical D-form GUID.' }
        }
        if (-not (Test-OperationLeaseUserSid $record.ownerSid)) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The owner SID is not a supported user SID.' }
        }
        $ownerSid = (New-Object System.Security.Principal.SecurityIdentifier([string]$record.ownerSid)).Value
        $sessionId = ConvertTo-OperationLeasePositiveInt32 $record.sessionId
        if ($null -eq $sessionId) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The session id must be a positive integer.' }
        }
        $ownerPid = ConvertTo-OperationLeasePositiveInt32 $record.ownerPid
        if ($null -eq $ownerPid) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The owner pid must be a positive integer.' }
        }
        if (-not (Test-OperationLeasePhase $record.phase)) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation phase is invalid.' }
        }

        $acquiredAt = Get-OperationLeaseJsonTimestampValue $json 'acquiredAt'
        $heartbeatAt = Get-OperationLeaseJsonTimestampValue $json 'heartbeatAt'
        $expiresAt = Get-OperationLeaseJsonTimestampValue $json 'expiresAt'
        if ($null -eq $acquiredAt -or $null -eq $heartbeatAt -or $null -eq $expiresAt) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease timestamps must be UTC round-trip values.' }
        }
        $acquiredDate = ConvertTo-OperationLeaseUtcDateTime $acquiredAt
        $heartbeatDate = ConvertTo-OperationLeaseUtcDateTime $heartbeatAt
        $expiresDate = ConvertTo-OperationLeaseUtcDateTime $expiresAt
        if ($null -eq $acquiredDate -or $null -eq $heartbeatDate -or $null -eq $expiresDate) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease timestamps are invalid.' }
        }
        if ($heartbeatDate -lt $acquiredDate -or $expiresDate -le $heartbeatDate) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease timestamp ordering is invalid.' }
        }
        $ttl = ($expiresDate - $heartbeatDate).TotalSeconds
        if ($ttl -lt $script:OperationLeaseMinimumTtlSeconds -or $ttl -gt $script:OperationLeaseMaximumTtlSeconds) {
            return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease ttl is outside the allowed range.' }
        }

        $lease = [pscustomobject]@{
            BasePath = $BasePath
            LeasePath = $leasePath
            SchemaVersion = 1
            OperationId = $operationId
            OwnerSid = $ownerSid
            SessionId = $sessionId
            OwnerPid = $ownerPid
            Phase = [string]$record.phase
            AcquiredAt = $acquiredAt
            HeartbeatAt = $heartbeatAt
            ExpiresAt = $expiresAt
        }
        $status = 'active'
        if ($expiresDate -le [DateTime]::UtcNow) { $status = 'stale' }
        return [pscustomobject]@{ Status = $status; Lease = $lease; Error = '' }
    } catch {
        return [pscustomobject]@{ Status = 'invalid'; Lease = $null; Error = 'The operation lease is not valid versioned JSON.' }
    }
}

function Write-OperationLeaseFileAtomic {
    param(
        [string]$BasePath,
        [string]$Json,
        [bool]$ReplaceExisting
    )
    $leasePath = Get-OperationLeasePath $BasePath
    $tempPath = Join-Path $BasePath ('.operation.lease.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        $stream = [IO.File]::Open($tempPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $bytes = $utf8.GetBytes($Json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if ($ReplaceExisting) {
            [IO.File]::Replace($tempPath, $leasePath, [NullString]::Value)
        } else {
            [IO.File]::Move($tempPath, $leasePath)
        }
        return [pscustomobject]@{ Success = $true; Error = '' }
    } catch {
        return [pscustomobject]@{ Success = $false; Error = 'The operation lease could not be written atomically.' }
    } finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch { }
        }
        try {
            if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
        } catch { }
    }
}

function ConvertTo-OperationLeaseIdentity {
    param([object]$Lease)
    $basePath = ConvertTo-OperationLeaseCanonicalBasePath (Get-OperationLeaseProperty $Lease 'BasePath')
    $operationId = ConvertTo-OperationLeaseGuid (Get-OperationLeaseProperty $Lease 'OperationId')
    $ownerSidValue = Get-OperationLeaseProperty $Lease 'OwnerSid'
    $sessionId = ConvertTo-OperationLeasePositiveInt32 (Get-OperationLeaseProperty $Lease 'SessionId')
    $ownerPid = ConvertTo-OperationLeasePositiveInt32 (Get-OperationLeaseProperty $Lease 'OwnerPid')
    if ($null -eq $basePath -or $null -eq $operationId -or $null -eq $sessionId -or $null -eq $ownerPid) { return $null }
    if (-not (Test-OperationLeaseUserSid $ownerSidValue)) { return $null }
    $ownerSid = (New-Object System.Security.Principal.SecurityIdentifier([string]$ownerSidValue)).Value
    return [pscustomobject]@{
        BasePath = $basePath
        LeasePath = Get-OperationLeasePath $basePath
        OperationId = $operationId
        OwnerSid = $ownerSid
        SessionId = $sessionId
        OwnerPid = $ownerPid
    }
}

function Test-OperationLeaseOwnerMatch {
    param([object]$Expected, [object]$Actual)
    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Expected.BasePath, [string]$Actual.BasePath)) { return $false }
    if (-not [StringComparer]::Ordinal.Equals([string]$Expected.OperationId, [string]$Actual.OperationId)) { return $false }
    if (-not [StringComparer]::Ordinal.Equals([string]$Expected.OwnerSid, [string]$Actual.OwnerSid)) { return $false }
    if ([int]$Expected.SessionId -ne [int]$Actual.SessionId) { return $false }
    if ([int]$Expected.OwnerPid -ne [int]$Actual.OwnerPid) { return $false }
    return $true
}

function New-OperationLease {
    param(
        [object]$BasePath,
        [object]$OperationId,
        [object]$OwnerSid,
        [object]$SessionId,
        [object]$OwnerPid,
        [object]$Phase,
        [object]$TtlSeconds = 30
    )
    $resolvedBase = ConvertTo-OperationLeaseCanonicalBasePath $BasePath
    if ($null -eq $resolvedBase) {
        return New-OperationLeaseResult $false 'invalid-base-path' 'BasePath must be an absolute path.'
    }
    $canonicalOperationId = ConvertTo-OperationLeaseGuid $OperationId
    if ($null -eq $canonicalOperationId) {
        return New-OperationLeaseResult $false 'invalid-operation-id' 'OperationId must be a canonical D-form GUID.'
    }
    if (-not (Test-OperationLeaseUserSid $OwnerSid)) {
        return New-OperationLeaseResult $false 'invalid-owner-sid' 'OwnerSid must be a supported non-service user SID.'
    }
    $validSessionId = ConvertTo-OperationLeasePositiveInt32 $SessionId
    if ($null -eq $validSessionId) {
        return New-OperationLeaseResult $false 'invalid-session-id' 'SessionId must be a positive integer.'
    }
    $validOwnerPid = ConvertTo-OperationLeasePositiveInt32 $OwnerPid
    if ($null -eq $validOwnerPid) {
        return New-OperationLeaseResult $false 'invalid-owner-pid' 'OwnerPid must be a positive integer.'
    }
    if (-not (Test-OperationLeasePhase $Phase)) {
        return New-OperationLeaseResult $false 'invalid-phase' 'Phase must be a bounded safe string.'
    }
    $validTtl = ConvertTo-OperationLeaseTtlSeconds $TtlSeconds
    if ($null -eq $validTtl) {
        return New-OperationLeaseResult $false 'invalid-ttl' 'TtlSeconds must be a bounded positive number.'
    }

    try {
        if (-not [IO.Directory]::Exists($resolvedBase)) {
            [void][IO.Directory]::CreateDirectory($resolvedBase)
        }
    } catch {
        return New-OperationLeaseResult $false 'lease-write-failed' 'The operation lease directory could not be created.'
    }

    $mutationLock = Enter-OperationLeaseMutationLock $resolvedBase
    if (-not $mutationLock.Success) {
        return New-OperationLeaseResult $false $mutationLock.Code $mutationLock.Error
    }

    try {
        $leasePath = Get-OperationLeasePath $resolvedBase
        if ([IO.Directory]::Exists($leasePath)) {
            return New-OperationLeaseResult $false 'lease-invalid' 'The operation lease path is not a regular file.'
        }
        if ([IO.File]::Exists($leasePath)) {
            $existing = Get-OperationLeaseStatus -BasePath $resolvedBase
            switch ($existing.Code) {
                'active' { return New-OperationLeaseResult $false 'lease-busy' 'An active operation lease already exists.' }
                'stale' { return New-OperationLeaseResult $false 'lease-stale' 'A stale operation lease requires recovery review.' }
                'invalid' { return New-OperationLeaseResult $false 'lease-invalid' 'An invalid operation lease requires recovery review.' }
                default { return New-OperationLeaseResult $false 'lease-invalid' 'The existing operation lease could not be validated.' }
            }
        }

        $ownerSidValue = (New-Object System.Security.Principal.SecurityIdentifier([string]$OwnerSid)).Value
        $now = [DateTime]::UtcNow
        $heartbeatAt = $now.ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        $expiresAt = $now.AddSeconds($validTtl).ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        $lease = [pscustomobject]@{
            BasePath = $resolvedBase
            LeasePath = $leasePath
            SchemaVersion = 1
            OperationId = $canonicalOperationId
            OwnerSid = $ownerSidValue
            SessionId = $validSessionId
            OwnerPid = $validOwnerPid
            Phase = [string]$Phase
            AcquiredAt = $heartbeatAt
            HeartbeatAt = $heartbeatAt
            ExpiresAt = $expiresAt
        }
        $json = ConvertTo-OperationLeaseJson $lease
        $written = Write-OperationLeaseFileAtomic -BasePath $resolvedBase -Json $json -ReplaceExisting $false
        if ($written.Success) {
            return New-OperationLeaseResult $true 'active' '' $lease -IncludeLease
        }

        if ([IO.Directory]::Exists($leasePath)) {
            return New-OperationLeaseResult $false 'lease-invalid' 'The operation lease path is not a regular file.'
        }
        if ([IO.File]::Exists($leasePath)) {
            $existing = Get-OperationLeaseStatus -BasePath $resolvedBase
            switch ($existing.Code) {
                'active' { return New-OperationLeaseResult $false 'lease-busy' 'An active operation lease already exists.' }
                'stale' { return New-OperationLeaseResult $false 'lease-stale' 'A stale operation lease requires recovery review.' }
                'invalid' { return New-OperationLeaseResult $false 'lease-invalid' 'An invalid operation lease requires recovery review.' }
                default { return New-OperationLeaseResult $false 'lease-invalid' 'The existing operation lease could not be validated.' }
            }
        }
        return New-OperationLeaseResult $false 'lease-write-failed' 'The operation lease could not be written atomically.'
    } catch {
        return New-OperationLeaseResult $false 'lease-write-failed' 'The operation lease could not be written safely.'
    } finally {
        Exit-OperationLeaseMutationLock $mutationLock
    }
}
function Get-OperationLeaseStatus {
    param([object]$BasePath)
    $resolvedBase = ConvertTo-OperationLeaseCanonicalBasePath $BasePath
    if ($null -eq $resolvedBase) {
        $result = New-OperationLeaseResult $false 'invalid-base-path' 'BasePath must be an absolute path.'
        Add-Member -InputObject $result -NotePropertyName Status -NotePropertyValue 'invalid'
        return $result
    }

    if ([IO.File]::Exists($resolvedBase) -and -not [IO.Directory]::Exists($resolvedBase)) {
        $invalidResult = New-OperationLeaseResult $false 'invalid' 'BasePath must identify a directory.'
        Add-Member -InputObject $invalidResult -NotePropertyName Status -NotePropertyValue 'invalid'
        return $invalidResult
    }

    $read = Read-OperationLeaseRecord $resolvedBase
    $success = $read.Status -eq 'active'
    $errorText = [string]$read.Error
    $result = New-OperationLeaseResult $success $read.Status $errorText $read.Lease -IncludeLease:($read.Status -eq 'active')
    Add-Member -InputObject $result -NotePropertyName Status -NotePropertyValue $read.Status
    return $result
}

function Renew-OperationLease {
    param(
        [object]$Lease,
        [object]$Phase,
        [object]$TtlSeconds = $null
    )
    $expected = ConvertTo-OperationLeaseIdentity $Lease
    if ($null -eq $expected) {
        return New-OperationLeaseResult $false 'lease-invalid' 'The supplied lease owner identity is invalid.'
    }

    $mutationLock = Enter-OperationLeaseMutationLock $expected.BasePath
    if (-not $mutationLock.Success) {
        return New-OperationLeaseResult $false $mutationLock.Code $mutationLock.Error
    }

    try {
        $read = Read-OperationLeaseRecord $expected.BasePath
        if ($read.Status -eq 'missing') {
            return New-OperationLeaseResult $false 'lease-missing' 'The operation lease no longer exists.'
        }
        if ($read.Status -eq 'invalid') {
            return New-OperationLeaseResult $false 'lease-invalid' 'The operation lease is invalid and requires recovery review.'
        }
        if (-not (Test-OperationLeaseOwnerMatch $expected $read.Lease)) {
            return New-OperationLeaseResult $false 'lease-owner-mismatch' 'Only the exact lease owner may renew it.'
        }
        if ($read.Status -eq 'stale') {
            return New-OperationLeaseResult $false 'lease-stale' 'The operation lease is stale and requires recovery review.'
        }
        if (-not (Test-OperationLeasePhase $Phase)) {
            return New-OperationLeaseResult $false 'invalid-phase' 'Phase must be a bounded safe string.'
        }

        if ($null -eq $TtlSeconds) {
            $oldHeartbeat = ConvertTo-OperationLeaseUtcDateTime $read.Lease.HeartbeatAt
            $oldExpires = ConvertTo-OperationLeaseUtcDateTime $read.Lease.ExpiresAt
            if ($null -eq $oldHeartbeat -or $null -eq $oldExpires) {
                return New-OperationLeaseResult $false 'lease-invalid' 'The operation lease ttl cannot be determined.'
            }
            $TtlSeconds = ($oldExpires - $oldHeartbeat).TotalSeconds
        }
        $validTtl = ConvertTo-OperationLeaseTtlSeconds $TtlSeconds
        if ($null -eq $validTtl) {
            return New-OperationLeaseResult $false 'invalid-ttl' 'TtlSeconds must be a bounded positive number.'
        }

        $now = [DateTime]::UtcNow
        $updated = [pscustomobject]@{
            BasePath = $read.Lease.BasePath
            LeasePath = $read.Lease.LeasePath
            SchemaVersion = 1
            OperationId = $read.Lease.OperationId
            OwnerSid = $read.Lease.OwnerSid
            SessionId = $read.Lease.SessionId
            OwnerPid = $read.Lease.OwnerPid
            Phase = [string]$Phase
            AcquiredAt = $read.Lease.AcquiredAt
            HeartbeatAt = $now.ToString('O', [Globalization.CultureInfo]::InvariantCulture)
            ExpiresAt = $now.AddSeconds($validTtl).ToString('O', [Globalization.CultureInfo]::InvariantCulture)
        }
        $json = ConvertTo-OperationLeaseJson $updated
        $written = Write-OperationLeaseFileAtomic -BasePath $expected.BasePath -Json $json -ReplaceExisting $true
        if (-not $written.Success) {
            return New-OperationLeaseResult $false 'lease-write-failed' 'The operation lease could not be renewed atomically.'
        }
        return New-OperationLeaseResult $true 'active' '' $updated -IncludeLease
    } catch {
        return New-OperationLeaseResult $false 'lease-renew-failed' 'The operation lease could not be renewed safely.'
    } finally {
        Exit-OperationLeaseMutationLock $mutationLock
    }
}

function Close-OperationLease {
    param([object]$Lease)
    $expected = ConvertTo-OperationLeaseIdentity $Lease
    if ($null -eq $expected) {
        return New-OperationLeaseResult $false 'lease-invalid' 'The supplied lease owner identity is invalid.'
    }

    $mutationLock = Enter-OperationLeaseMutationLock $expected.BasePath
    if (-not $mutationLock.Success) {
        return New-OperationLeaseResult $false $mutationLock.Code $mutationLock.Error
    }

    try {
        $read = Read-OperationLeaseRecord $expected.BasePath
        if ($read.Status -eq 'missing') {
            return New-OperationLeaseResult $false 'lease-missing' 'The operation lease no longer exists.'
        }
        if ($read.Status -eq 'invalid') {
            return New-OperationLeaseResult $false 'lease-invalid' 'The operation lease is invalid and requires recovery review.'
        }
        if (-not (Test-OperationLeaseOwnerMatch $expected $read.Lease)) {
            return New-OperationLeaseResult $false 'lease-owner-mismatch' 'Only the exact lease owner may close it.'
        }
        if ($read.Status -eq 'stale') {
            return New-OperationLeaseResult $false 'lease-stale' 'The operation lease is stale and requires recovery review.'
        }

        try {
            [IO.File]::Delete($expected.LeasePath)
            if ([IO.File]::Exists($expected.LeasePath)) {
                return New-OperationLeaseResult $false 'lease-close-failed' 'The operation lease could not be removed.'
            }
            return New-OperationLeaseResult $true 'closed' '' $read.Lease -IncludeLease
        } catch {
            return New-OperationLeaseResult $false 'lease-close-failed' 'The operation lease could not be removed.'
        }
    } catch {
        return New-OperationLeaseResult $false 'lease-close-failed' 'The operation lease could not be closed safely.'
    } finally {
        Exit-OperationLeaseMutationLock $mutationLock
    }
}