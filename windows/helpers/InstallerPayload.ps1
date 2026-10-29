# Elevated fixed-path payload operations used only by the embedded Inno installer.
[CmdletBinding()]
param([ValidateSet('Validate','Backup','Verify','Restore','Commit')][string]$Mode)
$ErrorActionPreference = 'Stop'

function Assert-InstallerProtectedPath {
    param([string]$Path, [string]$Boundary)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $stop = [IO.Path]::GetFullPath($Boundary).TrimEnd('\')
    if (-not ($full.Equals($stop,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($stop+'\',[StringComparison]::OrdinalIgnoreCase))) { throw 'Protected path escaped its boundary.' }
    $trusted = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $mask = [Security.AccessControl.FileSystemRights]'WriteData,AppendData,WriteExtendedAttributes,WriteAttributes,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    $cursor = $full
    while ($true) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Protected path contains a reparse point.' }
        $acl = Get-Acl -LiteralPath $cursor -ErrorAction Stop
        if ($trusted -notcontains $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) { throw 'Protected path has an untrusted owner.' }
        foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
            if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            if ($rule.AccessControlType -eq 'Allow' -and $trusted -notcontains $rule.IdentityReference.Value) {
                $bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$rule.FileSystemRights),0)
                if (($rule.FileSystemRights -band $mask) -or ($bits -band [uint32]0x50000000)) { throw 'Protected path is user writable.' }
            }
        }
        if ($cursor.Equals($stop,[StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = Split-Path -Parent $cursor
    }
}

function Get-InstallerPayloadFiles {
    param([string]$Root)
    # Enumerate one directory at a time and reject links BEFORE descending.
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Root)
    $files = New-Object 'Collections.Generic.List[object]'
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload contains a reparse point.' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            else { $files.Add($item) }
            if ($files.Count + $pending.Count -gt 20000) { throw 'Payload validation limit exceeded.' }
        }
    }
    return $files.ToArray()
}

function Copy-InstallerPayload {
    param([string]$Source, [string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in @(Get-InstallerPayloadFiles $Source)) {
        $relative = $item.FullName.Substring($Source.TrimEnd('\').Length+1)
        $target = Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy($item.FullName,$target,$true)
    }
}

function Get-InstallerPayloadManifest {
    param([string]$Root)
    @(Get-InstallerPayloadFiles $Root | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{path=$_.FullName.Substring($Root.TrimEnd('\').Length+1); hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
}

function Test-InstallerPayloadManifest {
    param([string]$Root, [object[]]$Manifest)
    $actual = @(Get-InstallerPayloadManifest $Root)
    if ($actual.Count -ne $Manifest.Count) { return $false }
    for ($i=0; $i -lt $actual.Count; $i++) {
        if ($actual[$i].path -cne $Manifest[$i].path -or $actual[$i].hash -cne $Manifest[$i].hash) { return $false }
    }
    return $true
}

$script:InstallerRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{85E9726B-98E3-4CB8-B055-7E8A854D777B}_is1'
$script:InstallerRegistryAllowedDescendants = @()

function Assert-InstallerRegistryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Registry path is required.' }
    $canonical = $Path.TrimEnd('\')
    $native = 'HKEY_LOCAL_MACHINE\' + $script:InstallerRegistryPath.Substring(6)
    if ($canonical -ine $script:InstallerRegistryPath -and $canonical -ine $native) {
        throw 'Registry path is not the fixed Claude Switcher uninstall key.'
    }
    return $script:InstallerRegistryPath
}

function Get-InstallerRegistryRelativePath {
    param([string]$Path)
    $canonical = Assert-InstallerRegistryPath $Path
    return $canonical.Substring(6)
}
function New-InstallerRegistryAdapter {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$TestKey,
        [Parameter(Mandatory=$true)][scriptblock]$GetSubKeyNames,
        [Parameter(Mandatory=$true)][scriptblock]$GetValues,
        [Parameter(Mandatory=$true)][scriptblock]$DeleteKeyTree,
        [Parameter(Mandatory=$true)][scriptblock]$CreateKey,
        [Parameter(Mandatory=$true)][scriptblock]$SetValue,
        [scriptblock]$AssertProtected=$null
    )
    [pscustomobject]@{
        TestKey=$TestKey
        GetSubKeyNames=$GetSubKeyNames
        GetValues=$GetValues
        DeleteKeyTree=$DeleteKeyTree
        CreateKey=$CreateKey
        SetValue=$SetValue
        AssertProtected=$AssertProtected
    }
}

function Get-InstallerRegistryKindName {
    param($Kind)
    $name = [string]$Kind
    if ([Enum]::GetNames([Microsoft.Win32.RegistryValueKind]) -notcontains $name) {
        throw 'Unsupported registry value type.'
    }
    return $name
}

function ConvertTo-InstallerRegistryValueRecord {
    param([object]$Entry)
    if ($null -eq $Entry -or $null -eq $Entry.PSObject.Properties['Name'] -or $null -eq $Entry.PSObject.Properties['Kind'] -or $null -eq $Entry.PSObject.Properties['Value']) {
        throw 'Invalid registry value entry.'
    }
    $name = [string]$Entry.Name
    $kind = Get-InstallerRegistryKindName $Entry.Kind
    switch ($kind) {
        'String' {
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='string'; data=[string]$Entry.Value }
        }
        'ExpandString' {
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='string'; data=[string]$Entry.Value }
        }
        'MultiString' {
            $items = @()
            if ($null -ne $Entry.Value) { $items = @([string[]]$Entry.Value) }
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='multi-string'; data=$items }
        }
        'DWord' {
            $signed = [int32]$Entry.Value
            $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($signed),0)
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='decimal'; data=[string]$unsigned }
        }
        'QWord' {
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='decimal'; data=[string]([int64]$Entry.Value) }
        }
        'Binary' {
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='base64'; data=[Convert]::ToBase64String([byte[]]$Entry.Value) }
        }
        'None' {
            if ($null -eq $Entry.Value) {
                return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='null'; data=$null }
            }
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='base64'; data=[Convert]::ToBase64String([byte[]]$Entry.Value) }
        }
        default {
            if ($Entry.Value -is [byte[]]) {
                return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='base64'; data=[Convert]::ToBase64String([byte[]]$Entry.Value) }
            }
            return [pscustomobject][ordered]@{ name=$name; kind=$kind; encoding='string'; data=[string]$Entry.Value }
        }
    }
}

function ConvertFrom-InstallerRegistryValueRecord {
    param([object]$Record)
    if ($null -eq $Record -or $null -eq $Record.PSObject.Properties['name'] -or $null -eq $Record.PSObject.Properties['kind'] -or $null -eq $Record.PSObject.Properties['encoding'] -or $null -eq $Record.PSObject.Properties['data']) {
        throw 'Invalid rollback registry value record.'
    }
    if ($Record.name -isnot [string]) { throw 'Invalid rollback registry value name.' }
    $name = [string]$Record.name
    $kind = Get-InstallerRegistryKindName $Record.kind
    $encoding = [string]$Record.encoding
    switch ($kind) {
        'String' {
            if ($encoding -cne 'string' -or $Record.data -isnot [string]) { throw 'Invalid string registry value.' }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::String; Value=[string]$Record.data }
        }
        'ExpandString' {
            if ($encoding -cne 'string' -or $Record.data -isnot [string]) { throw 'Invalid expand-string registry value.' }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::ExpandString; Value=[string]$Record.data }
        }
        'MultiString' {
            if ($encoding -cne 'multi-string' -or $null -eq $Record.data) { throw 'Invalid multi-string registry value.' }
            $items = @($Record.data)
            foreach ($item in $items) { if ($item -isnot [string]) { throw 'Invalid multi-string registry value.' } }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::MultiString; Value=[string[]]$items }
        }
        'DWord' {
            if ($encoding -cne 'decimal' -or $Record.data -isnot [string] -or $Record.data -notmatch '^[0-9]+$') { throw 'Invalid DWord registry value.' }
            $unsigned = [uint32]::Parse($Record.data,[Globalization.NumberStyles]::None,[Globalization.CultureInfo]::InvariantCulture)
            $signed = [BitConverter]::ToInt32([BitConverter]::GetBytes($unsigned),0)
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::DWord; Value=$signed }
        }
        'QWord' {
            if ($encoding -cne 'decimal' -or $Record.data -isnot [string] -or $Record.data -notmatch '^-?[0-9]+$') { throw 'Invalid QWord registry value.' }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::QWord; Value=[int64]::Parse($Record.data,[Globalization.CultureInfo]::InvariantCulture) }
        }
        'Binary' {
            if ($encoding -cne 'base64' -or $Record.data -isnot [string]) { throw 'Invalid binary registry value.' }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::Binary; Value=[Convert]::FromBase64String($Record.data) }
        }
        'None' {
            if ($encoding -ceq 'null' -and $null -eq $Record.data) {
                return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::None; Value=$null }
            }
            if ($encoding -cne 'base64' -or $Record.data -isnot [string]) { throw 'Invalid none registry value.' }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::None; Value=[Convert]::FromBase64String($Record.data) }
        }
        default {
            if ($encoding -ceq 'base64' -and $Record.data -is [string]) {
                return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::Unknown; Value=[Convert]::FromBase64String($Record.data) }
            }
            if ($encoding -cne 'string' -or $Record.data -isnot [string]) { throw 'Invalid unknown registry value.' }
            return [pscustomobject]@{ Name=$name; Kind=[Microsoft.Win32.RegistryValueKind]::Unknown; Value=[string]$Record.data }
        }
    }
}

function ConvertFrom-InstallerRegistrySnapshot {
    param([object]$Snapshot)
    if ($null -eq $Snapshot -or $null -eq $Snapshot.PSObject.Properties['schemaVersion'] -or [int]$Snapshot.schemaVersion -ne 1) {
        throw 'Invalid rollback registry receipt.'
    }
    if ($null -eq $Snapshot.PSObject.Properties['path'] -or (Assert-InstallerRegistryPath ([string]$Snapshot.path)) -ine $script:InstallerRegistryPath) {
        throw 'Invalid rollback registry path.'
    }
    if ($null -eq $Snapshot.PSObject.Properties['existed'] -or $Snapshot.existed -isnot [bool]) {
        throw 'Invalid rollback registry existence marker.'
    }
    if ($null -eq $Snapshot.PSObject.Properties['descendants'] -or $null -eq $Snapshot.PSObject.Properties['values']) {
        throw 'Invalid rollback registry receipt.'
    }
    $descendants = @($Snapshot.descendants)
    $unexpected = @($descendants | Where-Object { $script:InstallerRegistryAllowedDescendants -notcontains [string]$_ })
    if ($unexpected.Count -ne 0) { throw 'Registry receipt contains unexpected descendants.' }
    $rawValues = @($Snapshot.values)
    if (-not [bool]$Snapshot.existed -and $rawValues.Count -ne 0) { throw 'Absent registry receipt must not contain values.' }
    $seen = @{}
    $values = @()
    foreach ($record in $rawValues) {
        $value = ConvertFrom-InstallerRegistryValueRecord $record
        if ($seen.ContainsKey($value.Name)) { throw 'Registry receipt contains duplicate value names.' }
        $seen[$value.Name] = $true
        $values += $value
    }
    return [pscustomobject]@{ Existed=[bool]$Snapshot.existed; Values=@($values) }
}

function Get-InstallerRegistrySnapshot {
    param([string]$Path,[object]$RegistryAdapter=$null)
    $canonical = Assert-InstallerRegistryPath $Path
    if ($null -eq $RegistryAdapter) { $RegistryAdapter = New-InstallerRealRegistryAdapter }
    $exists = [bool](& $RegistryAdapter.TestKey $canonical)
    $descendants = @()
    $values = @()
    if ($exists) {
        $descendants = @(& $RegistryAdapter.GetSubKeyNames $canonical)
        $unexpected = @($descendants | Where-Object { $script:InstallerRegistryAllowedDescendants -notcontains [string]$_ })
        if ($unexpected.Count -ne 0) { throw 'Registry key contains unexpected descendants.' }
        foreach ($entry in @(& $RegistryAdapter.GetValues $canonical)) {
            $values += ConvertTo-InstallerRegistryValueRecord $entry
        }
    }
    return [pscustomobject][ordered]@{
        schemaVersion=1
        path=$canonical
        existed=$exists
        descendants=@()
        values=@($values | Sort-Object name)
    }
}

function Restore-InstallerRegistrySnapshot {
    param([string]$Path,[object]$Snapshot,[object]$RegistryAdapter=$null)
    $canonical = Assert-InstallerRegistryPath $Path
    if ($null -eq $RegistryAdapter) { $RegistryAdapter = New-InstallerRealRegistryAdapter }
    $normalized = ConvertFrom-InstallerRegistrySnapshot $Snapshot
    $exists = [bool](& $RegistryAdapter.TestKey $canonical)
    if ($exists) {
        $descendants = @(& $RegistryAdapter.GetSubKeyNames $canonical)
        $unexpected = @($descendants | Where-Object { $script:InstallerRegistryAllowedDescendants -notcontains [string]$_ })
        if ($unexpected.Count -ne 0) { throw 'Registry key contains unexpected descendants.' }
    }
    if ($normalized.Existed) {
        if ($null -ne $RegistryAdapter.AssertProtected) { & $RegistryAdapter.AssertProtected $canonical }
        if ($exists) { & $RegistryAdapter.DeleteKeyTree $canonical }
        & $RegistryAdapter.CreateKey $canonical
        foreach ($value in $normalized.Values) {
            & $RegistryAdapter.SetValue $canonical $value.Name $value.Kind $value.Value
        }
    } elseif ($exists) {
        & $RegistryAdapter.DeleteKeyTree $canonical
    }
}

function Assert-InstallerRegistrySecurity {
    param([Parameter(Mandatory=$true)][Security.AccessControl.RegistrySecurity]$Security,[switch]$SnapshotOnly)
    $trusted = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $owner = $Security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($trusted -notcontains $owner) { throw 'Registry key has an untrusted owner.' }
    # WriteKey is a composite containing READ_CONTROL, which ReadKey also
    # contains. Only actual mutations belong in this mask (KEY_CREATE_LINK=0x20).
    $writeMask = [Security.AccessControl.RegistryRights]::SetValue -bor [Security.AccessControl.RegistryRights]::CreateSubKey -bor [Security.AccessControl.RegistryRights]::Delete -bor [Security.AccessControl.RegistryRights]::ChangePermissions -bor [Security.AccessControl.RegistryRights]::TakeOwnership -bor 0x20
    $snapshotCompatibilitySid='S-1-5-13' # Terminal Server Users: legacy inherited ACL on this metadata key only
    foreach ($rule in $Security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $trusted -notcontains $rule.IdentityReference.Value) {
            $bits=[BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$rule.RegistryRights),0)
            if (($bits -band [uint32]$writeMask) -ne 0 -or ($bits -band [uint32]0x50000000) -ne 0) {
                if($SnapshotOnly -and $rule.IdentityReference.Value -eq $snapshotCompatibilitySid){continue}
                throw 'Registry key is user writable.'
            }
        }
    }
}

function Assert-InstallerRegistryProtected {
    param([string]$Path,[switch]$SnapshotOnly)
    $canonical = Assert-InstallerRegistryPath $Path
    $relative = Get-InstallerRegistryRelativePath -Path $canonical
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relative,$false)
    if ($null -eq $key) { return }
    try {
        $security = $key.GetAccessControl([Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Access)
        Assert-InstallerRegistrySecurity -Security $security -SnapshotOnly:$SnapshotOnly
    } finally { $key.Dispose() }
}

function New-InstallerRealRegistryAdapter {
    [pscustomobject]@{
        TestKey = {
            param([string]$Path)
            $canonical = Assert-InstallerRegistryPath $Path
            $relative = Get-InstallerRegistryRelativePath -Path $canonical
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relative,$false)
            if ($null -eq $key) { return $false }
            try { Assert-InstallerRegistryProtected $canonical -SnapshotOnly; return $true } finally { $key.Dispose() }
        }
        GetSubKeyNames = {
            param([string]$Path)
            $canonical = Assert-InstallerRegistryPath $Path
            $relative = Get-InstallerRegistryRelativePath -Path $canonical
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relative,$false)
            if ($null -eq $key) { return @() }
            try { return @($key.GetSubKeyNames()) } finally { $key.Dispose() }
        }
        GetValues = {
            param([string]$Path)
            $canonical = Assert-InstallerRegistryPath $Path
            $relative = Get-InstallerRegistryRelativePath -Path $canonical
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relative,$false)
            if ($null -eq $key) { throw 'Registry key is unavailable.' }
            try {
                foreach ($name in @($key.GetValueNames())) {
                    [pscustomobject]@{
                        Name=$name
                        Kind=$key.GetValueKind($name)
                        Value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    }
                }
            } finally { $key.Dispose() }
        }
        DeleteKeyTree = {
            param([string]$Path)
            $canonical = Assert-InstallerRegistryPath $Path
            $relative = Get-InstallerRegistryRelativePath -Path $canonical
            $leaf = Split-Path -Leaf $relative
            $parentRelative = Split-Path -Parent $relative
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relative,$false)
            if ($null -ne $key) {
                try { if (@($key.GetSubKeyNames()).Count -ne 0) { throw 'Registry key contains unexpected descendants.' } } finally { $key.Dispose() }
            }
            $parent = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($parentRelative,$true)
            if ($null -eq $parent) { throw 'Registry parent key is unavailable.' }
            try { $parent.DeleteSubKeyTree($leaf,$false) } finally { $parent.Dispose() }
        }
        CreateKey = {
            param([string]$Path)
            $canonical = Assert-InstallerRegistryPath $Path
            $relative = Get-InstallerRegistryRelativePath -Path $canonical
            $leaf = Split-Path -Leaf $relative
            $parentRelative = Split-Path -Parent $relative
            $parent = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($parentRelative,$true)
            if ($null -eq $parent) { throw 'Registry parent key is unavailable.' }
            try { $key = $parent.CreateSubKey($leaf); if ($null -eq $key) { throw 'Registry key could not be created.' }; $key.Dispose() } finally { $parent.Dispose() }
        }
        SetValue = {
            param([string]$Path,[string]$Name,$Kind,$Value)
            $canonical = Assert-InstallerRegistryPath $Path
            $relative = Get-InstallerRegistryRelativePath -Path $canonical
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($relative,$true)
            if ($null -eq $key) { throw 'Registry key is unavailable.' }
            try { $key.SetValue($Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind) } finally { $key.Dispose() }
        }
        AssertProtected = { param([string]$Path) Assert-InstallerRegistryProtected $Path }
    }
}
function Invoke-InstallerPayloadOperation {
    param([string]$Mode,[object]$RegistryAdapter=$null)
    $script:InstallerPayloadFailureCode=10 # protected install preflight
    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $root = Join-Path $programFiles 'ClaudeSwitcher'
    $backup = Join-Path $programFiles 'ClaudeSwitcher.maintenance'
    $payload = Join-Path $backup 'payload'
    $recordPath = Join-Path $backup 'receipt.json'
    $registryPath = $script:InstallerRegistryPath
    if ($Mode -eq 'Validate') {
        if (Test-Path -LiteralPath $backup) { throw 'Previous maintenance material requires recovery.' }
        if (-not (Test-Path -LiteralPath $root)) { return }
        Assert-InstallerProtectedPath $root $programFiles
        foreach ($file in @(Get-InstallerPayloadFiles $root)) { Assert-InstallerProtectedPath $file.FullName $root }
        foreach ($required in @('ClaudeSwitcher.exe','helpers\ClaudeSwitcher.Admin.exe','scripts\install.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $required) -PathType Leaf)) { throw 'Existing protected payload is incomplete.' }
        }
        return
    }
    if ($Mode -eq 'Backup') {
        Invoke-InstallerPayloadOperation 'Validate'
        $script:InstallerPayloadFailureCode=20 # registry snapshot/ACL
        if ($null -eq $RegistryAdapter) { $RegistryAdapter = New-InstallerRealRegistryAdapter }
        $registrySnapshot = Get-InstallerRegistrySnapshot -Path $registryPath -RegistryAdapter $RegistryAdapter
        $script:InstallerPayloadFailureCode=21 # protected backup directory
        [void][IO.Directory]::CreateDirectory($backup)
        Assert-InstallerProtectedPath $backup $programFiles
        $script:InstallerPayloadFailureCode=22 # installed payload hashing
        $record = [ordered]@{schemaVersion=1; files=@(Get-InstallerPayloadManifest $root); registry=$registrySnapshot}
        $script:InstallerPayloadFailureCode=23 # payload copy
        Copy-InstallerPayload $root $payload
        $script:InstallerPayloadFailureCode=24 # copied payload verification
        if (-not (Test-InstallerPayloadManifest $payload $record.files)) { throw 'Rollback copy did not match the installed payload.' }
        $script:InstallerPayloadFailureCode=25 # durable backup receipt
        [IO.File]::WriteAllText($recordPath,($record | ConvertTo-Json -Depth 10 -Compress),[Text.UTF8Encoding]::new($false))
        return
    }
    $script:InstallerPayloadFailureCode=30 # recovery payload validation
    Assert-InstallerProtectedPath $backup $programFiles
    foreach ($file in @(Get-InstallerPayloadFiles $backup)) { Assert-InstallerProtectedPath $file.FullName $backup }
    if ($Mode -eq 'Commit') {
        $script:InstallerPayloadFailureCode=40 # committed backup cleanup
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop
        return
    }
    $recordFile = Get-Item -LiteralPath $recordPath
    if ($recordFile.Length -gt 8000000) { throw 'Invalid rollback receipt size.' }
    $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
    if ($record.schemaVersion -ne 1 -or -not (Test-InstallerPayloadManifest $payload @($record.files))) { throw 'Rollback receipt could not be verified.' }
    # Validate the registry receipt before touching the installed payload.
    $null = ConvertFrom-InstallerRegistrySnapshot $record.registry
    if($Mode -eq 'Verify'){return}
    $script:InstallerPayloadFailureCode=31 # restore original program files
    if (Test-Path -LiteralPath $root) {
        Assert-InstallerProtectedPath $root $programFiles
        foreach ($file in @(Get-InstallerPayloadFiles $root)) { Assert-InstallerProtectedPath $file.FullName $root }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    }
    Copy-InstallerPayload $payload $root
    if (-not (Test-InstallerPayloadManifest $root @($record.files))) { throw 'Restored payload could not be verified.' }
    if ($null -eq $RegistryAdapter) { $RegistryAdapter = New-InstallerRealRegistryAdapter }
    $script:InstallerPayloadFailureCode=32 # restore original registration
    Restore-InstallerRegistrySnapshot -Path $registryPath -Snapshot $record.registry -RegistryAdapter $RegistryAdapter
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-InstallerPayloadOperation $Mode; exit 0 }
    catch {
        $failureCode=if($null -ne $script:InstallerPayloadFailureCode){[int]$script:InstallerPayloadFailureCode}else{1}
        [Console]::Error.WriteLine(('Protected installer payload operation failed (stage code {0}); retain maintenance recovery material.' -f $failureCode))
        exit $failureCode
    }
}
