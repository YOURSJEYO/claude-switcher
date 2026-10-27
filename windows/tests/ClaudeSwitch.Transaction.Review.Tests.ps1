# Isolated regressions for the Task 2/3 independent core review.
Add-CoreTest -Tag CoreReview -Name 'pre-journal transaction failure is ordinary exit one without recovery claim' {
    . New-TransactionFixture
    $script:ReviewLaunchCalls = 0
    function Test-LaunchGate { [pscustomobject]@{ CanLaunch=$true; Checks=@{}; BlockingReason='' } }
    function Stop-ClaudeApp { $true }
    function Start-ClaudeApp { $script:ReviewLaunchCalls++ }
    function Get-AccountTreeManifest { param([string]$Path) throw 'synthetic unreadable manifest before journal' }

    $result = Invoke-CoreRequest -Command switch -Target B -OperationId ([guid]::NewGuid().ToString('D'))

    Assert-False $result.success 'failed manifest generation cannot succeed'
    Assert-False $result.recoveryRequired 'a failure before journaling has no recovery data'
    Assert-Equal 1 $script:ProtocolExitCode 'ordinary failure must not use recovery exit three'
    Assert-Equal 'A' $result.current 'unchanged original account is reported'
    Assert-Equal 0 $script:ReviewLaunchCalls 'failed transaction cannot start Claude'
    Assert-False (Test-Path -LiteralPath (Join-Path $script:BASE 'transaction.json')) 'no journal was created'
    Assert-TransactionTree $script:DATA 'source-A' $script:TransactionSourceHash
}

Add-CoreTest -Tag CoreReview -Name 'legacy CLI status preserves exact archive-presence fields' {
    $root = New-TestWorkspace
    [IO.File]::WriteAllText((Join-Path $script:BASE 'current.txt'), 'B')
    [void][IO.Directory]::CreateDirectory((Join-Path $script:BASE 'accounts/A'))
    $wrapper = Join-Path $root 'legacy-status.ps1'
    $corePath = $script:CorePath.Replace("'", "''")
    $userPath = (Split-Path $script:BASE -Parent).Replace("'", "''")
    $dataPath = (Split-Path $script:DATA -Parent).Replace("'", "''")
    $localPath = (Join-Path $root 'local').Replace("'", "''")
    $source = "`$env:USERPROFILE='$userPath'; `$env:APPDATA='$dataPath'; `$env:LOCALAPPDATA='$localPath'; & '$corePath' status; exit `$LASTEXITCODE"
    [IO.File]::WriteAllText($wrapper, $source, (New-Object Text.UTF8Encoding($true)))
    $hostPath = (Get-Process -Id $PID).Path
    $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapper)
    Assert-Equal 0 $LASTEXITCODE 'idle legacy status exits zero'
    Assert-Equal 'current=B hasA=1 hasB=0' ($output -join '') 'legacy CLI status field contract is unchanged'
}

Add-CoreTest -Tag CoreReview -Name 'copy timeout observes both stream drains before disposing its process' {
    # Model a killed process whose asynchronous stream drains finish shortly afterwards.
    $script:ReviewDrainA = [Threading.Tasks.Task]::Delay(500)
    $script:ReviewDrainB = [Threading.Tasks.Task]::Delay(600)
    $script:ReviewCopy = [pscustomobject]@{
        StartInfo=$null; ExitCode=0; Killed=$false; DisposedBeforeDrain=$false
        StandardOutput=[pscustomobject]@{ BaseStream=[pscustomobject]@{} }
        StandardError=[pscustomobject]@{ BaseStream=[pscustomobject]@{} }
    }
    $script:ReviewCopy.StandardOutput.BaseStream | Add-Member ScriptMethod CopyToAsync { param($destination) return $script:ReviewDrainA }
    $script:ReviewCopy.StandardError.BaseStream | Add-Member ScriptMethod CopyToAsync { param($destination) return $script:ReviewDrainB }
    $script:ReviewCopy | Add-Member ScriptMethod Start { return $true }
    $script:ReviewCopy | Add-Member ScriptMethod WaitForExit { param($timeout) if ($args.Count -eq 0 -and $null -eq $timeout) { return }; return $false }
    $script:ReviewCopy | Add-Member ScriptMethod Kill { $this.Killed=$true }
    $script:ReviewCopy | Add-Member ScriptMethod Dispose { $this.DisposedBeforeDrain = -not ($script:ReviewDrainA.IsCompleted -and $script:ReviewDrainB.IsCompleted) }
    function New-Object {
        param([string]$TypeName)
        if ($TypeName -eq 'Diagnostics.Process') { return $script:ReviewCopy }
        Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName
    }

    $code = Invoke-AccountCopy -Source 'C:\synthetic-source' -Destination 'C:\synthetic-destination'

    Assert-Equal 16 $code 'timeout is a failing copy code'
    Assert-True $script:ReviewCopy.Killed 'only the synthetic timed-out child is terminated'
    Assert-False $script:ReviewCopy.DisposedBeforeDrain 'drains must be observed before process disposal'
}
