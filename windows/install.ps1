# Claude Switcher user configuration. Run from an ordinary desktop session.
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [string]$ProxyMode,
    [string]$ProxyGroup,
    [string]$Country,
    [string]$TimeZoneId,
    [string]$Culture,
    [switch]$Preview,
    [switch]$Json,
    [switch]$Initialize,
    [switch]$RemoveUserTask,
    [switch]$RequireNoOtherTasks
)
$ErrorActionPreference = 'Stop'
$script:SetupSourceDirectory = $PSScriptRoot
$taskSetupLibrary = Join-Path $PSScriptRoot 'helpers\UserSetup.ps1'
if (-not (Test-Path -LiteralPath $taskSetupLibrary -PathType Leaf)) {
    $taskSetupLibrary = Join-Path (Split-Path $PSScriptRoot -Parent) 'helpers\UserSetup.ps1'
}
. $taskSetupLibrary

function New-InstallerFlowResult {
    param([int]$ExitCode, [string]$Stage, [string]$Code, [string]$Message)
    [pscustomobject]@{
        ExitCode=$ExitCode
        Result=[pscustomobject][ordered]@{schemaVersion=1;success=($ExitCode -eq 0);stage=$Stage;code=$Code;message=$Message}
    }
}

function Get-SetupIdentity {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal=New-Object Security.Principal.WindowsPrincipal($identity)
        $sid=$identity.User.Value
        $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
        if (-not (Test-UserSidForSetup $sid) -or $session -le 0) { throw 'Interactive user required.' }
        [pscustomobject]@{Sid=$sid;SessionId=$session;Elevated=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
    } finally { $identity.Dispose() }
}

function Get-GeoInfo {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers=@{'User-Agent'='claude-switcher-installer/1.0'}
    $countryTz=@{
        US='America/New_York'; JP='Asia/Tokyo'; TW='Asia/Taipei'; HK='Asia/Hong_Kong'
        SG='Asia/Singapore'; GB='Europe/London'; DE='Europe/Berlin'; FR='Europe/Paris'
        KR='Asia/Seoul'; AU='Australia/Sydney'; CA='America/Toronto'
    }
    $sources=@(
        @{Url='https://ipinfo.io/json';Country='country';Timezone='timezone'},
        @{Url='https://ipapi.co/json/';Country='country_code';Timezone='timezone'},
        @{Url='https://ifconfig.co/json';Country='country_iso';Timezone='timezone'}
    )
    $observations=New-Object 'System.Collections.Generic.List[object]'
    foreach($source in $sources) {
        try { $data=Invoke-RestMethod -Uri $source.Url -Headers $headers -TimeoutSec 8 -ErrorAction Stop }
        catch { continue }
        $country=[string](Get-UserSetupProperty $data $source.Country)
        if ($country -cnotmatch '^[A-Z]{2}$') { continue }
        $timezone=[string](Get-UserSetupProperty $data $source.Timezone)
        if ([string]::IsNullOrWhiteSpace($timezone)) { $timezone=$countryTz[$country] }
        $observations.Add([pscustomobject]@{Country=$country;Timezone=$timezone})
    }
    try {
        $trace=Invoke-WebRequest -Uri 'https://www.cloudflare.com/cdn-cgi/trace' -Headers $headers -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
        foreach($line in ([string]$trace.Content -split '\r?\n')) {
            if ($line -cmatch '^loc=([A-Z]{2})$') {
                $country=$Matches[1]
                $observations.Add([pscustomobject]@{Country=$country;Timezone=$countryTz[$country]})
                break
            }
        }
    } catch {}
    $countries=@($observations | Select-Object -ExpandProperty Country -Unique)
    if ($countries -contains 'CN') { throw 'CN egress observation is not supported.' }
    if ($countries.Count -gt 1) { throw 'Egress sources disagree; retry after confirming a consistent proxy route.' }
    foreach($observation in $observations) {
        if ((Get-CultureTarget $observation.Country) -and (Get-WindowsTimeZoneId $observation.Timezone)) { return $observation }
    }
    throw 'No supported egress observation is available.'
}

function Get-SetupEgress {
    # Only reviewed region scalars leave this function. Never print the raw response.
    $response=Get-GeoInfo
    $country=$response.Country
    $zone=Get-WindowsTimeZoneId $response.Timezone
    $culture=Get-CultureTarget $country
    if ($country -cnotmatch '^[A-Z]{2}$' -or $country -eq 'CN' -or -not $zone -or -not $culture) { throw 'Supported non-CN region required.' }
    [pscustomobject]@{Country=$country;TimeZoneId=$zone;Culture=$culture}
}

function Get-SetupDetectedProxyMode {
    foreach($parent in @($env:APPDATA,$env:LOCALAPPDATA)) {
        if (Test-Path -LiteralPath (Join-Path $parent 'io.github.clash-verge-rev.clash-verge-rev')) { return 'clash-verge' }
    }
    foreach($name in @('sing-box','ClashX','Surge')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $name.ToLowerInvariant() }
    }
    if (Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') { return 'wireguard' }
    return ''
}

function Test-SetupProtectedPath {
    param([string]$Path,[string]$Boundary)
    $cursor=[IO.Path]::GetFullPath($Path)
    $boundaryPath=[IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    if (-not $cursor.StartsWith($boundaryPath+'\',[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $mask=[Security.AccessControl.FileSystemRights]::WriteData -bor [Security.AccessControl.FileSystemRights]::AppendData -bor [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor [Security.AccessControl.FileSystemRights]::WriteAttributes -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    while ($true) {
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $acl=Get-Acl -LiteralPath $cursor -ErrorAction Stop
        if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { return $false }
        foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -eq 'Allow' -and $trusted -notcontains $rule.IdentityReference.Value) {
                $bits=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$rule.FileSystemRights),0)
                if (($rule.FileSystemRights -band $mask) -or ($bits -band [uint32]0x50000000)) { return $false }
            }
        }
        if ($cursor.TrimEnd('\').Equals($boundaryPath,[StringComparison]::OrdinalIgnoreCase)) { return $true }
        $cursor=Split-Path -Parent $cursor
    }
}

function Get-SetupProtectedPayload {
    try {
        $programFiles=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        $root=Join-Path $programFiles 'ClaudeSwitcher'
        $helper=Join-Path $root 'helpers\ClaudeSwitcher.Admin.exe'
        $application=Join-Path $root 'ClaudeSwitcher.exe'
        foreach($path in @($helper,$application,(Join-Path $root 'scripts\claude-bodyguard.ps1'),(Join-Path $root 'scripts\claude-switch.ps1'),(Join-Path $root 'scripts\install.ps1'))) {
            if (-not (Test-SetupProtectedPath $path $programFiles)) { return $null }
        }
        foreach($entry in @(Get-ChildItem -LiteralPath (Split-Path $helper -Parent) -Recurse -Force -ErrorAction Stop)) {
            if (-not (Test-SetupProtectedPath $entry.FullName $programFiles)) { return $null }
        }
        [pscustomobject]@{Helper=$helper;App=$application}
    } catch { return $null }
}

function Copy-SetupUserTemplates {
    param([string]$Destination)
    foreach($name in @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1')) {
        $text=[IO.File]::ReadAllText((Join-Path $script:SetupSourceDirectory $name))
        $target=Join-Path $Destination $name
        $temporary=Join-Path $Destination ('.setup.'+[guid]::NewGuid().ToString('N')+'.tmp')
        try {
            [IO.File]::WriteAllText($temporary,$text,(New-Object Text.UTF8Encoding($true)))
            if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary,$target,[NullString]::Value) }
            else { [IO.File]::Move($temporary,$target) }
        } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    # Keep the compatibility updater's installed-version contract without changing user configuration.
    $versionSrc = Join-Path $script:SetupSourceDirectory '..\VERSION'
    if (-not (Test-Path -LiteralPath $versionSrc -PathType Leaf)) { $versionSrc = Join-Path $script:SetupSourceDirectory 'VERSION' }
    $appVersion = 'unknown'
    if (Test-Path -LiteralPath $versionSrc -PathType Leaf) {
        $versionFile=Get-Item -LiteralPath $versionSrc -ErrorAction Stop
        if ($versionFile.Length -le 256 -and -not ($versionFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $candidate=[IO.File]::ReadAllText($versionSrc).Trim()
            if ($candidate -cmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$') { $appVersion=$candidate }
        }
    }
    [IO.File]::WriteAllText((Join-Path $Destination 'version.txt'),$appVersion,(New-Object Text.UTF8Encoding($false)))
}

if ($null -eq $script:NativeUpgradeSnapshots) {
    $script:NativeUpgradeSnapshots = @{}
}
function ConvertTo-NativeUpgradeCanonicalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { return $null }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $root.Length) {
            $trimChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            $full = $full.TrimEnd($trimChars)
        }
        return $full
    } catch { return $null }
}

function Test-NativeUpgradePathEqual {
    param([string]$Left, [string]$Right)
    $a = ConvertTo-NativeUpgradeCanonicalPath $Left
    $b = ConvertTo-NativeUpgradeCanonicalPath $Right
    return ($null -ne $a -and $null -ne $b -and $a.Equals($b, [StringComparison]::OrdinalIgnoreCase))
}

function Test-NativeUpgradePathWithin {
    param([string]$Path, [string]$Boundary)
    $candidate = ConvertTo-NativeUpgradeCanonicalPath $Path
    $root = ConvertTo-NativeUpgradeCanonicalPath $Boundary
    if ($null -eq $candidate -or $null -eq $root) { return $false }
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-NativeUpgradePathHasNoReparse {
    param([string]$Path, [string]$Boundary)
    $candidate = ConvertTo-NativeUpgradeCanonicalPath $Path
    $root = ConvertTo-NativeUpgradeCanonicalPath $Boundary
    if ($null -eq $candidate -or $null -eq $root -or -not (Test-NativeUpgradePathWithin $candidate $root)) { return $false }
    $cursor = $candidate
    while ($true) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            try {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            } catch { return $false }
        }
        if ($cursor.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $cursor = $parent
    }
}

function Test-NativeUpgradeRegularFile {
    param([string]$Path, [string]$Boundary)
    if (-not [IO.File]::Exists($Path)) { return $false }
    if (-not (Test-NativeUpgradePathHasNoReparse $Path $Boundary)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (-not $item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
    } catch { return $false }
}

function Get-NativeUpgradeExpectedBasePath {
    $profile = [string]$env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profile) -or -not [IO.Path]::IsPathRooted($profile)) { return $null }
    return ConvertTo-NativeUpgradeCanonicalPath (Join-Path $profile '.claude-switcher')
}

function Get-NativeUpgradeOperationHandle {
    param([object]$Operation)
    return Get-UserSetupProperty $Operation 'Handle'
}

function Get-NativeUpgradeOperationLease {
    param([object]$Operation)
    $lease = Get-UserSetupProperty $Operation 'Lease'
    if ($null -eq $lease) {
        $handle = Get-NativeUpgradeOperationHandle $Operation
        $lease = Get-UserSetupProperty $handle 'ClaudeSwitcherLease'
    }
    return $lease
}

function Get-NativeUpgradeSnapshotPath {
    param([object]$Snapshot)
    if ($null -eq $Snapshot) { return $null }
    if ($Snapshot -is [string]) { return [string]$Snapshot }
    foreach ($name in @('SnapshotPath','Path','snapshotPath')) {
        $value = Get-UserSetupProperty $Snapshot $name
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    $result = Get-UserSetupProperty $Snapshot 'Result'
    if ($null -ne $result) {
        foreach ($name in @('snapshotPath','SnapshotPath')) {
            $value = Get-UserSetupProperty $result $name
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        }
    }
    return $null
}
function Test-NativeUpgradeOperationBoundary {
    param([object]$Operation, [string]$BasePath)
    if ($null -eq $Operation) {
        return New-InstallerFlowResult 1 'user' 'operation_required' 'An active user setup operation is required.'
    }
    $resolvedBase = ConvertTo-NativeUpgradeCanonicalPath $BasePath
    $expectedBase = Get-NativeUpgradeExpectedBasePath
    if ($null -eq $resolvedBase -or $null -eq $expectedBase) {
        return New-InstallerFlowResult 1 'user' 'user_profile_unavailable' 'The current user profile path is unavailable.'
    }
    if (-not (Test-NativeUpgradePathEqual $resolvedBase $expectedBase)) {
        return New-InstallerFlowResult 1 'user' 'base_path_mismatch' 'Upgrade finalization must target the exact current user setup directory.'
    }
    if (-not [IO.Directory]::Exists($resolvedBase) -or -not (Test-NativeUpgradePathHasNoReparse $resolvedBase $resolvedBase)) {
        return New-InstallerFlowResult 1 'user' 'unsafe_template_path' 'The user setup directory is missing or unsafe.'
    }

    $handle = Get-NativeUpgradeOperationHandle $Operation
    $lease = Get-NativeUpgradeOperationLease $Operation
    if ($handle -isnot [IO.FileStream] -or $null -eq $lease) {
        return New-InstallerFlowResult 1 'user' 'operation_lock_not_held' 'The broker operation lock is not held.'
    }
    try {
        $null = $handle.Length
        $null = $handle.Name
    } catch {
        return New-InstallerFlowResult 1 'user' 'operation_lock_not_held' 'The broker operation lock is not held.'
    }

    $expectedLockPath = ConvertTo-NativeUpgradeCanonicalPath (Join-Path $resolvedBase 'operation.lock')
    $heldLockPath = ConvertTo-NativeUpgradeCanonicalPath ([string]$handle.Name)
    if ($null -eq $expectedLockPath -or $null -eq $heldLockPath -or -not (Test-NativeUpgradePathEqual $expectedLockPath $heldLockPath)) {
        return New-InstallerFlowResult 1 'user' 'operation_lock_not_held' 'The broker operation lock is not the expected lock.'
    }

    $probe = $null
    try {
        $probe = [IO.File]::Open($expectedLockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $probe.Dispose()
        $probe = $null
        return New-InstallerFlowResult 1 'user' 'operation_lock_not_held' 'The broker operation lock is not held.'
    } catch [IO.IOException] {
        if ($null -ne $probe) { $probe.Dispose() }
    } catch {
        if ($null -ne $probe) { $probe.Dispose() }
        return New-InstallerFlowResult 1 'user' 'operation_lock_unverified' 'The broker operation lock could not be verified.'
    }

    try {
        $identity = Get-SetupIdentity
        if ([bool]$identity.Elevated) {
            return New-InstallerFlowResult 1 'user' 'normal_user_required' 'Upgrade finalization must run as the original user.'
        }
        $process = [Diagnostics.Process]::GetCurrentProcess()
        if (-not (Test-NativeUpgradePathEqual ([string]$lease.BasePath) $resolvedBase) -or
            [string]$lease.OwnerSid -cne [string]$identity.Sid -or
            [int]$lease.SessionId -ne [int]$identity.SessionId -or
            [int]$lease.OwnerPid -ne [int]$process.Id) {
            return New-InstallerFlowResult 1 'user' 'operation_owner_mismatch' 'The operation lease does not belong to this broker process.'
        }
    } catch {
        return New-InstallerFlowResult 1 'user' 'operation_owner_mismatch' 'The operation owner identity could not be verified.'
    }

    $status = Get-OperationLeaseStatus -BasePath $resolvedBase
    if (-not $status.Success -or [string]$status.Status -cne 'active') {
        return New-InstallerFlowResult 1 'user' 'operation_lease_inactive' 'The operation lease is not active.'
    }
    if (-not (Test-OperationLeaseOwnerMatch $lease $status.Lease)) {
        return New-InstallerFlowResult 1 'user' 'operation_lease_mismatch' 'The active lease does not match the broker operation.'
    }
    return New-InstallerFlowResult 0 'user' 'ok' 'operation boundary valid'
}

function Copy-NativeUpgradeFileAtomic {
    param([string]$Source, [string]$Destination, [string]$DestinationRoot)
    if (-not (Test-NativeUpgradeRegularFile $Source (Split-Path -Parent $Source))) { throw 'Unsafe snapshot source.' }
    if (-not (Test-NativeUpgradePathWithin $Destination $DestinationRoot)) { throw 'Snapshot destination escaped its root.' }
    $parent = Split-Path -Parent $Destination
    if (-not [IO.Directory]::Exists($parent) -or -not (Test-NativeUpgradePathHasNoReparse $parent $DestinationRoot)) { throw 'Unsafe snapshot destination parent.' }
    if ([IO.File]::Exists($Destination) -and -not (Test-NativeUpgradeRegularFile $Destination $DestinationRoot)) { throw 'Unsafe snapshot destination.' }
    $temporary = Join-Path $parent ('.upgrade.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [IO.File]::ReadAllBytes($Source)
        [IO.File]::WriteAllBytes($temporary, $bytes)
        if ([IO.File]::Exists($Destination)) {
            [IO.File]::Replace($temporary, $Destination, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $Destination)
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Test-NativeUpgradeSnapshotPath {
    param([string]$SnapshotPath)
    $tempRoot = ConvertTo-NativeUpgradeCanonicalPath ([IO.Path]::GetTempPath())
    $snapshot = ConvertTo-NativeUpgradeCanonicalPath $SnapshotPath
    if ($null -eq $tempRoot -or $null -eq $snapshot -or -not (Test-NativeUpgradePathWithin $snapshot $tempRoot)) { return $false }
    if ((Split-Path -Leaf $snapshot) -cnotmatch '^ClaudeSwitcher-upgrade-[0-9a-f]{32}$') { return $false }
    return Test-NativeUpgradePathHasNoReparse $snapshot $tempRoot
}

function New-NativeUpgradeSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BasePath,
        [Parameter(Mandatory=$true)][object]$Operation
    )
    $snapshotPath = $null
    $operationId = $null
    try {
        $boundary = Test-NativeUpgradeOperationBoundary -Operation $Operation -BasePath $BasePath
        if (-not $boundary.Result.success) { return $boundary }
        $renewed = Renew-UserSetupOperation -Operation $Operation -Phase 'upgrade-snapshot' -TtlSeconds 300
        if (-not $renewed.Success) {
            return New-InstallerFlowResult 2 'snapshot' 'operation_lease_renewal_failed' 'The operation lease could not be renewed before the template snapshot.'
        }
        $boundary = Test-NativeUpgradeOperationBoundary -Operation $Operation -BasePath $BasePath
        if (-not $boundary.Result.success) { return $boundary }

        $payload = Get-SetupProtectedPayload
        $source = Resolve-NativeUpgradeTemplateSource -Payload $payload
        if (-not $source.Result.success) { return $source }

        $lease = Get-NativeUpgradeOperationLease $Operation
        $operationId = [string](Get-UserSetupProperty $lease 'OperationId')
        if ([string]::IsNullOrWhiteSpace($operationId)) {
            return New-InstallerFlowResult 1 'snapshot' 'operation_lease_mismatch' 'The operation lease id is unavailable.'
        }
        if ($script:NativeUpgradeSnapshots.ContainsKey($operationId)) {
            $existing = [string]$script:NativeUpgradeSnapshots[$operationId]
            if (-not [string]::IsNullOrWhiteSpace($existing)) {
                $removed = Remove-NativeUpgradeSnapshot -Snapshot $existing
                if (-not $removed.Result.success) { return $removed }
            }
        }

        $resolvedBase = ConvertTo-NativeUpgradeCanonicalPath $BasePath
        if ($null -eq $resolvedBase -or -not [IO.Directory]::Exists($resolvedBase) -or -not (Test-NativeUpgradePathHasNoReparse $resolvedBase $resolvedBase)) {
            return New-InstallerFlowResult 1 'snapshot' 'unsafe_template_path' 'The user setup directory is missing or unsafe.'
        }
        $tempRoot = ConvertTo-NativeUpgradeCanonicalPath ([IO.Path]::GetTempPath())
        if ($null -eq $tempRoot -or -not [IO.Directory]::Exists($tempRoot) -or -not (Test-NativeUpgradePathHasNoReparse $tempRoot $tempRoot)) {
            return New-InstallerFlowResult 1 'snapshot' 'temp_unavailable' 'The user temporary directory is unavailable or unsafe.'
        }
        $snapshotPath = Join-Path $tempRoot ('ClaudeSwitcher-upgrade-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($snapshotPath)
        if (-not (Test-NativeUpgradePathHasNoReparse $snapshotPath $tempRoot)) {
            [void](Remove-NativeUpgradeSnapshot -Snapshot $snapshotPath)
            return New-InstallerFlowResult 1 'snapshot' 'unsafe_snapshot_path' 'The snapshot directory is unsafe.'
        }
        foreach ($name in @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1','version.txt')) {
            $sourceFile = Join-Path $resolvedBase $name
            if (-not (Test-Path -LiteralPath $sourceFile)) { continue }
            if (-not (Test-NativeUpgradeRegularFile $sourceFile $resolvedBase)) {
                [void](Remove-NativeUpgradeSnapshot -Snapshot $snapshotPath)
                return New-InstallerFlowResult 1 'snapshot' 'unsafe_template_path' 'A template path is unsafe.'
            }
            Copy-NativeUpgradeFileAtomic -Source $sourceFile -Destination (Join-Path $snapshotPath $name) -DestinationRoot $snapshotPath
        }
        $script:NativeUpgradeSnapshots[$operationId] = $snapshotPath
        $result = New-InstallerFlowResult 0 'snapshot' 'ok' 'template snapshot created'
        Add-Member -InputObject $result.Result -NotePropertyName snapshotPath -NotePropertyValue $snapshotPath -Force
        Add-Member -InputObject $result.Result -NotePropertyName operationId -NotePropertyValue $operationId -Force
        Add-Member -InputObject $result -NotePropertyName SnapshotPath -NotePropertyValue $snapshotPath -Force
        Add-Member -InputObject $result -NotePropertyName Path -NotePropertyValue $snapshotPath -Force
        Add-Member -InputObject $result -NotePropertyName OperationId -NotePropertyValue $operationId -Force
        Add-Member -InputObject $result -NotePropertyName BasePath -NotePropertyValue $resolvedBase -Force
        return $result
    } catch {
        if ($null -ne $snapshotPath -and (Test-Path -LiteralPath $snapshotPath)) {
            [void](Remove-NativeUpgradeSnapshot -Snapshot $snapshotPath)
        }
        if ($null -ne $operationId) { [void]$script:NativeUpgradeSnapshots.Remove($operationId) }
        return New-InstallerFlowResult 1 'snapshot' 'snapshot_failed' 'The template snapshot could not be created safely.'
    }
}

function Restore-NativeUpgradeSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Snapshot,
        [Parameter(Mandatory=$true)][object]$Operation
    )
    try {
        $snapshotPath = Get-NativeUpgradeSnapshotPath $Snapshot
        if ([string]::IsNullOrWhiteSpace($snapshotPath)) {
            return New-InstallerFlowResult 1 'restore' 'unsafe_snapshot_path' 'The snapshot object does not contain a valid path.'
        }
        $resolvedBase = Get-NativeUpgradeExpectedBasePath
        if ([string]::IsNullOrWhiteSpace($resolvedBase)) {
            return New-InstallerFlowResult 1 'restore' 'user_profile_unavailable' 'The current user profile path is unavailable.'
        }
        $boundary = Test-NativeUpgradeOperationBoundary -Operation $Operation -BasePath $resolvedBase
        if (-not $boundary.Result.success) { return $boundary }
        $renewed = Renew-UserSetupOperation -Operation $Operation -Phase 'upgrade-restore' -TtlSeconds 300
        if (-not $renewed.Success) {
            return New-InstallerFlowResult 2 'restore' 'operation_lease_renewal_failed' 'The operation lease could not be renewed before template restore.'
        }
        $boundary = Test-NativeUpgradeOperationBoundary -Operation $Operation -BasePath $resolvedBase
        if (-not $boundary.Result.success) { return $boundary }
        $payload = Get-SetupProtectedPayload
        $source = Resolve-NativeUpgradeTemplateSource -Payload $payload
        if (-not $source.Result.success) { return $source }
        if (-not [IO.Directory]::Exists($resolvedBase) -or -not (Test-NativeUpgradePathHasNoReparse $resolvedBase $resolvedBase)) {
            return New-InstallerFlowResult 1 'restore' 'unsafe_template_path' 'The restore target is missing or unsafe.'
        }
        if (-not (Test-NativeUpgradeSnapshotPath $snapshotPath)) {
            return New-InstallerFlowResult 1 'restore' 'unsafe_snapshot_path' 'The snapshot path is outside the unique user snapshot namespace.'
        }
        $snapshot = ConvertTo-NativeUpgradeCanonicalPath $snapshotPath
        if (-not [IO.Directory]::Exists($snapshot)) {
            return New-InstallerFlowResult 1 'restore' 'snapshot_missing' 'The template snapshot is missing.'
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $snapshot -Force)) {
            if ($entry.PSIsContainer -or @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1','version.txt') -cnotcontains $entry.Name) {
                return New-InstallerFlowResult 1 'restore' 'unsafe_snapshot_path' 'The snapshot contains an unexpected entry.'
            }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return New-InstallerFlowResult 1 'restore' 'unsafe_snapshot_path' 'The snapshot contains a reparse entry.'
            }
        }
        foreach ($name in @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1','version.txt')) {
            $snapshotFile = Join-Path $snapshot $name
            $target = Join-Path $resolvedBase $name
            if (Test-Path -LiteralPath $snapshotFile) {
                if (-not (Test-NativeUpgradeRegularFile $snapshotFile $snapshot)) {
                    return New-InstallerFlowResult 1 'restore' 'unsafe_snapshot_path' 'A snapshot file is unsafe.'
                }
                if ([IO.File]::Exists($target) -and -not (Test-NativeUpgradeRegularFile $target $resolvedBase)) {
                    return New-InstallerFlowResult 1 'restore' 'unsafe_template_path' 'A template target is unsafe.'
                }
                Copy-NativeUpgradeFileAtomic -Source $snapshotFile -Destination $target -DestinationRoot $resolvedBase
            } elseif ([IO.File]::Exists($target)) {
                if (-not (Test-NativeUpgradeRegularFile $target $resolvedBase)) {
                    return New-InstallerFlowResult 1 'restore' 'unsafe_template_path' 'A template target is unsafe.'
                }
                [IO.File]::Delete($target)
            }
        }
        return New-InstallerFlowResult 0 'restore' 'ok' 'template snapshot restored'
    } catch {
        return New-InstallerFlowResult 1 'restore' 'restore_failed' 'The template snapshot could not be restored safely.'
    }
}

function Remove-NativeUpgradeSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object]$Snapshot)
    try {
        $snapshotPath = Get-NativeUpgradeSnapshotPath $Snapshot
        if ([string]::IsNullOrWhiteSpace($snapshotPath) -or -not (Test-NativeUpgradeSnapshotPath $snapshotPath)) {
            return New-InstallerFlowResult 1 'cleanup' 'unsafe_snapshot_path' 'The snapshot path is outside the unique user snapshot namespace.'
        }
        $snapshot = ConvertTo-NativeUpgradeCanonicalPath $snapshotPath
        if (-not [IO.Directory]::Exists($snapshot)) {
            foreach ($key in @($script:NativeUpgradeSnapshots.Keys)) {
                if (Test-NativeUpgradePathEqual ([string]$script:NativeUpgradeSnapshots[$key]) $snapshot) { [void]$script:NativeUpgradeSnapshots.Remove($key) }
            }
            return New-InstallerFlowResult 0 'cleanup' 'ok' 'snapshot already absent'
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $snapshot -Force)) {
            if ($entry.PSIsContainer -or @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1','version.txt') -cnotcontains $entry.Name) {
                return New-InstallerFlowResult 1 'cleanup' 'unsafe_snapshot_path' 'The snapshot contains an unexpected entry.'
            }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return New-InstallerFlowResult 1 'cleanup' 'unsafe_snapshot_path' 'The snapshot contains a reparse entry.'
            }
            [IO.File]::Delete($entry.FullName)
        }
        [IO.Directory]::Delete($snapshot, $false)
        foreach ($key in @($script:NativeUpgradeSnapshots.Keys)) {
            if (Test-NativeUpgradePathEqual ([string]$script:NativeUpgradeSnapshots[$key]) $snapshot) { [void]$script:NativeUpgradeSnapshots.Remove($key) }
        }
        return New-InstallerFlowResult 0 'cleanup' 'ok' 'template snapshot removed'
    } catch {
        return New-InstallerFlowResult 1 'cleanup' 'cleanup_failed' 'The template snapshot could not be removed safely.'
    }
}

function Resolve-NativeUpgradeTemplateSource {
    param([object]$Payload)
    if ($null -eq $Payload) {
        return New-InstallerFlowResult 1 'user' 'protected_payload_required' 'The protected native payload is unavailable.'
    }
    try {
        $app = ConvertTo-NativeUpgradeCanonicalPath ([string](Get-UserSetupProperty $Payload 'App'))
        if ($null -eq $app -or -not (Test-NativeUpgradeRegularFile $app (Split-Path -Parent $app))) {
            return New-InstallerFlowResult 1 'user' 'protected_payload_required' 'The protected native application is unavailable.'
        }
        $appRoot = Split-Path -Parent $app
        $installedScripts = ConvertTo-NativeUpgradeCanonicalPath (Join-Path $appRoot 'scripts')
        $source = ConvertTo-NativeUpgradeCanonicalPath $script:SetupSourceDirectory
        if ($null -eq $installedScripts -or $null -eq $source -or -not (Test-NativeUpgradePathEqual $installedScripts $source)) {
            return New-InstallerFlowResult 1 'user' 'template_source_mismatch' 'Upgrade templates must come from the installed scripts directory.'
        }
        foreach ($name in @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1')) {
            if (-not (Test-NativeUpgradeRegularFile (Join-Path $installedScripts $name) $installedScripts)) {
                return New-InstallerFlowResult 1 'user' 'template_missing' 'Protected user templates are incomplete or unsafe.'
            }
        }
        $versionPath = Join-Path $appRoot 'VERSION'
        if (-not (Test-NativeUpgradeRegularFile $versionPath $appRoot)) {
            return New-InstallerFlowResult 1 'user' 'template_missing' 'The protected version file is missing or unsafe.'
        }
        $result = New-InstallerFlowResult 0 'user' 'ok' 'protected template source validated'
        Add-Member -InputObject $result.Result -NotePropertyName scriptsDirectory -NotePropertyValue $installedScripts -Force
        Add-Member -InputObject $result.Result -NotePropertyName versionPath -NotePropertyValue $versionPath -Force
        return $result
    } catch {
        return New-InstallerFlowResult 1 'user' 'protected_payload_required' 'The protected native payload could not be validated.'
    }
}

function Invoke-NativeUpgradeFinalize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object]$Operation,
        [string]$BasePath=''
    )
    $snapshotPath = $null
    try {
        if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = Get-NativeUpgradeExpectedBasePath }
        $boundary = Test-NativeUpgradeOperationBoundary -Operation $Operation -BasePath $BasePath
        if (-not $boundary.Result.success) { return $boundary }
        $renewed = Renew-UserSetupOperation -Operation $Operation -Phase 'upgrade-finalize' -TtlSeconds 300
        if (-not $renewed.Success) {
            return New-InstallerFlowResult 2 'user' 'operation_lease_renewal_failed' 'The operation lease could not be renewed before upgrade finalization.'
        }
        $boundary = Test-NativeUpgradeOperationBoundary -Operation $Operation -BasePath $BasePath
        if (-not $boundary.Result.success) { return $boundary }

        $lease = Get-NativeUpgradeOperationLease $Operation
        $operationId = [string](Get-UserSetupProperty $lease 'OperationId')
        if ([string]::IsNullOrWhiteSpace($operationId) -or -not $script:NativeUpgradeSnapshots.ContainsKey($operationId)) {
            return New-InstallerFlowResult 1 'user' 'snapshot_required' 'Upgrade finalization requires a prepared template snapshot for this operation.'
        }
        $snapshotPath = [string]$script:NativeUpgradeSnapshots[$operationId]
        if ([string]::IsNullOrWhiteSpace($snapshotPath) -or -not (Test-NativeUpgradeSnapshotPath $snapshotPath) -or -not [IO.Directory]::Exists($snapshotPath)) {
            return New-InstallerFlowResult 1 'user' 'snapshot_required' 'The prepared template snapshot is missing or unsafe.'
        }

        $payload = Get-SetupProtectedPayload
        $source = Resolve-NativeUpgradeTemplateSource -Payload $payload
        if (-not $source.Result.success) { return $source }

        try {
            Copy-SetupUserTemplates -Destination $BasePath
            $result = New-InstallerFlowResult 0 'completed' 'ok' 'user templates updated; configuration and account data retained'
            Add-Member -InputObject $result.Result -NotePropertyName snapshotPath -NotePropertyValue $snapshotPath -Force
            return $result        } catch {
            $restore = Restore-NativeUpgradeSnapshot -Snapshot $snapshotPath -Operation $Operation
            if ($restore.Result.success) {
                $failed = New-InstallerFlowResult 1 'user' 'upgrade_finalize_failed' 'User templates could not be updated safely; template changes were restored and the snapshot is retained for outer rollback.'
                Add-Member -InputObject $failed.Result -NotePropertyName snapshotPath -NotePropertyValue $snapshotPath -Force
                Add-Member -InputObject $failed.Result -NotePropertyName restoreState -NotePropertyValue 'restored' -Force
                return $failed
            }
            $failed = New-InstallerFlowResult 1 'user' 'upgrade_finalize_rollback_failed' 'User templates could not be updated and rollback failed; retain recovery material.'
            Add-Member -InputObject $failed.Result -NotePropertyName snapshotPath -NotePropertyValue $snapshotPath -Force
            Add-Member -InputObject $failed.Result -NotePropertyName restoreState -NotePropertyValue 'failed' -Force
            return $failed
        }
    } catch {
        return New-InstallerFlowResult 1 'user' 'upgrade_finalize_failed' 'User templates could not be updated safely.'
    }
}

function Invoke-NativeUserSetupFlow {
    param([hashtable]$Options,[string]$BasePath=(Join-Path $env:USERPROFILE '.claude-switcher'))
    $stage='user'; $handle=$null
    try {
        $entryCount=0
        foreach($entry in @('Preview','Initialize','RemoveUserTask')) {
            if ([bool](Get-UserSetupProperty $Options $entry)) { $entryCount++ }
        }
        if ($entryCount -gt 1 -or ([bool](Get-UserSetupProperty $Options 'RequireNoOtherTasks') -and -not [bool](Get-UserSetupProperty $Options 'RemoveUserTask'))) {
            return New-InstallerFlowResult 1 'user' 'invalid_entry_mode' 'Choose exactly one setup entry; task inventory checks are valid only for task removal.'
        }
        $identity=Get-SetupIdentity
        if ([bool](Get-UserSetupProperty $Options 'Initialize')) {
            if ($identity.Elevated) { return New-InstallerFlowResult 1 'user' 'normal_user_required' 'Open configuration from your ordinary desktop session.' }
            $payload=Get-SetupProtectedPayload
            if ($null -eq $payload) { return New-InstallerFlowResult 1 'user' 'protected_payload_required' 'Install the native Setup EXE before system configuration.' }
            Start-Process -FilePath $payload.App -ArgumentList '--setup' -ErrorAction Stop | Out-Null
            return New-InstallerFlowResult 0 'completed' 'ok' 'configuration window opened'
        }
        if ([bool](Get-UserSetupProperty $Options 'RemoveUserTask')) {
            $payload=Get-SetupProtectedPayload
            if ($null -eq $payload) { return New-InstallerFlowResult 1 'user' 'protected_payload_required' 'Protected helper is unavailable.' }
            if ([bool](Get-UserSetupProperty $Options 'RequireNoOtherTasks')) {
                try {
                    $taskPrefix='ClaudeSwitcher.Bodyguard.'
                    $otherTasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object {
                        $_.TaskName.StartsWith($taskPrefix,[StringComparison]::Ordinal) -and
                        $_.TaskName -cne ($taskPrefix+$identity.Sid)
                    })
                    if ($otherTasks.Count -gt 0) { return New-InstallerFlowResult 1 'user' 'other_user_tasks_exist' 'Other configured users must remove their owned task from their own desktop session first.' }
                } catch { return New-InstallerFlowResult 1 'user' 'task_inventory_failed' 'Owned task inventory could not be verified; uninstallation was blocked.' }
            }
            $locked=Enter-UserSetupOperation -BasePath $BasePath
            if (-not $locked.Success) { return New-InstallerFlowResult 2 'user' 'busy_or_recovery_required' 'A running operation or pending recovery blocks task removal.' }
            $handle=$locked.Handle; $stage='system'
            $removed=Invoke-ElevatedSystemSetup -HelperPath $payload.Helper -Operation 'remove-bodyguard-task' -UserSid $identity.Sid -SessionId $identity.SessionId
            if (-not $removed.Success) {
                if ([bool](Get-UserSetupProperty $removed 'Cancelled')) { return New-InstallerFlowResult 4 'system' 'uac_cancelled' 'Task removal was cancelled; user data has been retained and removal can be retried.' }
                return New-InstallerFlowResult 1 'system' 'task_removal_failed' 'Owned task removal failed; user data has been retained.'
            }
            return New-InstallerFlowResult 0 'completed' 'ok' 'owned task removed; user data retained'
        }
        if ($identity.Elevated) { return New-InstallerFlowResult 1 'user' 'normal_user_required' 'Open configuration from your ordinary desktop session.' }
        $stage='preview'
        $interactive=-not [bool](Get-UserSetupProperty $Options 'NonInteractive')
        $reader=$null
        if ($interactive) { $reader={param($prompt) Read-Host $prompt} }
        $selectedMode=[string](Get-UserSetupProperty $Options 'ProxyMode')
        $detectedMode=if ($selectedMode) { $selectedMode } else { Get-SetupDetectedProxyMode }
        $proxy=Resolve-ProxyConfiguration -DetectedMode $detectedMode -RequestedMode $selectedMode -ProxyGroup ([string](Get-UserSetupProperty $Options 'ProxyGroup')) -NonInteractive (-not $interactive) -ReadHost $reader
        if (-not $proxy.Success) { return New-InstallerFlowResult 1 'preview' 'invalid_proxy_configuration' $proxy.Error }
        $observed=Get-SetupEgress
        $validated=Test-UserSetupConfiguration -InputObject @{NonInteractive=$true;ProxyMode=$proxy.ProxyMode;ProxyGroup=$proxy.ProxyGroup;Country=$observed.Country;TimeZoneId=$observed.TimeZoneId;Culture=$observed.Culture}
        if (-not $validated.Success) { return New-InstallerFlowResult 1 'preview' 'unsupported_region' 'A supported non-CN region and known time zone are required.' }
        if ([bool](Get-UserSetupProperty $Options 'Preview')) {
            return [pscustomobject]@{ExitCode=0;Result=[pscustomobject][ordered]@{schemaVersion=1;success=$true;country=$validated.Country;timeZoneId=$validated.TimeZoneId;culture=$validated.Culture;proxyMode=$validated.ProxyMode;proxyGroup=$validated.ProxyGroup}}
        }
        foreach($field in @('Country','TimeZoneId','Culture')) {
            $reviewed=[string](Get-UserSetupProperty $Options $field)
            if (-not $reviewed -and $interactive) { $Options[$field]=$validated.$field }
            elseif ($reviewed -cne $validated.$field) { return New-InstallerFlowResult 1 'preview' 'reviewed_region_mismatch' ('Reviewed '+$field+' must match the current egress region.') }
        }
        if ($interactive) {
            $answer=Read-Host ('Apply '+$validated.Country+' / '+$validated.TimeZoneId+' and configure IPv6, DNS cache and bodyguard? Type YES')
            if ($answer -cne 'YES') { return New-InstallerFlowResult 4 'user' 'cancelled' 'Configuration was cancelled before changes.' }
        }
        $stage='user'
        $payload=Get-SetupProtectedPayload
        if ($null -eq $payload) { return New-InstallerFlowResult 1 'user' 'protected_payload_required' 'Install the native Setup EXE before system configuration.' }
        foreach($name in @('claude-switch.ps1','SwitcherUI.ps1','claude-bodyguard.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $script:SetupSourceDirectory $name) -PathType Leaf)) { return New-InstallerFlowResult 1 'user' 'template_missing' 'Bundled user templates are incomplete.' }
        }
        $locked=Enter-UserSetupOperation -BasePath $BasePath
        if (-not $locked.Success) { return New-InstallerFlowResult 2 'user' 'busy_or_recovery_required' 'A running operation or pending recovery blocks configuration.' }
        $handle=$locked.Handle
        $renewed=Renew-UserSetupOperation -Operation $locked -Phase 'user' -TtlSeconds 300
        if (-not $renewed.Success) { return New-InstallerFlowResult 2 'user' 'operation_lease_renewal_failed' 'The operation lease could not be renewed before user configuration; no configuration was written.' }
        Copy-SetupUserTemplates -Destination $BasePath
        $written=Write-UserConfiguration -ConfigPath (Join-Path $BasePath 'config.json') -InputObject $validated
        if (-not $written.Success) { return New-InstallerFlowResult 1 'user' 'configuration_write_failed' 'User configuration could not be saved; system configuration has not started.' }
        $stage='system'
        $renewed=Renew-UserSetupOperation -Operation $locked -Phase 'system' -TtlSeconds 300
        if (-not $renewed.Success) { return New-InstallerFlowResult 2 'system' 'operation_lease_renewal_failed' 'The operation lease could not be renewed before system configuration; the elevated stage was not started.' }
        $system=Invoke-ElevatedSystemSetup -HelperPath $payload.Helper -Operation 'repair-system' -UserSid $identity.Sid -SessionId $identity.SessionId -TimeZoneId $validated.TimeZoneId -LeaseRenewal { Renew-UserSetupOperation -Operation $locked -Phase 'system-wait' -TtlSeconds 300 }
        $renewed=Renew-UserSetupOperation -Operation $locked -Phase 'system-returned' -TtlSeconds 300
        if (-not $renewed.Success) { return New-InstallerFlowResult 2 'system' 'operation_lease_renewal_failed' 'The operation lease could not be renewed after system configuration; review recovery material before retrying.' }
        if (-not $system.Success) {
            if ([bool](Get-UserSetupProperty $system 'Cancelled')) { return New-InstallerFlowResult 4 'system' 'uac_cancelled' 'System configuration was cancelled; user configuration was saved and can be retried.' }
            return New-InstallerFlowResult 1 'system' 'system_configuration_failed' 'System configuration failed; earlier completed steps may remain applied. Retry configuration.'
        }
        return New-InstallerFlowResult 0 'completed' 'ok' 'configuration complete'
    } catch {
        return New-InstallerFlowResult 1 $stage 'setup_failed' 'Configuration failed at the reported stage. Review the selected proxy and region, then retry.'
    } finally {
        if ($null -ne $handle) { Exit-UserSetupOperation -Handle $handle }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false) } catch {}
    $taskOptions=@{NonInteractive=[bool]$NonInteractive;ProxyMode=$ProxyMode;ProxyGroup=$ProxyGroup;Country=$Country;TimeZoneId=$TimeZoneId;Culture=$Culture;Preview=[bool]$Preview;Initialize=[bool]$Initialize;RemoveUserTask=[bool]$RemoveUserTask;RequireNoOtherTasks=[bool]$RequireNoOtherTasks}
    if ($Json) { $taskOptions.NonInteractive=$true }
    $taskOutcome=Invoke-NativeUserSetupFlow -Options $taskOptions
    if ($Json) { ConvertTo-Json -InputObject $taskOutcome.Result -Compress -Depth 5 }
    else { Write-Host $taskOutcome.Result.message }
    exit $taskOutcome.ExitCode
}
