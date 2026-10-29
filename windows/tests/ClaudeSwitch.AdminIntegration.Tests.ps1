# All elevated operations and process identities in this suite are synthetic.
function New-AdminTestWorkspace {
    $root=New-TestWorkspace
    $script:CoreConfigurationKind=$null
    return $root
}

function New-TestAcl([string]$Sid) {
    $owner=New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList $Sid
    $acl=[pscustomobject]@{OwnerSid=$owner}
    $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) return $this.OwnerSid }
    return $acl
}
Add-CoreTest -Tag AdminIntegration -Name 'repair invokes only the protected fixed helper with scalar identity arguments' {
    New-AdminTestWorkspace | Out-Null
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{ Helper='C:\Program Files\ClaudeSwitcher\helpers\ClaudeSwitcher.Admin.exe' } }
    $script:AdminLaunch=$null
    function Start-Process { param($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction,$WindowStyle) $script:AdminLaunch=[pscustomobject]@{ File=$FilePath; Verb=$Verb; Arguments=$ArgumentList; Wait=$Wait; Style=$WindowStyle }; [pscustomobject]@{ ExitCode=0 } }
    $script:TZ_TARGET='Tokyo Standard Time'
    Assert-Equal 0 (Invoke-ProtectedSystemRepair) 'fixed helper success propagates'
    Assert-Equal 'C:\Program Files\ClaudeSwitcher\helpers\ClaudeSwitcher.Admin.exe' $script:AdminLaunch.File 'only protected helper is elevated'
    Assert-Equal 'RunAs' $script:AdminLaunch.Verb 'UAC is explicit'
    Assert-Match '--operation repair-system --user-sid S-1-5-21-1-2-3-1001 --session-id 2 --time-zone-id "Tokyo Standard Time"' ($script:AdminLaunch.Arguments -join ' ') 'closed scalar contract'
    Assert-Equal 'Hidden' $script:AdminLaunch.Style 'no visible helper console'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:BASE -Filter '*.ps1').Count 'repair never writes elevated script text'
}

Add-CoreTest -Tag AdminIntegration -Name 'repair rejects missing protected payload before elevation' {
    New-AdminTestWorkspace | Out-Null
    function Get-ProtectedWindowsPayload { $null }
    function Start-Process { throw 'must not elevate' }
    Assert-Equal 1 (Invoke-ProtectedSystemRepair) 'unprotected or missing helper blocks repair'
}

Add-CoreTest -Tag AdminIntegration -Name 'cancelled UAC and failed helper are distinct nonzero repair results' {
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{ Helper='C:\Program Files\ClaudeSwitcher\helpers\ClaudeSwitcher.Admin.exe' } }
    function Start-Process { throw (New-Object ComponentModel.Win32Exception 1223) }
    Assert-Equal 4 (Invoke-ProtectedSystemRepair) 'UAC cancellation is explicit'
    function Start-Process { [pscustomobject]@{ ExitCode=5 } }
    Assert-Equal 1 (Invoke-ProtectedSystemRepair) 'partial helper failure is not success'
}

Add-CoreTest -Tag AdminIntegration -Name 'bodyguard task existence alone never passes health' {
    New-AdminTestWorkspace | Out-Null
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{ Script='C:\Program Files\ClaudeSwitcher\scripts\claude-bodyguard.ps1'; PowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' } }
    function Get-ScheduledTask { [pscustomobject]@{ State='Ready' } }
    Assert-False (Test-BodyguardHealth) 'idle task with no heartbeat cannot authorize launch'
}

Add-CoreTest -Tag AdminIntegration -Name 'system repair is skipped only when timezone IPv6 and bodyguard are healthy' {
    $script:TZ_TARGET='Tokyo Standard Time'
    $script:MockTimezone='Tokyo Standard Time'; $script:MockIpv6=@(); $script:MockBodyguard=$true
    function Get-TimeZone { [pscustomobject]@{Id=$script:MockTimezone} }
    function Get-NetAdapterBinding { $script:MockIpv6 }
    function Test-BodyguardHealth { $script:MockBodyguard }
    function Test-DNS { $true }
    Assert-False (Test-SystemRepairRequired) 'healthy state needs no UAC helper'
    $script:MockTimezone='Eastern Standard Time'
    Assert-True (Test-SystemRepairRequired) 'timezone drift needs repair'
    $script:MockTimezone=$script:TZ_TARGET; $script:MockIpv6=@([pscustomobject]@{Enabled=$true})
    Assert-True (Test-SystemRepairRequired) 'enabled IPv6 needs repair'
    $script:MockIpv6=@(); $script:MockBodyguard=$false
    Assert-True (Test-SystemRepairRequired) 'missing or stale bodyguard needs repair'
}

Add-CoreTest -Tag AdminIntegration -Name 'DNS-only failure requires the fixed system repair' {
    $script:TZ_TARGET='Tokyo Standard Time'
    function Get-TimeZone { [pscustomobject]@{Id='Tokyo Standard Time'} }
    function Get-NetAdapterBinding { @() }
    function Test-BodyguardHealth { $true }
    function Test-DNS { $false }
    Assert-True (Test-SystemRepairRequired) 'DNS must participate in the helper-owned repair trigger'
}

Add-CoreTest -Tag AdminIntegration -Name 'core ACL policy rejects generic mutation rights but ignores inherit-only entries' {
    $users='S-1-5-32-545'
    $genericWrite=[Enum]::ToObject([Security.AccessControl.FileSystemRights],[int]0x40000000)
    $genericAll=[Enum]::ToObject([Security.AccessControl.FileSystemRights],[int]0x10000000)
    Assert-True (Test-UnsafeWindowsAllow $users $genericWrite ([Security.AccessControl.PropagationFlags]::None)) 'generic write is unsafe'
    Assert-True (Test-UnsafeWindowsAllow $users $genericAll ([Security.AccessControl.PropagationFlags]::None)) 'generic all is unsafe'
    Assert-False (Test-UnsafeWindowsAllow $users ([Security.AccessControl.FileSystemRights]::WriteData) ([Security.AccessControl.PropagationFlags]::InheritOnly)) 'inherit-only ACE does not grant access on the current path'
}

Add-CoreTest -Tag AdminIntegration -Name 'fresh heartbeat and exact owned running task are required together' {
    New-AdminTestWorkspace | Out-Null
    $script:SyntheticSid='S-1-5-21-1-2-3-1001'
    $script:SyntheticPowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:SyntheticScript='C:\Program Files\ClaudeSwitcher\scripts\claude-bodyguard.ps1'
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:SyntheticSid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{ Script=$script:SyntheticScript; PowerShell=$script:SyntheticPowerShell } }
    $script:SyntheticArgs='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script:SyntheticScript + '"'
    $script:SyntheticTask=[pscustomobject]@{ TaskName="ClaudeSwitcher.Bodyguard.$script:SyntheticSid"; TaskPath='\'; State='Running'; Principal=[pscustomobject]@{UserId=$script:SyntheticSid;LogonType='Interactive';RunLevel='Limited'}; Settings=[pscustomobject]@{Enabled=$true;AllowDemandStart=$true;MultipleInstances='IgnoreNew';DisallowStartIfOnBatteries=$false;StopIfGoingOnBatteries=$false;ExecutionTimeLimit='PT0S'}; Actions=@([pscustomobject]@{Execute=$script:SyntheticPowerShell;Arguments=$script:SyntheticArgs}); Triggers=@([pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'};Enabled=$true;UserId=$script:SyntheticSid}) }
    $script:SyntheticLastRun=[DateTimeOffset]::UtcNow.AddSeconds(-10)
    function Get-ScheduledTask { @($script:SyntheticTask) }
    function Get-ScheduledTaskInfo { param($TaskName,$TaskPath,$ErrorAction) [pscustomobject]@{LastRunTime=$script:SyntheticLastRun} }
    function Get-Process { param([int]$Id) [pscustomobject]@{ Id=9876; SessionId=2; Path=$script:SyntheticPowerShell; StartTime=$script:SyntheticLastRun.AddSeconds(2);ProcessName='powershell' } }
    function Get-CimInstance {
        param($ClassName,$Filter,$ErrorAction)
        @([pscustomobject]@{ ProcessId=9876; CommandLine=('"'+$script:SyntheticPowerShell+'" '+$script:SyntheticArgs) })
    }
    function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ReturnValue=0;Sid=$script:SyntheticSid} }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:SyntheticSid }
    $heartbeat=[ordered]@{schemaVersion=1;userSid=$script:SyntheticSid;sessionId=2;processId=9876;updatedAt=[DateTimeOffset]::UtcNow.AddSeconds(-10).ToString('o')}
    $path=Join-Path $script:BASE 'bodyguard-heartbeat.json'
    [IO.File]::WriteAllText($path,($heartbeat|ConvertTo-Json))
    Assert-True (Test-BodyguardHealth) 'exact task and fresh session heartbeat pass'
    $heartbeat.updatedAt=[DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o'); [IO.File]::WriteAllText($path,($heartbeat|ConvertTo-Json))
    Assert-False (Test-BodyguardHealth) 'stale heartbeat blocks'
    $heartbeat.updatedAt=[DateTimeOffset]::UtcNow.AddSeconds(-10).ToString('o'); [IO.File]::WriteAllText($path,($heartbeat|ConvertTo-Json))
    $script:SyntheticTask.Actions[0].Arguments+=' -Command evil'
    Assert-False (Test-BodyguardHealth) 'extra task command blocks'
}

Add-CoreTest -Tag AdminIntegration -Name 'Claude process selection excludes other sessions and users and rejects unknown owners' {
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-Process { @([pscustomobject]@{Id=11;SessionId=2},[pscustomobject]@{Id=12;SessionId=3},[pscustomobject]@{Id=13;SessionId=2}) }
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) [pscustomobject]@{ ProcessId=([int]($Filter -replace '\D','')) } }
    function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ ReturnValue=0; Sid=if($InputObject.ProcessId -eq 11){'S-1-5-21-1-2-3-1001'}else{'S-1-5-21-1-2-3-1002'} } }
    $owned=@(Get-OwnedClaudeProcesses)
    Assert-Equal 1 $owned.Count 'only this user and session are included'
    Assert-Equal 11 $owned[0].Id 'matching process is selected'
    function Invoke-CimMethod { throw 'identity unavailable' }
    $rejected=$false
    try { $null=@(Get-OwnedClaudeProcesses) } catch { $rejected=$true }
    Assert-True $rejected 'unknown process owner must fail before a switch mutates data'
}

function Invoke-AdminMocks {
    param([hashtable]$Mocks, [scriptblock]$Body)
    $saved=@{}
    foreach($name in $Mocks.Keys) {
        $command=Get-Command $name -CommandType Function -ErrorAction SilentlyContinue
        $saved[$name]=if($command){$command.ScriptBlock}else{$null}
        Set-Item -Path "Function:\$name" -Value $Mocks[$name]
    }
    try { & $Body }
    finally {
        foreach($name in $Mocks.Keys) {
            if($null -ne $saved[$name]) { Set-Item -Path "Function:\$name" -Value $saved[$name] }
            else { Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue }
        }
    }
}

function New-LegacyBodyguardFixture {
    param([string]$Sid='S-1-5-21-1-2-3-1001',[string]$SessionId=2)
    $script:LegacySid=$Sid
    $script:LegacyPowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:LegacyScript=Join-Path $script:BASE 'claude-bodyguard.ps1'
    $script:LegacyArguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$script:LegacyScript+'"'
    $script:LegacyLastRun=[DateTimeOffset]::UtcNow.AddSeconds(-10)
    $script:LegacyTask=[pscustomobject]@{
        TaskName='ClaudeBodyguard'; TaskPath='\'; State='Running'
        Principal=[pscustomobject]@{UserId=$Sid;LogonType='Interactive';RunLevel='Limited'}
        Settings=[pscustomobject]@{Enabled=$true;AllowDemandStart=$true;MultipleInstances='IgnoreNew';DisallowStartIfOnBatteries=$false;StopIfGoingOnBatteries=$false;ExecutionTimeLimit='PT0S'}
        Triggers=@([pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'};Enabled=$true;UserId=$Sid})
        Actions=@([pscustomobject]@{Execute=$script:LegacyPowerShell;Arguments=$script:LegacyArguments})
    }
    $script:LegacyProcess=[pscustomobject]@{Id=4321;SessionId=[int]$SessionId;Path=$script:LegacyPowerShell;StartTime=$script:LegacyLastRun.AddSeconds(2);ProcessName='powershell'}
    $script:LegacyCim=[pscustomobject]@{ProcessId=4321;CommandLine=('"'+$script:LegacyPowerShell+'" '+$script:LegacyArguments)}
}

function Set-LegacyTaskMocks {
    # Return a scriptblock so dot-sourcing defines mocks in the test body scope.
    return {
        function Get-ScheduledTask { @($script:LegacyTask) }
        function Get-ScheduledTaskInfo { [pscustomobject]@{LastRunTime=$script:LegacyLastRun} }
        function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) @($script:LegacyCim) }
        function Get-Process { param([int]$Id) $script:LegacyProcess }
        function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ReturnValue=0;Sid=$script:LegacySid} }
    }
}

Add-CoreTest -Tag AdminIntegration -Name 'valid legacy bodyguard migrates then continues normal repair checks' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { $null }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    $script:PROXY_MODE='other'
    $script:MigrationCalls=0; $script:EgressCalls=0
    function Invoke-ProtectedBodyguardMigration { $script:MigrationCalls++; return 0 }
    function Test-ProxyAlive { $true }
    function Test-TunUp { $true }
    function Get-ProxyName { 'synthetic' }
    function Test-SystemRepairRequired { $false }
    function Get-Egress { $script:EgressCalls++; [pscustomobject]@{loc=$script:COUNTRY_TARGET;ip='203.0.113.10'} }
    function Start-Sleep { param($Seconds) }
    function Start-Process { throw 'no process may be launched after migration' }
    Assert-True (Test-BodyguardHealth) 'strict legacy task with correlated process is healthy'
    Assert-Equal 'Legacy' (Get-BodyguardTaskAssessment).Kind 'valid legacy is recognized narrowly'
    Invoke-Fix | Out-Null
    Assert-Equal 0 $script:FixExitCode 'successful migration no longer forces migration-required'
    Assert-Equal 1 $script:MigrationCalls 'migration runs exactly once'
    Assert-Equal 1 $script:EgressCalls 'normal post-migration repair checks continue'
    $script:PROXY_MODE='clash-verge'
}

Add-CoreTest -Tag AdminIntegration -Name 'legacy migration helper failure remains migration-required and preserves the old task' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { $null }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    $originalArguments=$script:LegacyTask.Actions[0].Arguments
    function Invoke-ProtectedBodyguardMigration { return 1 }
    function Test-ProxyAlive { throw 'normal repair must not run after migration failure' }
    function Invoke-ProtectedSystemRepair { throw 'system repair must not run after migration failure' }
    $output=@(Invoke-Fix)
    Assert-Equal 5 $script:FixExitCode 'failed migration is not reported as success'
    Assert-Match '迁移失败' ($output -join "`n") 'failure is reported as migration failure'
    Assert-Match '不会停止或删除旧任务' ($output -join "`n") 'failure states the old task is preserved'
    Assert-Equal $originalArguments $script:LegacyTask.Actions[0].Arguments 'failure does not rewrite the old task'
}

Add-CoreTest -Tag AdminIntegration -Name 'invalid legacy fix reports unsupported migration without mutating state' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { $null }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    $originalArguments=$script:LegacyTask.Actions[0].Arguments
    $script:LegacyTask.Actions[0].Arguments+=' -Command evil'
    $script:SideEffects=0
    function Test-ProxyAlive { $script:SideEffects++; throw 'proxy must not run' }
    function Invoke-ProtectedSystemRepair { $script:SideEffects++; throw 'helper must not run' }
    function Start-Process { $script:SideEffects++; throw 'process must not run' }
    $output=@(Invoke-Fix)
    Assert-Equal 'LegacyMigration' (Get-BodyguardTaskAssessment).Kind 'corrupted legacy task cannot pass health'
    Assert-Equal 5 $script:FixExitCode 'invalid legacy fix remains migration-required'
    Assert-Equal 0 $script:SideEffects 'invalid legacy fix has no side effects'
    Assert-Equal ($originalArguments+' -Command evil') $script:LegacyTask.Actions[0].Arguments 'legacy task is not rewritten'
    Assert-Match '不支持自动迁移' ($output -join "`n") 'guidance states automatic migration is unsupported'
    Assert-Match '不会停止或删除旧任务' ($output -join "`n") 'guidance states legacy task is preserved'
}

Add-CoreTest -Tag AdminIntegration -Name 'verified legacy migration uses only the protected fixed helper' {
    New-AdminTestWorkspace | Out-Null
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{ Helper='C:\Program Files\ClaudeSwitcher\helpers\ClaudeSwitcher.Admin.exe' } }
    $script:AdminLaunch=$null
    function Start-Process { param($FilePath,$Verb,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction,$WindowStyle) $script:AdminLaunch=[pscustomobject]@{File=$FilePath;Verb=$Verb;Arguments=$ArgumentList;Wait=$Wait;Style=$WindowStyle}; [pscustomobject]@{ExitCode=0} }
    Assert-Equal 0 (Invoke-ProtectedBodyguardMigration) 'protected migration success propagates'
    Assert-Equal 'RunAs' $script:AdminLaunch.Verb 'migration requires UAC'
    Assert-Match '--operation migrate-legacy-bodyguard --user-sid S-1-5-21-1-2-3-1001 --session-id 2' ($script:AdminLaunch.Arguments -join ' ') 'migration uses the closed scalar helper contract'
    Assert-False (($script:AdminLaunch.Arguments -join ' ') -match '(?i)claude-bodyguard\.ps1|Invoke-Expression|--command|--path') 'migration does not pass user-controlled paths or code'
}

Add-CoreTest -Tag AdminIntegration -Name 'legacy migration helper has closed failure codes' {
    New-AdminTestWorkspace | Out-Null
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid='S-1-5-21-1-2-3-1001'; SessionId=2 } }
    function Get-ProtectedWindowsPayload { $null }
    function Start-Process { throw 'missing payload must not elevate' }
    Assert-Equal 1 (Invoke-ProtectedBodyguardMigration) 'missing helper is a stable failure'

    function Get-ProtectedWindowsPayload { [pscustomobject]@{ Helper='C:\Program Files\ClaudeSwitcher\helpers\ClaudeSwitcher.Admin.exe' } }
    function Start-Process { throw (New-Object ComponentModel.Win32Exception 1223) }
    Assert-Equal 4 (Invoke-ProtectedBodyguardMigration) 'UAC cancellation is distinct'

    function Start-Process { [pscustomobject]@{ ExitCode=7 } }
    Assert-Equal 1 (Invoke-ProtectedBodyguardMigration) 'helper failure is not success'
}
Add-CoreTest -Tag AdminIntegration -Name 'native configuration never falls back to a legacy task' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { $null }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    [IO.File]::WriteAllText((Join-Path $script:BASE 'config.json'),'{"schemaVersion":1,"proxyMode":"clash-verge","proxyGroup":"GLOBAL","country":"US","timeZoneId":"Eastern Standard Time","culture":"en-US"}')
    Assert-Equal 'Invalid' (Get-BodyguardTaskAssessment).Kind 'native config requires the protected task'
    Assert-False (Test-BodyguardHealth) 'legacy task cannot satisfy native configuration'
}

Add-CoreTest -Tag AdminIntegration -Name 'invalid protected task never falls back to a valid legacy task' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    $script:ProtectedTask=[pscustomobject]@{TaskName=('ClaudeSwitcher.Bodyguard.'+$script:LegacySid);TaskPath='\';State='Running'}
    function Get-ScheduledTask { @($script:ProtectedTask) }
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{Script='C:\Program Files\ClaudeSwitcher\scripts\claude-bodyguard.ps1';PowerShell=$script:LegacyPowerShell} }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    Assert-Equal 'Invalid' (Get-BodyguardTaskAssessment).Kind 'invalid protected task is terminal'
    Assert-False (Test-BodyguardHealth) 'legacy fallback cannot mask a broken protected task'
}

Add-CoreTest -Tag AdminIntegration -Name 'legacy health rejects elevation writable scripts triggers settings and stale process correlation' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    $assessment=Get-BodyguardTaskAssessment
    Assert-True ($assessment.Kind -ceq 'Legacy') ("baseline legacy fixture is valid: kind={0} reason={1}" -f $assessment.Kind,$assessment.Reason)
    $acceptedCommands=@(
        ('"{0}" {1}' -f $script:LegacyPowerShell,$script:LegacyArguments),
        ('{0} {1}' -f $script:LegacyPowerShell,$script:LegacyArguments),
        ('"powershell.exe" {0}' -f $script:LegacyArguments),
        ('powershell.exe {0}' -f $script:LegacyArguments)
    )
    foreach ($command in $acceptedCommands) {
        $script:LegacyCim.CommandLine=$command
        Assert-True (Test-BodyguardHealth) ("legacy process command form is valid: {0}" -f $command)
    }
    $script:LegacyCim.CommandLine=$acceptedCommands[0]+' -Command evil'
    Assert-False (Test-BodyguardHealth) 'legacy process command injection is rejected'
    $script:LegacyCim.CommandLine=$acceptedCommands[0]
    $script:LegacyTask.Principal.RunLevel='Highest'
    Assert-False (Test-BodyguardHealth) 'elevated legacy task is not healthy'
    $script:LegacyTask.Principal.RunLevel='Limited'
    $script:LegacyTask.Triggers[0].CimClass.CimClassName='MSFT_TaskDailyTrigger'
    Assert-False (Test-BodyguardHealth) 'non-logon trigger is rejected'
    $script:LegacyTask.Triggers[0].CimClass.CimClassName='MSFT_TaskLogonTrigger'
    $script:LegacyTask.Triggers[0].Enabled=$false
    Assert-False (Test-BodyguardHealth) 'disabled trigger is rejected'
    $script:LegacyTask.Triggers[0].Enabled=$true
    $script:LegacyTask.Settings.AllowDemandStart=$null
    Assert-False (Test-BodyguardHealth) 'missing settings are rejected'
    $script:LegacyTask.Settings.AllowDemandStart=$true
    $script:LegacyProcess.StartTime=$script:LegacyLastRun.AddMinutes(-5)
    Assert-False (Test-BodyguardHealth) 'unrelated running process is rejected'
}

Add-CoreTest -Tag AdminIntegration -Name 'legacy script owner and action mismatches are migration states' {
    New-AdminTestWorkspace | Out-Null
    New-LegacyBodyguardFixture
    . (Set-LegacyTaskMocks)
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:LegacySid; SessionId=2 } }
    [IO.File]::WriteAllText($script:LegacyScript,'# synthetic legacy bodyguard')
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl 'S-1-5-21-1-2-3-2002' }
    Assert-Equal 'LegacyMigration' (Get-BodyguardTaskAssessment).Kind 'wrong script owner cannot be healthy'
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:LegacySid }
    $script:LegacyTask.Actions[0].Arguments+=' -Command evil'
    Assert-Equal 'LegacyMigration' (Get-BodyguardTaskAssessment).Kind 'wrong action cannot be healthy'
}

Add-CoreTest -Tag AdminIntegration -Name 'protected health requires exact demand settings and task-process correlation' {
    New-AdminTestWorkspace | Out-Null
    $script:ProtectedSid='S-1-5-21-1-2-3-1001'
    $script:ProtectedPowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:ProtectedScript='C:\Program Files\ClaudeSwitcher\scripts\claude-bodyguard.ps1'
    $script:ProtectedArguments='-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$script:ProtectedScript+'"'
    $script:ProtectedLastRun=[DateTimeOffset]::UtcNow.AddSeconds(-10)
    $script:ProtectedTask=[pscustomobject]@{
        TaskName=('ClaudeSwitcher.Bodyguard.'+$script:ProtectedSid); TaskPath='\'; State='Running'
        Principal=[pscustomobject]@{UserId=$script:ProtectedSid;LogonType='Interactive';RunLevel='Limited'}
        Settings=[pscustomobject]@{Enabled=$true;AllowDemandStart=$true;MultipleInstances='IgnoreNew';DisallowStartIfOnBatteries=$false;StopIfGoingOnBatteries=$false;ExecutionTimeLimit='PT0S'}
        Triggers=@([pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskLogonTrigger'};Enabled=$true;UserId=$script:ProtectedSid})
        Actions=@([pscustomobject]@{Execute=$script:ProtectedPowerShell;Arguments=$script:ProtectedArguments})
    }
    $script:ProtectedProcess=[pscustomobject]@{Id=9876;SessionId=2;Path=$script:ProtectedPowerShell;StartTime=$script:ProtectedLastRun.AddSeconds(2);ProcessName='powershell'}
    $script:ProtectedCim=[pscustomobject]@{ProcessId=9876;CommandLine=('"'+$script:ProtectedPowerShell+'" '+$script:ProtectedArguments)}
    function Get-ScheduledTask { @($script:ProtectedTask) }
    function Get-ScheduledTaskInfo { [pscustomobject]@{LastRunTime=$script:ProtectedLastRun} }
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) @($script:ProtectedCim) }
    function Get-Process { param([int]$Id) $script:ProtectedProcess }
    function Invoke-CimMethod { param($InputObject,$MethodName,$ErrorAction) [pscustomobject]@{ReturnValue=0;Sid=$script:ProtectedSid} }
    function Get-CoreCallerIdentity { [pscustomobject]@{ Sid=$script:ProtectedSid; SessionId=2 } }
    function Get-ProtectedWindowsPayload { [pscustomobject]@{Script=$script:ProtectedScript;PowerShell=$script:ProtectedPowerShell} }
    function Get-Acl { param($LiteralPath,$Path) New-TestAcl $script:ProtectedSid }
    $heartbeat=[ordered]@{schemaVersion=1;userSid=$script:ProtectedSid;sessionId=2;processId=9876;updatedAt=[DateTimeOffset]::UtcNow.AddSeconds(-10).ToString('o')}
    [IO.File]::WriteAllText((Join-Path $script:BASE 'bodyguard-heartbeat.json'),($heartbeat|ConvertTo-Json))
    Assert-True (Test-BodyguardHealth) 'fully correlated protected task is healthy'
    $script:ProtectedTask.Settings.AllowDemandStart=$null
    $script:ProtectedTask.Settings | Add-Member -NotePropertyName AllowStartOnDemand -NotePropertyValue $true -Force
    Assert-False (Test-BodyguardHealth) 'AllowStartOnDemand is not an acceptable substitute'
    $script:ProtectedTask.Settings.AllowDemandStart=$true
    $script:ProtectedProcess.StartTime=$script:ProtectedLastRun.AddMinutes(-5)
    Assert-False (Test-BodyguardHealth) 'process start time must correlate with task last run'
}

Add-CoreTest -Tag AdminIntegration -Name 'fix protocol maps migration exit five without reporting generic failure' {
    New-AdminTestWorkspace | Out-Null
    $script:CoreExitCode=5
    function Invoke-FixCommand { $script:CoreExitCode=5 }
    $result=Invoke-CoreRequest -Command 'fix' -Target '' -OperationId ([guid]::NewGuid())
    Assert-Equal 'migration-required' $result.code 'migration is a distinct protocol result'
    Assert-False $result.success 'migration-required is not success'
}
