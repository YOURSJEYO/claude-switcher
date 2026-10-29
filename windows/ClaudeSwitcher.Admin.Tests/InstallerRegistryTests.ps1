# Isolated registry rollback tests. No real registry hive is opened.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'windows/helpers/InstallerPayload.ps1')

$script:RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{85E9726B-98E3-4CB8-B055-7E8A854D777B}_is1'
$script:MockKeys = @{}
$script:MockSecurity = $null
$script:Mutations = New-Object 'Collections.Generic.List[string]'
$script:Passed = 0

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('ASSERT: ' + $Message) } }
function Assert-False([bool]$Condition, [string]$Message) { if ($Condition) { throw ('ASSERT: ' + $Message) } }
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if (-not [object]::Equals($Expected, $Actual)) {
        throw ('ASSERT: ' + $Message + ' (expected=' + [string]$Expected + ', actual=' + [string]$Actual + ')')
    }
}
function Assert-Throws([scriptblock]$Body, [string]$Message) {
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw ('ASSERT: ' + $Message) }
}
function New-MockKey {
    param([hashtable]$Values = @{}, [string[]]$SubKeys = @())
    [pscustomobject]@{ Values = $Values; SubKeys = @($SubKeys) }
}
function Reset-MockRegistry {
    $script:MockKeys = @{}
    $script:Mutations = New-Object 'Collections.Generic.List[string]'
    $script:MockSecurity = $null
}
function New-MockRegistryAdapter {
    $adapter = New-InstallerRegistryAdapter `
        -TestKey {
            param([string]$Path)
            $exists=$script:MockKeys.ContainsKey($Path)
            if($exists -and $null -ne $script:MockSecurity){Assert-InstallerRegistrySecurity -Security $script:MockSecurity}
            return $exists
        } `
        -GetSubKeyNames { param([string]$Path) if (-not $script:MockKeys.ContainsKey($Path)) { return @() }; return @($script:MockKeys[$Path].SubKeys) } `
        -GetValues {
            param([string]$Path)
            if (-not $script:MockKeys.ContainsKey($Path)) { throw 'missing mock key' }
            foreach ($name in @($script:MockKeys[$Path].Values.Keys)) {
                $entry = $script:MockKeys[$Path].Values[$name]
                [pscustomobject]@{ Name = $name; Kind = $entry.Kind; Value = $entry.Value }
            }
        } `
        -DeleteKeyTree {
            param([string]$Path)
            $script:Mutations.Add('delete')
            if ($script:MockKeys.ContainsKey($Path) -and @($script:MockKeys[$Path].SubKeys).Count -ne 0) { throw 'mock descendants' }
            [void]$script:MockKeys.Remove($Path)
        } `
        -CreateKey {
            param([string]$Path)
            $script:Mutations.Add('create')
            if (-not $script:MockKeys.ContainsKey($Path)) { $script:MockKeys[$Path] = New-MockKey }
        } `
        -SetValue {
            param([string]$Path, [string]$Name, $Kind, $Value)
            $script:Mutations.Add('set:' + $Name)
            if (-not $script:MockKeys.ContainsKey($Path)) { throw 'missing mock key' }
            $script:MockKeys[$Path].Values[$Name] = [pscustomobject]@{ Kind = $Kind; Value = $Value }
        }
    return $adapter
}
function Get-MockValue([string]$Name) {
    $key = $script:MockKeys[$script:RegistryPath]
    if (-not $key.Values.ContainsKey($Name)) { return $null }
    return $key.Values[$Name]
}

function New-TestRegistrySecurity {
    param(
        [Security.AccessControl.RegistryRights]$Rights=[Security.AccessControl.RegistryRights]::ReadKey,
        [Security.AccessControl.PropagationFlags]$Propagation=[Security.AccessControl.PropagationFlags]::None,
        [string]$Owner='S-1-5-32-544',
        [string]$Identity='S-1-5-32-545',
        [Security.AccessControl.AccessControlType]$AccessType=[Security.AccessControl.AccessControlType]::Allow
    )
    $security=[Security.AccessControl.RegistrySecurity]::new()
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new($Owner))
    $inheritance=[Security.AccessControl.InheritanceFlags]::None
    if($Propagation -ne [Security.AccessControl.PropagationFlags]::None){$inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit}
    $rule=[Security.AccessControl.RegistryAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($Identity),$Rights,$inheritance,$Propagation,$AccessType)
    [void]$security.AddAccessRule($rule)
    return $security
}

function Copy-Json($Value) {
    return ($Value | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json)
}
function Run-Test([string]$Name, [scriptblock]$Body) {
    Reset-MockRegistry
    & $Body
    $script:Passed++
    Write-Host ('PASS ' + $Name)
}

try {
    Run-Test 'standard Users ReadKey permission does not block a rollback snapshot' {
        # In-memory Windows RegistrySecurity, never an opened registry key.
        $security=New-TestRegistrySecurity
        Assert-InstallerRegistrySecurity -Security $security
    }
    Run-Test 'ReadPermissions and ExecuteKey remain read-only access' {
        foreach($right in @([Security.AccessControl.RegistryRights]::ReadPermissions,[Security.AccessControl.RegistryRights]::ExecuteKey)) {
            Assert-InstallerRegistrySecurity -Security (New-TestRegistrySecurity -Rights $right)
        }
    }
    Run-Test 'every effective mutation grant still blocks the rollback snapshot' {
        foreach($right in @('SetValue','CreateSubKey','Delete','ChangePermissions','TakeOwnership','WriteKey','FullControl')) {
            $security=New-TestRegistrySecurity -Rights ([Security.AccessControl.RegistryRights]$right)
            Assert-Throws {Assert-InstallerRegistrySecurity -Security $security} ('mutation grant must fail: '+$right)
        }
    }
    Run-Test 'native key-create-link access remains a mutation' {
        $security=New-TestRegistrySecurity -Rights ([Security.AccessControl.RegistryRights]0x20)
        Assert-Throws {Assert-InstallerRegistrySecurity -Security $security} 'KEY_CREATE_LINK must fail'
    }
    Run-Test 'generic write and generic all grants remain blocked' {
        foreach($right in @('GW','GA')) {
            $security=[Security.AccessControl.RegistrySecurity]::new()
            $security.SetSecurityDescriptorSddlForm(('O:BAG:BAD:P(A;;'+$right+';;;BU)'))
            Assert-Throws {Assert-InstallerRegistrySecurity -Security $security} ('generic mutation must fail: '+$right)
        }
    }
    Run-Test 'inherit-only grants do not apply to the protected key itself' {
        $security=New-TestRegistrySecurity -Rights FullControl -Propagation InheritOnly
        Assert-InstallerRegistrySecurity -Security $security
    }
    Run-Test 'denied write rights do not become an allow grant' {
        $security=New-TestRegistrySecurity -Rights WriteKey -AccessType Deny
        Assert-InstallerRegistrySecurity -Security $security
    }
    Run-Test 'an untrusted owner is rejected even with a read-only DACL' {
        $security=New-TestRegistrySecurity -Owner 'S-1-5-21-1-2-3-1001'
        Assert-Throws {Assert-InstallerRegistrySecurity -Security $security} 'untrusted owner must fail'
    }
    Run-Test 'rollback registry snapshot validates a real read-only descriptor before reading values' {
        $adapter=New-MockRegistryAdapter
        $script:MockSecurity=New-TestRegistrySecurity
        $script:MockKeys[$script:RegistryPath]=New-MockKey -Values @{
            DisplayVersion=[pscustomobject]@{Kind=[Microsoft.Win32.RegistryValueKind]::String;Value='1.2.3'}
        }
        $snapshot=Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter
        Assert-True $snapshot.existed 'a protected read-only key must be snapshotted'
        Assert-Equal '1.2.3' @($snapshot.values)[0].data 'version is preserved'
        Assert-Equal 0 $script:Mutations.Count 'snapshot must not change the registry'
        $script:MockSecurity=New-TestRegistrySecurity -Rights SetValue
        Assert-Throws {Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter} 'a writable key must still fail before backup'
        Assert-Equal 0 $script:Mutations.Count 'rejected snapshot must not change the registry'
    }
    Run-Test 'Terminal Server Users mutation grant is allowed for read-only metadata snapshot only' {
        $security=New-TestRegistrySecurity -Rights SetValue -Identity 'S-1-5-13'
        Assert-Throws {Assert-InstallerRegistrySecurity -Security $security} 'strict restore policy must reject the legacy mutation grant'
        Assert-InstallerRegistrySecurity -Security $security -SnapshotOnly
    }
    Run-Test 'the host uninstall key can be read when it exists, without mutation' {
        $adapter=New-InstallerRealRegistryAdapter
        $snapshot=Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter
        if($snapshot.existed){Assert-True (@($snapshot.values).Count -gt 0) 'existing uninstall metadata must be readable'}
        Assert-Equal 0 $script:Mutations.Count 'real snapshot is read-only'
    }
    Run-Test 'absent key restore deletes a newly-created key' {
        $adapter = New-MockRegistryAdapter
        $snapshot = Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter
        Assert-False ([bool]$snapshot.existed) 'snapshot must record absence'
        $script:MockKeys[$script:RegistryPath] = New-MockKey -Values @{ Temporary = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::String; Value = 'created' } }
        $script:Mutations.Clear()
        Restore-InstallerRegistrySnapshot -Path $script:RegistryPath -Snapshot $snapshot -RegistryAdapter $adapter
        Assert-False $script:MockKeys.ContainsKey($script:RegistryPath) 'absent key must be removed on restore'
        Assert-Equal 1 $script:Mutations.Count 'only the delete mutation should occur'
        Assert-Equal 'delete' $script:Mutations[0] 'absence restore must not recreate the key'
    }

    Run-Test 'string, expand-string, multi-string, DWord and QWord values and types round-trip exactly' {
        $adapter = New-MockRegistryAdapter
        $script:MockKeys[$script:RegistryPath] = New-MockKey -Values @{
            '' = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::String; Value = 'default-value' }
            DisplayName = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::String; Value = 'Claude Switcher' }
            ExpandPath = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString; Value = '%SystemRoot%\ClaudeSwitcher' }
            MultiValue = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::MultiString; Value = @('one','two') }
            Count = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::DWord; Value = [int32]-1 }
            Large = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::QWord; Value = [int64]9007199254740993 }
            BinaryValue = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::Binary; Value = [byte[]](0,1,255) }
        }
        $snapshot = Copy-Json (Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter)
        $script:MockKeys[$script:RegistryPath].Values.Clear()
        $script:Mutations.Clear()
        Restore-InstallerRegistrySnapshot -Path $script:RegistryPath -Snapshot $snapshot -RegistryAdapter $adapter
        Assert-Equal 'default-value' (Get-MockValue '').Value 'default value'
        Assert-Equal 'Claude Switcher' (Get-MockValue 'DisplayName').Value 'string value'
        Assert-Equal ([Microsoft.Win32.RegistryValueKind]::String) (Get-MockValue 'DisplayName').Kind 'string type'
        Assert-Equal '%SystemRoot%\ClaudeSwitcher' (Get-MockValue 'ExpandPath').Value 'expand-string value'
        Assert-Equal ([Microsoft.Win32.RegistryValueKind]::ExpandString) (Get-MockValue 'ExpandPath').Kind 'expand-string type'
        Assert-Equal 'one|two' ((Get-MockValue 'MultiValue').Value -join '|') 'multi-string value'
        Assert-Equal ([Microsoft.Win32.RegistryValueKind]::MultiString) (Get-MockValue 'MultiValue').Kind 'multi-string type'
        Assert-Equal ([int32]-1) (Get-MockValue 'Count').Value 'DWord value'
        Assert-Equal ([Microsoft.Win32.RegistryValueKind]::DWord) (Get-MockValue 'Count').Kind 'DWord type'
        Assert-Equal ([int64]9007199254740993) (Get-MockValue 'Large').Value 'QWord value'
        Assert-Equal ([Microsoft.Win32.RegistryValueKind]::QWord) (Get-MockValue 'Large').Kind 'QWord type'
        Assert-Equal 'AAH/' ([Convert]::ToBase64String((Get-MockValue 'BinaryValue').Value)) 'binary value'
        Assert-Equal ([Microsoft.Win32.RegistryValueKind]::Binary) (Get-MockValue 'BinaryValue').Kind 'binary type'
    }

    Run-Test 'corrupt receipt is rejected before any registry mutation' {
        $adapter = New-MockRegistryAdapter
        $script:MockKeys[$script:RegistryPath] = New-MockKey -Values @{
            Keep = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::String; Value = 'before' }
        }
        $snapshot = Copy-Json (Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter)
        $snapshot.values[0].data = 'not-a-dword'
        $snapshot.values[0].kind = 'DWord'
        $script:Mutations.Clear()
        Assert-Throws { Restore-InstallerRegistrySnapshot -Path $script:RegistryPath -Snapshot $snapshot -RegistryAdapter $adapter } 'corrupt receipt must fail'
        Assert-Equal 0 $script:Mutations.Count 'corrupt receipt must not mutate the registry'
        Assert-Equal 'before' (Get-MockValue 'Keep').Value 'existing value must remain unchanged'
    }

    Run-Test 'absent receipt with values is rejected before mutation' {
        $adapter = New-MockRegistryAdapter
        $script:MockKeys[$script:RegistryPath] = New-MockKey -Values @{
            Keep = [pscustomobject]@{ Kind = [Microsoft.Win32.RegistryValueKind]::String; Value = 'before' }
        }
        $snapshot = [pscustomobject]@{ schemaVersion = 1; path = $script:RegistryPath; existed = $false; descendants = @(); values = @([pscustomobject]@{ name = 'Unexpected'; kind = 'String'; encoding = 'string'; data = 'value' }) }
        $script:Mutations.Clear()
        Assert-Throws { Restore-InstallerRegistrySnapshot -Path $script:RegistryPath -Snapshot $snapshot -RegistryAdapter $adapter } 'absent receipt with values must fail'
        Assert-Equal 0 $script:Mutations.Count 'invalid absent receipt must not mutate the registry'
        Assert-Equal 'before' (Get-MockValue 'Keep').Value 'existing value must remain unchanged'
    }
    Run-Test 'unknown descendants are rejected before snapshot or restore mutation' {
        $adapter = New-MockRegistryAdapter
        $script:MockKeys[$script:RegistryPath] = New-MockKey -SubKeys @('UnexpectedChild')
        Assert-Throws { Get-InstallerRegistrySnapshot -Path $script:RegistryPath -RegistryAdapter $adapter } 'unknown descendants must fail snapshot'
        $snapshot = [pscustomobject]@{ schemaVersion = 1; path = $script:RegistryPath; existed = $true; descendants = @('UnexpectedChild'); values = @() }
        $script:Mutations.Clear()
        Assert-Throws { Restore-InstallerRegistrySnapshot -Path $script:RegistryPath -Snapshot $snapshot -RegistryAdapter $adapter } 'unknown descendants must fail restore'
        Assert-Equal 0 $script:Mutations.Count 'descendant validation must happen before mutation'
    }

    Run-Test 'real adapter derives a registry-relative path without a leading slash' {
        Assert-Equal 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{85E9726B-98E3-4CB8-B055-7E8A854D777B}_is1' (Get-InstallerRegistryRelativePath -Path $script:RegistryPath) 'relative path must be accepted by RegistryKey.OpenSubKey'
    }
    Run-Test 'registry path is restricted to the fixed uninstall key' {
        $adapter = New-MockRegistryAdapter
        Assert-Throws { Get-InstallerRegistrySnapshot -Path 'HKLM:\SOFTWARE\Other' -RegistryAdapter $adapter } 'unexpected registry path must fail'
    }

    Write-Host ('RESULT total={0} passed={1} failed=0' -f $script:Passed, $script:Passed)
} catch {
    Write-Error $_
    exit 1
}
