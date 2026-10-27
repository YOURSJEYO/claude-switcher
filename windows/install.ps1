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

function Get-SetupEgress {
    # Only reviewed region scalars leave this function. Never print the raw response.
    $response=Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 8 -ErrorAction Stop
    $country=[string](Get-UserSetupProperty $response 'country')
    $zone=Get-WindowsTimeZoneId ([string](Get-UserSetupProperty $response 'timezone'))
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
        Copy-SetupUserTemplates -Destination $BasePath
        $written=Write-UserConfiguration -ConfigPath (Join-Path $BasePath 'config.json') -InputObject $validated
        if (-not $written.Success) { return New-InstallerFlowResult 1 'user' 'configuration_write_failed' 'User configuration could not be saved; system configuration has not started.' }
        $stage='system'
        $system=Invoke-ElevatedSystemSetup -HelperPath $payload.Helper -Operation 'repair-system' -UserSid $identity.Sid -SessionId $identity.SessionId -TimeZoneId $validated.TimeZoneId
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
