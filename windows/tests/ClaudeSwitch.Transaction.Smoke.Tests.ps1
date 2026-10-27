Add-CoreTest 'transaction commits verified target and retains original data on archive failure' -Tag Transaction -Body {
    New-TestWorkspace | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'current.txt'),'A')
    [IO.File]::WriteAllText((Join-Path $DATA 'profile.txt'),'original-A')
    New-Item -ItemType Directory -Path (Join-Path $BASE 'accounts\B') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'accounts\B\profile.txt'),'target-B')
    function Invoke-AccountCopy { param($Source,$Destination) return 8 }
    $r=Invoke-AccountTransaction -Target B -OperationId ([guid]::NewGuid())
    Assert-False $r.success 'failed copy must fail transaction'
    Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $BASE 'current.txt'))) 'marker must stay A'
    Assert-Equal 'original-A' ([IO.File]::ReadAllText((Join-Path $DATA 'profile.txt'))) 'active A must survive'
}

Add-CoreTest 'verified transaction switches complete target using copy hook' -Tag Transaction -Body {
    New-TestWorkspace | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'current.txt'),'A')
    [IO.File]::WriteAllText((Join-Path $DATA 'profile.txt'),'original-A')
    New-Item -ItemType Directory -Path (Join-Path $BASE 'accounts\B') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'accounts\B\profile.txt'),'target-B')
    function Invoke-AccountCopy { param($Source,$Destination) New-Item -ItemType Directory -Path $Destination -Force | Out-Null; Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force; return 7 }
    $r=Invoke-AccountTransaction -Target B -OperationId ([guid]::NewGuid())
    Assert-True $r.success 'verified successful copy must commit'
    Assert-Equal 'B' ([IO.File]::ReadAllText((Join-Path $BASE 'current.txt'))) 'marker must commit B'
    Assert-Equal 'target-B' ([IO.File]::ReadAllText((Join-Path $DATA 'profile.txt'))) 'active profile must be complete B'
    Assert-Equal 'original-A' ([IO.File]::ReadAllText((Join-Path $BASE 'accounts\A\profile.txt'))) 'source snapshot must be preserved'
}

Add-CoreTest 'transaction exception after replacement recovers source and marker' -Tag Transaction -Body {
    New-TestWorkspace | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'current.txt'),'A')
    [IO.File]::WriteAllText((Join-Path $DATA 'profile.txt'),'original-A')
    New-Item -ItemType Directory -Path (Join-Path $BASE 'accounts\B') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'accounts\B\profile.txt'),'target-B')
    function Invoke-AccountCopy { param($Source,$Destination) New-Item -ItemType Directory -Path $Destination -Force | Out-Null; Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force; return 0 }
    function Invoke-TransactionCheckpoint { param($Phase) if($Phase -eq 'activeReplaced'){ throw 'synthetic interruption' } }
    $r=Invoke-AccountTransaction -Target B -OperationId ([guid]::NewGuid())
    Assert-False $r.success 'interruption must not claim completed switch'
    Assert-True (($r.current -eq 'A') -or $r.recoveryRequired) 'state must be rolled back or explicitly blocked'
    if(-not $r.recoveryRequired) { Assert-Equal 'original-A' ([IO.File]::ReadAllText((Join-Path $DATA 'profile.txt'))) 'rollback must restore A content'; Assert-Equal 'A' ([IO.File]::ReadAllText((Join-Path $BASE 'current.txt'))) 'rollback marker must be A' }
}

Add-CoreTest 'exclusive operation file handle refuses concurrent owner' -Tag Transaction -Body {
    New-TestWorkspace | Out-Null
    $first=Enter-OperationLock -WaitMilliseconds 0
    try { Assert-True ($null -ne $first) 'first owner must acquire'; $other=Enter-OperationLock -WaitMilliseconds 20; if($other){ Exit-OperationLock -Handle $other }; Assert-True ($null -eq $other) 'second owner must return busy' } finally { Exit-OperationLock -Handle $first }
}
Add-CoreTest 'CLI switch refuses busy owner before any fresh gate or launch' -Tag Transaction -Body {
    New-TestWorkspace | Out-Null
    $handle=Enter-OperationLock -WaitMilliseconds 0
    $script:BusyLaunchCalls=0
    function Test-LaunchGate { throw 'gate must not run while lock is owned elsewhere' }
    function Start-ClaudeApp { $script:BusyLaunchCalls++ }
    try { $r=@(Invoke-Switch A); Assert-Equal 0 $script:BusyLaunchCalls 'busy switch never launches'; Assert-True ($script:SwitchExitCode -ne 0) 'busy returns nonzero'; Assert-Match 'FAIL:' ($r -join "`n") 'busy has explicit failure' } finally { Exit-OperationLock -Handle $handle }
}

Add-CoreTest 'same-account entry cannot launch with a malformed pending journal' -Tag Transaction -Body {
    New-TestWorkspace | Out-Null
    [IO.File]::WriteAllText((Join-Path $BASE 'current.txt'),'A')
    [IO.File]::WriteAllText((Join-Path $BASE 'transaction.json'),'{bad json')
    $script:PendingLaunchCalls=0
    function Invoke-CheckDetail { New-CheckLines }
    function Start-ClaudeApp { $script:PendingLaunchCalls++ }
    $r=@(Invoke-Switch A)
    Assert-Equal 0 $script:PendingLaunchCalls 'pending recovery blocks even same-account launch'
    Assert-True ($script:SwitchExitCode -ne 0) 'pending recovery returns nonzero'
    Assert-True (Test-Path (Join-Path $BASE 'transaction.json')) 'malformed journal is retained'
}