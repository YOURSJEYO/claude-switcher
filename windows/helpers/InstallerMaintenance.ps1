[CmdletBinding()]
param(
    [ValidateSet('Broker','SpawnBroker','LaunchUninstall')]
    [string]$Mode,
    [ValidateSet('upgrade','uninstall')]
    [string]$Action,
    [string]$InstalledRoot,
    [string]$ContextDirectory,
    [int]$ParentProcessId,
    [switch]$Quiet,
    [switch]$DeleteUserData
)

$ErrorActionPreference = 'Stop'

function New-InstallerMaintenanceResult {
    param([bool]$Success, [string]$Code, [string]$Message, [hashtable]$Extra = @{})
    $result = [ordered]@{
        schemaVersion = 1
        success = $Success
        code = $Code
        message = $Message
    }
    foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] }
    [pscustomobject]$result
}

function Write-InstallerMaintenanceResult {
    param([string]$Path, [object]$Result)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, ($Result | ConvertTo-Json -Compress -Depth 6), [Text.UTF8Encoding]::new($false))
}

function Get-InstallerFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'path must be absolute' }
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-InstallerDirectoryTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return New-InstallerMaintenanceResult $true 'missing' 'directory is absent' }
    try {
        $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return New-InstallerMaintenanceResult $false 'unsafe-user-data' 'user data root is not a normal directory'
        }
        $cursor=$root.FullName
        while($cursor) {
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse ancestor'}
            $cursor=Split-Path -Parent $cursor
        }
        $count = 0
        $pending=New-Object 'Collections.Generic.Stack[string]'
        $pending.Push($Path)
        while($pending.Count) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
                $count++
                if ($count -gt 1000000 -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    return New-InstallerMaintenanceResult $false 'unsafe-user-data' 'user data contains an unsafe reparse path'
                }
                if($entry.PSIsContainer){$pending.Push($entry.FullName)}
            }
        }
        return New-InstallerMaintenanceResult $true 'safe' 'directory tree is safe'
    } catch {
        return New-InstallerMaintenanceResult $false 'unsafe-user-data' 'user data could not be validated safely'
    }
}

function Invoke-InstallerUserDataCleanup {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$ClaudeDataPath,
        [switch]$ConfirmDeleteUserData
    )
    if (-not $ConfirmDeleteUserData) {
        return New-InstallerMaintenanceResult $false 'confirmation-required' 'explicit user-data deletion confirmation is required'
    }

    try {
        $base = Get-InstallerFullPath $BasePath
        $claude = Get-InstallerFullPath $ClaudeDataPath
        if ([IO.Path]::GetFileName($base) -cne '.claude-switcher' -or [IO.Path]::GetFileName($claude) -cne 'Claude') {
            return New-InstallerMaintenanceResult $false 'unsafe-user-data' 'user data paths do not have the expected names'
        }
        if ($base.Equals($claude, [StringComparison]::OrdinalIgnoreCase)) {
            return New-InstallerMaintenanceResult $false 'unsafe-user-data' 'user data paths must be distinct'
        }

        foreach ($path in @($base, $claude)) {
            $safe = Test-InstallerDirectoryTree $path
            if (-not $safe.Success -and $safe.Code -ne 'missing') { return $safe }
        }

        $quarantine = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($path in @($claude, $base)) {
                if (-not (Test-Path -LiteralPath $path)) { continue }
                $parent = Split-Path -Parent $path
                $name = [IO.Path]::GetFileName($path)
                $staged = Join-Path $parent ('.' + $name + '.delete-' + [guid]::NewGuid().ToString('N'))
                [IO.Directory]::Move($path, $staged)
                $quarantine.Add([pscustomobject]@{ Original = $path; Staged = $staged })
            }
            foreach ($item in $quarantine) {
                Remove-Item -LiteralPath $item.Staged -Recurse -Force -ErrorAction Stop
            }
            return New-InstallerMaintenanceResult $true 'deleted' 'user data was deleted after explicit confirmation'
        } catch {
            foreach ($item in @($quarantine | Sort-Object { $_.Original.Length })) {
                try {
                    if ((Test-Path -LiteralPath $item.Staged) -and -not (Test-Path -LiteralPath $item.Original)) {
                        [IO.Directory]::Move($item.Staged, $item.Original)
                    }
                } catch { }
            }
            return New-InstallerMaintenanceResult $false 'delete-failed' 'user data deletion failed; retained data was restored where possible'
        }
    } catch {
        return New-InstallerMaintenanceResult $false 'unsafe-user-data' 'user data paths could not be validated safely'
    }
}

function Get-InstallerMaintenanceIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'maintenance broker must run as the original non-elevated user'
        }
        $sid = [string]$identity.User.Value
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        if (-not (Test-UserSidForSetup $sid) -or $session -le 0) { throw 'interactive user identity is invalid' }
        [pscustomobject]@{ Sid = $sid; SessionId = $session }
    } finally { $identity.Dispose() }
}

function Get-MaintenanceTaskInventory {
    param($Identity)
    $tasks=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop)
    $own='ClaudeSwitcher.Bodyguard.'+$Identity.Sid
    foreach($task in $tasks) {
        if ($task.TaskName -eq 'ClaudeBodyguard') { throw 'Migrate the legacy ClaudeBodyguard task before maintenance.' }
        if ($task.TaskName.StartsWith('ClaudeSwitcher.Bodyguard.',[StringComparison]::OrdinalIgnoreCase) -and $task.TaskName -cne $own) {
            throw 'Other configured users must remove their owned tasks in their own sessions first.'
        }
    }
    return @($tasks | Where-Object TaskName -CEQ $own).Count -gt 0
}

function Assert-MaintenanceProcessesClosed {
    param([string]$Root,[bool]$DeleteData)
    # Removing the guard while Claude is running would leave an unprotected client.
    if (Get-Process -Name Claude -ErrorAction SilentlyContinue) { throw 'Exit Claude completely before maintenance.' }
    foreach($process in @(Get-Process -Name ClaudeSwitcher -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -ine (Join-Path $Root 'ClaudeSwitcher.exe')) { throw 'An unknown switcher process is running.' }
            if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(10000)) { throw 'Close Claude Switcher before maintenance.' }
        } finally { $process.Dispose() }
    }
}

function Invoke-MaintenanceTask {
    param([string]$Root,$Identity,[string]$Operation,$Lease)
    $result=Invoke-ElevatedSystemSetup -HelperPath (Join-Path $Root 'helpers\ClaudeSwitcher.Admin.exe') -Operation $Operation -UserSid $Identity.Sid -SessionId $Identity.SessionId -LeaseRenewal {
        Renew-UserSetupOperation -Operation $Lease -Phase 'installer-task' -TtlSeconds 300
    }
    if (-not $result.Success) { throw 'The protected task operation failed or was cancelled.' }
}

function Write-MaintenanceState {
    param([string]$Directory,[string]$State)
    if($script:MaintenanceChannels.ContainsKey($Directory)){$script:MaintenanceChannels[$Directory].State=$State}
}

if($null -eq $script:MaintenanceChannels){$script:MaintenanceChannels=@{}}

function Get-MaintenanceState {
    param([string]$Directory)
    $script:MaintenanceChannels[$Directory].State
}

function New-MaintenanceChannel {
    param([string]$Directory,[int]$ExpectedParentId=$PID)
    if(-not ('InstallerPipeClientIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class InstallerPipeClientIdentity {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientId);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static string Image(uint id) {
        var handle=OpenProcess(0x1000,false,id); if(handle==IntPtr.Zero) return null;
        try {int size=32768; var path=new StringBuilder(size); return QueryFullProcessImageName(handle,0,path,ref size)?path.ToString():null;}
        finally {CloseHandle(handle);}
    }
}
'@
    }
    $name=[IO.Path]::GetFileName($Directory.TrimEnd('\'))
    $pipe=[IO.Pipes.NamedPipeServerStream]::new($name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Message,[IO.Pipes.PipeOptions]::Asynchronous)
    $channel=[pscustomobject]@{Name=$name;Token=$name;Pipe=$pipe;Wait=$pipe.WaitForConnectionAsync();ExpectedParentId=$ExpectedParentId;State='starting';LastStatusRead=$false;Parent=$null;UninstallerHash=''}
    $script:MaintenanceChannels[$Directory]=$channel
    return $channel
}

function Test-MaintenanceUninstallerChild {
    param([int]$ExpectedParentId,[string]$ExpectedHash,$Record)
    return $null -ne $Record -and $Record.ParentId -eq $ExpectedParentId -and
        [IO.Path]::GetFileName([string]$Record.Image) -ieq '_unins.tmp' -and
        $ExpectedHash -match '^[A-Fa-f0-9]{64}$' -and
        ([string]$Record.Hash -ieq $ExpectedHash -or [bool]$Record.HashUnavailable)
}

function Bind-MaintenanceUninstallerChild {
    param($Channel,[uint32]$ClientId)
    if(-not $Channel.UninstallerHash){return $false}
    try {
        $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ClientId) -ErrorAction Stop
        $image=[InstallerPipeClientIdentity]::Image($ClientId)
        if(-not $image){$image=[string]$process.ExecutablePath}
        $hash='';$unavailable=$false
        if(-not $image) {
            # Cross-account UAC can hide both the image path and its private
            # temp file. The exact trusted parent, kernel PID, instance token
            # and WMI image name still attest the Inno-created second phase.
            $image=[string]$process.Name
            $unavailable=$true
        } else {
            try{$hash=(Get-FileHash -LiteralPath $image -Algorithm SHA256 -ErrorAction Stop).Hash}
            catch {
                $errorException=$_.Exception
                while($null -ne $errorException) {
                    if($errorException -is [UnauthorizedAccessException] -or $errorException -is [Security.SecurityException]){$unavailable=$true;break}
                    $errorException=$errorException.InnerException
                }
                if(-not $unavailable){throw}
            }
        }
        $record=[pscustomobject]@{ParentId=$process.ParentProcessId;Image=$image;Hash=$hash;HashUnavailable=$unavailable}
        if(-not (Test-MaintenanceUninstallerChild $Channel.ExpectedParentId $Channel.UninstallerHash $record)){return $false}
        $Channel.ExpectedParentId=[int]$ClientId
        $Channel.Parent=[Diagnostics.Process]::GetProcessById([int]$ClientId)
        $Channel.UninstallerHash=''
        return $true
    } catch {return $false}
}

function Get-MaintenanceSignal {
    param([string]$Directory,$Channel)
    if(-not $Channel.Wait.IsCompleted){return ''}
    $null=$Channel.Wait.GetAwaiter().GetResult()
    try {
        [uint32]$clientId=0
        if(-not [InstallerPipeClientIdentity]::GetNamedPipeClientProcessId($Channel.Pipe.SafePipeHandle.DangerousGetHandle(),[ref]$clientId)){return ''}
        $buffer=New-Object byte[] 256
        $read=$Channel.Pipe.ReadAsync($buffer,0,$buffer.Length)
        if(-not $read.Wait(2000)){throw 'Maintenance pipe read timed out.'}
        $packet=[Text.Encoding]::ASCII.GetString($buffer,0,$read.Result) -split '\|',2
        if($packet.Count -ne 2 -or $packet[1] -cne $Channel.Token){return ''}
        if($clientId -ne $Channel.ExpectedParentId -and -not (Bind-MaintenanceUninstallerChild $Channel $clientId)){return ''}
        $command=$packet[0]
        if($command -cnotin @('prepare','commit','rollback','status')){return ''}
        $codes=@{starting=0;ready=1;prepared=2;committed=3;rolledback=4;failed=5;lost=6;'cleanup-failed'=7}
        $response=100
        if($command -eq 'status'){$response=[int]$codes[$Channel.State];$Channel.LastStatusRead=$true}
        $ack=[BitConverter]::GetBytes([int]$response)
        $write=$Channel.Pipe.WriteAsync($ack,0,$ack.Length)
        if(-not $write.Wait(2000)){throw 'Maintenance pipe acknowledgement timed out.'}
        if($command -eq 'status'){return ''}
        return $command
    } finally {
        $Channel.Pipe.Disconnect()
        $Channel.Wait=$Channel.Pipe.WaitForConnectionAsync()
    }
}

function Complete-MaintenanceAcknowledgement {
    param([string]$Directory,$Channel)
    $Channel.LastStatusRead=$false
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while(-not $Channel.LastStatusRead -and $timer.ElapsedMilliseconds -lt 15000){$null=Get-MaintenanceSignal $Directory $Channel; Start-Sleep -Milliseconds 50}
}

function Test-MaintenanceParentAlive {
    param($Parent)
    $Parent.Refresh()
    return -not $Parent.HasExited
}

function Invoke-MaintenanceSession {
    param([ValidateSet('upgrade','uninstall')][string]$Action,[string]$InstalledRoot,[string]$BasePath,[string]$ContextDirectory,$Identity,$Parent,[switch]$DeleteUserData,[scriptblock]$StartUninstaller,[string]$UninstallerHash)
    $operation=$null; $snapshot=$null; $hadTask=$false; $touched=$false; $prepared=$false; $allowMutation=$false; $channel=$null
    $journal=Join-Path $BasePath 'installer-maintenance.json'
    try {
        if (Test-Path -LiteralPath $journal) { throw 'Previous installer maintenance needs recovery review.' }
        $operation=Enter-UserSetupOperation -BasePath $BasePath
        if (-not $operation.Success) { throw 'The core operation is busy or requires recovery.' }
        Assert-MaintenanceProcessesClosed $InstalledRoot ([bool]$DeleteUserData)
        $hadTask=Get-MaintenanceTaskInventory $Identity
        $channel=New-MaintenanceChannel $ContextDirectory $Parent.Id
        Write-InstallerMaintenanceResult $journal ([ordered]@{schemaVersion=1;action=$Action;operationId=$operation.Lease.OperationId;hadTask=$hadTask;phase='holding'})
        if ($hadTask) {
            $touched=$true
            Invoke-MaintenanceTask $InstalledRoot $Identity 'remove-bodyguard-task' $operation
        }
        if($null -ne $StartUninstaller) {
            $Parent=& $StartUninstaller $operation
            $channel.ExpectedParentId=$Parent.Id
            $channel.UninstallerHash=$UninstallerHash
        }
        $channel.Parent=$Parent
        $allowMutation=$true
        Write-MaintenanceState $ContextDirectory 'ready'
        $timer=[Diagnostics.Stopwatch]::StartNew(); $renewAt=15000
        while ($true) {
            if (-not (Test-MaintenanceParentAlive $channel.Parent) -or $timer.Elapsed.TotalHours -ge 4) { throw 'Installer exited before completing maintenance.' }
            if ($timer.ElapsedMilliseconds -ge $renewAt) {
                $renewed=Renew-UserSetupOperation $operation -Phase ('installer-'+$Action) -TtlSeconds 300
                if(-not $renewed.Success){throw 'Maintenance lease renewal failed.'}
                $renewAt=$timer.ElapsedMilliseconds+15000
            }
            $command=Get-MaintenanceSignal $ContextDirectory $channel
            if ($command -eq 'prepare' -and -not $prepared) {
                try {
                    if($Action -eq 'upgrade') {
                        # Load the NEW, protected install functions after Inno replaced the payload.
                        if(Test-Path -LiteralPath (Join-Path $InstalledRoot 'scripts\install.ps1')) { . (Join-Path $InstalledRoot 'scripts\install.ps1') }
                        $candidate=New-NativeUpgradeSnapshot -BasePath $BasePath -Operation $operation
                        if(-not $candidate.Result.success){throw 'Could not snapshot user templates.'}
                        $snapshot=$candidate
                        $finalized=Invoke-NativeUpgradeFinalize -BasePath $BasePath -Operation $operation
                        if(-not $finalized.Result.success){throw 'User template update failed.'}
                        if($hadTask){Invoke-MaintenanceTask $InstalledRoot $Identity 'register-bodyguard-task' $operation}
                    }
                    $prepared=$true
                    Write-MaintenanceState $ContextDirectory 'prepared'
                } catch { $prepared=$false; Write-MaintenanceState $ContextDirectory 'failed' }
                # A repeated prepare must not re-run partially applied mutations.
                if(-not $prepared) {
                    do {
                        Start-Sleep -Milliseconds 200
                        if(-not (Test-MaintenanceParentAlive $channel.Parent)){throw 'Installer exited during rollback.'}
                        $renewed=Renew-UserSetupOperation $operation -Phase 'installer-await-rollback' -TtlSeconds 300
                        if(-not $renewed.Success){throw 'Maintenance lease renewal failed.'}
                        $command=Get-MaintenanceSignal $ContextDirectory $channel
                    } until($command -eq 'rollback')
                }
            }
            if($command -eq 'rollback') {
                if($null -ne $snapshot){
                    $restored=Restore-NativeUpgradeSnapshot -Snapshot $snapshot -Operation $operation
                    if(-not $restored.Result.success){throw 'User template rollback failed.'}
                }
                if($hadTask){Invoke-MaintenanceTask $InstalledRoot $Identity 'register-bodyguard-task' $operation}
                $closed=Close-OperationLease -Lease $operation.Lease
                if(-not $closed.Success){throw 'Maintenance lease close could not be verified.'}
                $operation.Handle.Dispose()
                $operation=$null
                Remove-Item -LiteralPath $journal -Force
                if($null -ne $snapshot){[void](Remove-NativeUpgradeSnapshot -Snapshot $snapshot)}
                Write-MaintenanceState $ContextDirectory 'rolledback'
                Complete-MaintenanceAcknowledgement $ContextDirectory $channel
                return 0
            }
            if($command -eq 'commit' -and $prepared) {
                Write-InstallerMaintenanceResult $journal ([ordered]@{schemaVersion=1;action=$Action;operationId=$operation.Lease.OperationId;hadTask=$hadTask;phase='committed'})
                $closed=Close-OperationLease -Lease $operation.Lease
                if(-not $closed.Success){throw 'Maintenance lease close could not be verified.'}
                $operation.Handle.Dispose()
                $operation=$null
                if($null -ne $snapshot){[void](Remove-NativeUpgradeSnapshot -Snapshot $snapshot)}
                if($Action -eq 'uninstall' -and $DeleteUserData) {
                    $cleaned=Invoke-InstallerUserDataCleanup -BasePath $BasePath -ClaudeDataPath (Join-Path $env:APPDATA 'Claude') -ConfirmDeleteUserData
                    if(-not $cleaned.Success){Write-MaintenanceState $ContextDirectory 'cleanup-failed';Complete-MaintenanceAcknowledgement $ContextDirectory $channel; return 1}
                }
                if(Test-Path -LiteralPath $journal){Remove-Item -LiteralPath $journal -Force}
                Write-MaintenanceState $ContextDirectory 'committed'
                Complete-MaintenanceAcknowledgement $ContextDirectory $channel
                return 0
            }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        if($touched -and -not $allowMutation) {
            # No ready acknowledgement means the original protected files remain.
            try {Invoke-MaintenanceTask $InstalledRoot $Identity 'register-bodyguard-task' $operation; $touched=$false} catch {}
        }
        if($null -ne $operation -and $operation.Success -and -not $touched -and -not $allowMutation) {
            if(Test-Path -LiteralPath $journal){Remove-Item -LiteralPath $journal -Force}
            Exit-UserSetupOperation -Handle $operation.Handle -Lease $operation.Lease
            $operation=$null
        }
        elseif($null -ne $operation -and $operation.Success -and (Test-Path -LiteralPath $BasePath)) {
            Write-InstallerMaintenanceResult $journal ([ordered]@{schemaVersion=1;action=$Action;operationId=$operation.Lease.OperationId;hadTask=$hadTask;phase='recovery-required';code='broker-failed'})
        }
        Write-MaintenanceState $ContextDirectory 'lost'
        if($null -ne $channel){Complete-MaintenanceAcknowledgement $ContextDirectory $channel}
        return 1
    } finally {
        # Unexpected termination preserves the lease/journal, but never strands an
        # open test/process handle. The remaining lease blocks future operations.
        if($null -ne $operation -and $null -ne $operation.Handle){$operation.Handle.Dispose()}
        if($null -ne $channel){$channel.Pipe.Dispose()}
    }
}

function Invoke-InstallerMaintenanceBroker {
    param([string]$Action,[string]$InstalledRoot,[string]$ContextDirectory,[int]$ParentProcessId,[switch]$DeleteUserData)
    $root=Get-InstallerFullPath $InstalledRoot
    $fixed=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'ClaudeSwitcher'
    if($root -ine $fixed){throw 'Maintenance requires the fixed protected install root.'}
    # Validate before dot-sourcing installed code, even at user privilege.
    . (Join-Path $PSScriptRoot 'InstallerPayload.ps1')
    Assert-InstallerProtectedPath $root (Split-Path $root -Parent)
    foreach($file in @(Get-InstallerPayloadFiles $root)){Assert-InstallerProtectedPath $file.FullName $root}
    . (Join-Path $root 'scripts\install.ps1')
    $identity=Get-InstallerMaintenanceIdentity
    if($DeleteUserData) {
        $consent=$script:InstallerDeletionConsent
        if($null -eq $consent -or $consent.OwnerSid -cne $identity.Sid -or $consent.OwnerPid -ne $PID -or $consent.ParentId -ne $ParentProcessId){throw 'User data deletion requires the ordinary-user confirmation flow.'}
        $script:InstallerDeletionConsent=$null
    }
    $parent=[Diagnostics.Process]::GetProcessById($ParentProcessId)
    if($parent.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId){throw 'Installer session mismatch.'}
    $mutex=[Threading.Mutex]::new($false,'Global\ClaudeSwitcher.InstallerMaintenance')
    $owned=$false
    try {
        try {$owned=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if(-not $owned){throw 'Another installer maintenance operation is running.'}
        Invoke-MaintenanceSession -Action $Action -InstalledRoot $root -BasePath (Join-Path $env:USERPROFILE '.claude-switcher') -ContextDirectory $ContextDirectory -Identity $identity -Parent $parent -DeleteUserData:$DeleteUserData
    } finally {
        if($owned){$mutex.ReleaseMutex()}
        $mutex.Dispose()
    }
}

function Invoke-UserUninstall {
    param([switch]$Quiet)
    $root=Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'scripts\install.ps1')
    $null=Get-InstallerMaintenanceIdentity
    $delete=$false
    if(-not $Quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        $answer=[Windows.Forms.MessageBox]::Show('Also permanently delete switcher configuration, all account snapshots, and Claude login data? Select No to preserve them (recommended).','Claude Switcher uninstall',[Windows.Forms.MessageBoxButtons]::YesNoCancel,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2)
        if($answer -eq [Windows.Forms.DialogResult]::Cancel){return 0}
        $delete=$answer -eq [Windows.Forms.DialogResult]::Yes
        if($delete -and [Windows.Forms.MessageBox]::Show('This permanently removes all saved account sessions. Continue?','Confirm data deletion',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2) -ne [Windows.Forms.DialogResult]::Yes){return 0}
    }
    $ipc=Join-Path ([IO.Path]::GetTempPath()) ('ClaudeSwitcher-maintenance-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($ipc)
    $arguments='/MAINTENANCE="'+$ipc+'" /BROKERPID='+$PID
    if($Quiet){$arguments+=' /VERYSILENT /SUPPRESSMSGBOXES'}
    . (Join-Path $PSScriptRoot 'InstallerPayload.ps1')
    $fixed=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'ClaudeSwitcher'
    if($root -ine $fixed){throw 'Uninstall requires the fixed protected installation.'}
    Assert-InstallerProtectedPath $root (Split-Path $root -Parent)
    foreach($file in @(Get-InstallerPayloadFiles $root)){Assert-InstallerProtectedPath $file.FullName $root}
    $uninstallHash=(Get-FileHash -LiteralPath (Join-Path $root 'unins000.exe') -Algorithm SHA256).Hash
    $launchState=@{Started=$false}
    $startUninstaller={
        param($operation)
        # Inno holds unins000.dat exclusively in its second phase. Snapshot it
        # while the broker holds the lease, BEFORE starting the uninstaller.
        $systemPs=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $backupArguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $root 'helpers\InstallerPayload.ps1')+'" -Mode Backup'
        $backup=Start-Process -FilePath $systemPs -ArgumentList $backupArguments -Verb RunAs -WindowStyle Hidden -PassThru
        [void]$backup.Handle
        while(-not $backup.WaitForExit(10000)) {
            if(-not (Renew-UserSetupOperation $operation -Phase 'uninstall-backup' -TtlSeconds 300).Success){throw 'Uninstall backup lease renewal failed.'}
        }
        $backup.Refresh()
        if($backup.ExitCode -ne 0){throw 'Protected uninstall backup failed.'}
        $started=Start-Process -FilePath (Join-Path $root 'unins000.exe') -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
        $launchState.Started=$true
        return $started
    }
    $mutex=[Threading.Mutex]::new($false,'Global\ClaudeSwitcher.InstallerMaintenance')
    $owned=$false
    try {
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'Other installer maintenance is active.'}
        $identity=Get-InstallerMaintenanceIdentity
        $outcome=Invoke-MaintenanceSession -Action uninstall -InstalledRoot $root -BasePath (Join-Path $env:USERPROFILE '.claude-switcher') -ContextDirectory $ipc -Identity $identity -Parent ([Diagnostics.Process]::GetCurrentProcess()) -StartUninstaller $startUninstaller -UninstallerHash $uninstallHash -DeleteUserData:$delete
        if($outcome -ne 0 -and -not $launchState.Started -and -not $Quiet) {
            [void][Windows.Forms.MessageBox]::Show('卸载准备未完成。请先完全退出 Claude 和切换器，确认没有旧版 ClaudeBodyguard、其他用户的保镖任务或待恢复操作。请保留配置与账号快照后再处理阻断项。','Claude Switcher',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)
        }
        return $outcome
    } finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if($Mode -eq 'LaunchUninstall'){exit (Invoke-UserUninstall -Quiet:$Quiet)}
        if($Mode -eq 'SpawnBroker') {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode Broker -Action upgrade -InstalledRoot "'+$InstalledRoot+'" -ContextDirectory "'+$ContextDirectory+'" -ParentProcessId '+$ParentProcessId
            $child=[Diagnostics.Process]::Start($start)
            exit $child.Id
        }
        if($Mode -ne 'Broker'){exit 2}
        exit (Invoke-InstallerMaintenanceBroker -Action $Action -InstalledRoot $InstalledRoot -ContextDirectory $ContextDirectory -ParentProcessId $ParentProcessId)
    } catch {
        exit 1
    }
}
