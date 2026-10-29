# Isolated state-machine tests: no installer, UAC, tasks, network or installed data.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'windows/helpers/UserSetup.ps1')
. (Join-Path $repo 'windows/helpers/InstallerMaintenance.ps1')
. (Join-Path $repo 'windows/helpers/InstallerPayload.ps1')
$realSignal=(Get-Command Get-MaintenanceSignal).ScriptBlock
$root=Join-Path ([IO.Path]::GetTempPath()) ('switcher-maintenance-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:passed=0
function Assert($Condition,[string]$Message){if(-not $Condition){throw "ASSERT: $Message"}}
function Test([string]$Name,[scriptblock]$Body){& $Body; $script:passed++; Write-Host "PASS $Name"}
# Only task/process/system boundaries are synthetic. The real lock, lease and
# state transitions run against a new unique directory per test.
function Get-MaintenanceTaskInventory { param($Identity) [bool]$script:HadTask }
function Invoke-MaintenanceTask { param($Root,$Identity,$Operation,$Lease) [void]$script:Calls.Add($Operation) }
function Assert-MaintenanceProcessesClosed { param($Root,$DeleteData) }
function Get-MaintenanceSignal { param($Directory) return $script:Signals.Dequeue() }
function Test-MaintenanceParentAlive { param($Parent) return $script:ParentAlive }
function Complete-MaintenanceAcknowledgement { param($Directory,$Channel) }
function Invoke-NativeUpgradeFinalize { param($BasePath,$Operation) [void]$script:Calls.Add('finalize'); if($script:FailFinalize){return [pscustomobject]@{Result=@{success=$false}}}; [pscustomobject]@{Result=@{success=$true}} }
function New-NativeUpgradeSnapshot { param($BasePath,$Operation) return [pscustomobject]@{Path='synthetic';Result=@{success=$true}} }
function Restore-NativeUpgradeSnapshot { param($Snapshot,$Operation) [void]$script:Calls.Add('restore-user'); return [pscustomobject]@{Result=@{success=$true}} }
function Remove-NativeUpgradeSnapshot { param($Snapshot) }
function New-Fixture {
    $script:Signals=New-Object 'Collections.Generic.Queue[string]'
    $script:Calls=New-Object 'Collections.Generic.List[string]'
    $script:ParentAlive=$true; $script:HadTask=$true; $script:FailFinalize=$false
    $dir=Join-Path $root ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($dir)
    [pscustomobject]@{Base=(Join-Path $dir '.claude-switcher'); Ipc=$dir; Root=$dir; Parent=[Diagnostics.Process]::GetCurrentProcess()}
}
try {
    Test 'maintenance command channel uses a named pipe without privileged file writes' {
        $f=New-Fixture
        $channel=New-MaintenanceChannel -Directory $f.Ipc
        $client=[IO.Pipes.NamedPipeClientStream]::new('.',$channel.Name,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $client.Connect(2000)
            $bytes=[Text.Encoding]::ASCII.GetBytes('prepare|'+$channel.Token)
            $write=$client.WriteAsync($bytes,0,$bytes.Length)
            $ack=New-Object byte[] 4
            $ackRead=$client.ReadAsync($ack,0,4)
            $command=''
            for($i=0;$i -lt 30 -and -not $command;$i++){$command=& $realSignal $f.Ipc $channel; if(-not $command){Start-Sleep -Milliseconds 50}}
            Assert ($command -eq 'prepare') 'command must arrive over the pipe'
            Assert ($write.Wait(2000)) 'client write completes'
            Assert ($ackRead.Wait(2000) -and $ackRead.Result -eq 4 -and $ack[0] -eq 100) 'server acknowledges the request'
            Assert (-not (Test-Path (Join-Path $f.Ipc 'command'))) 'no command file is written'
        } finally {$client.Dispose();$channel.Pipe.Dispose()}
    }
    Test 'maintenance pipe rejects commands from an unexpected process' {
        $f=New-Fixture
        $channel=New-MaintenanceChannel -Directory $f.Ipc -ExpectedParentId ($PID+10000)
        $client=[IO.Pipes.NamedPipeClientStream]::new('.',$channel.Name,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $client.Connect(2000)
            $bytes=[Text.Encoding]::ASCII.GetBytes('commit|'+$channel.Token)
            $write=$client.WriteAsync($bytes,0,$bytes.Length)
            $command=''
            for($i=0;$i -lt 30 -and -not $channel.Wait.IsCompleted;$i++){Start-Sleep -Milliseconds 50}
            $command=& $realSignal $f.Ipc $channel
            Assert (-not $command) 'unauthenticated commit must be ignored'
            Assert ($channel.State -eq 'starting') 'rejected client cannot advance the state'
        } finally {$client.Dispose();$channel.Pipe.Dispose()}
    }
    Test 'Inno second-phase identity requires exact parent and original executable hash' {
        $hash='a'*64
        $record=[pscustomobject]@{ParentId=100;Image='C:\synthetic\_unins.tmp';Hash=$hash;HashUnavailable=$false}
        Assert (Test-MaintenanceUninstallerChild 100 $hash $record) 'exact second phase is accepted'
        Assert (-not (Test-MaintenanceUninstallerChild 101 $hash $record)) 'other parent is rejected'
        $record.Hash='b'*64
        Assert (-not (Test-MaintenanceUninstallerChild 100 $hash $record)) 'changed executable is rejected'
        $record.Hash='';$record.HashUnavailable=$true
        Assert (Test-MaintenanceUninstallerChild 100 $hash $record) 'alternate-admin private temp relies on exact kernel parent and authenticated token'
    }
    Test 'uninstall stages its launcher only after holding the lock and removing the task' {
        $f=New-Fixture
        $script:Signals.Enqueue('prepare');$script:Signals.Enqueue('commit')
        $start={param($operation)
            Assert (($script:Calls -join ',') -eq 'remove-bodyguard-task') 'owned task removed before launcher'
            $probe=$null; $held=$false
            try{$probe=[IO.File]::Open((Join-Path $f.Base 'operation.lock'),'Open','ReadWrite','None')}catch [IO.IOException]{$held=$true}finally{if($probe){$probe.Dispose()}}
            Assert $held 'snapshot/launcher callback retains the user operation lock'
            [Diagnostics.Process]::GetCurrentProcess()
        }
        $result=Invoke-MaintenanceSession -Action uninstall -InstalledRoot $f.Root -BasePath $f.Base -ContextDirectory $f.Ipc -Identity @{Sid='S-1-5-21-1-2-3-1001';SessionId=1} -Parent $f.Parent -StartUninstaller $start -UninstallerHash ('a'*64)
        Assert ($result -eq 0) 'launcher-bound uninstall finishes'
    }
    Test 'upgrade keeps lock held through prepare and commit' {
        $f=New-Fixture
        $script:Signals.Enqueue('prepare'); $script:Signals.Enqueue('commit')
        $result=Invoke-MaintenanceSession -Action upgrade -InstalledRoot $f.Root -BasePath $f.Base -ContextDirectory $f.Ipc -Identity @{Sid='S-1-5-21-1-2-3-1001';SessionId=1} -Parent $f.Parent
        Assert ($result -eq 0) 'upgrade should finish'
        Assert (($script:Calls -join ',') -eq 'remove-bodyguard-task,finalize,register-bodyguard-task') 'task and finalize order'
        Assert (-not (Test-Path (Join-Path $f.Base 'operation.lease.json'))) 'committed lease is closed'
        Assert (-not (Test-Path (Join-Path $f.Base 'installer-maintenance.json'))) 'journal removed only after commit'
        Assert ((Get-MaintenanceState $f.Ipc) -eq 'committed') 'commit acknowledged'
    }
    Test 'failed preparation allows explicit rollback and restores task and user templates' {
        $f=New-Fixture; $script:FailFinalize=$true
        $script:Signals.Enqueue('prepare'); $script:Signals.Enqueue('rollback')
        $result=Invoke-MaintenanceSession -Action upgrade -InstalledRoot $f.Root -BasePath $f.Base -ContextDirectory $f.Ipc -Identity @{Sid='S-1-5-21-1-2-3-1001';SessionId=1} -Parent $f.Parent
        Assert ($result -eq 0) 'verified rollback should finish'
        Assert (($script:Calls -join ',') -eq 'remove-bodyguard-task,finalize,restore-user,register-bodyguard-task') 'rollback must restore both user templates and task'
        Assert ((Get-MaintenanceState $f.Ipc) -eq 'rolledback') 'rollback acknowledged'
    }
    Test 'parent crash preserves journal and lease for recovery' {
        $f=New-Fixture; $script:ParentAlive=$false
        $result=Invoke-MaintenanceSession -Action upgrade -InstalledRoot $f.Root -BasePath $f.Base -ContextDirectory $f.Ipc -Identity @{Sid='S-1-5-21-1-2-3-1001';SessionId=1} -Parent $f.Parent
        Assert ($result -ne 0) 'parent crash cannot commit'
        Assert (Test-Path (Join-Path $f.Base 'operation.lease.json')) 'orphan lease retained'
        Assert (Test-Path (Join-Path $f.Base 'installer-maintenance.json')) 'maintenance journal retained'
    }
    Test 'uninstall preserves user data and does not recreate an absent task' {
        $f=New-Fixture; $script:HadTask=$false
        [void][IO.Directory]::CreateDirectory($f.Base)
        [IO.File]::WriteAllText((Join-Path $f.Base 'config.json'),'keep')
        $script:Signals.Enqueue('prepare'); $script:Signals.Enqueue('commit')
        $result=Invoke-MaintenanceSession -Action uninstall -InstalledRoot $f.Root -BasePath $f.Base -ContextDirectory $f.Ipc -Identity @{Sid='S-1-5-21-1-2-3-1001';SessionId=1} -Parent $f.Parent
        Assert ($result -eq 0) 'uninstall completes'
        Assert ($script:Calls.Count -eq 0) 'absent task remains absent'
        Assert ([IO.File]::ReadAllText((Join-Path $f.Base 'config.json')) -eq 'keep') 'configuration retained'
    }
    Test 'payload copy verifies hashes and catches corruption' {
        $f=New-Fixture; $src=Join-Path $f.Root 'source'; $dst=Join-Path $f.Root 'backup'
        [void][IO.Directory]::CreateDirectory($src)
        [IO.File]::WriteAllText((Join-Path $src 'app.bin'),'before')
        $manifest=@(Get-InstallerPayloadManifest $src)
        Copy-InstallerPayload $src $dst
        Assert (Test-InstallerPayloadManifest $dst $manifest) 'verified backup'
        [IO.File]::WriteAllText((Join-Path $dst 'app.bin'),'corrupt')
        Assert (-not (Test-InstallerPayloadManifest $dst $manifest)) 'corruption rejected'
    }
    Write-Host "RESULT total=$script:passed passed=$script:passed failed=0"
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
