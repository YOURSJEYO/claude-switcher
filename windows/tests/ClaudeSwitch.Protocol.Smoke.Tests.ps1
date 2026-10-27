Add-CoreTest -Name 'protocol returns complete fresh check result without printing diagnostics' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines }
    $id = [guid]::NewGuid().ToString('D')
    $result = @(Invoke-CoreRequest -Command checkdetail -OperationId $id)
    Assert-Equal 1 $result.Count 'one request returns exactly one object'
    Assert-Equal 1 $result[0].schemaVersion 'schema version is fixed'
    Assert-Equal $id $result[0].operationId 'operation identity must echo the request'
    Assert-Equal 14 @($result[0].checks).Count 'all checks are present'
    Assert-True $result[0].canLaunch 'complete valid checks permit launch'
    Assert-Equal 0 $script:ProtocolExitCode 'success must exit zero'
}

Add-CoreTest -Name 'protocol retains failed check details in nonzero result' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines @{ DNS = 'fail:synthetic DNS failure' } }
    $result = Invoke-CoreRequest -Command checkdetail -OperationId ([guid]::NewGuid().ToString('D'))
    Assert-False $result.success 'blocked checks cannot return command success'
    Assert-False $result.canLaunch 'blocked checks cannot authorize launch'
    Assert-Equal 'fail' $result.checks[7].status 'partial failure retains actual DNS status'
    Assert-Equal 1 $script:ProtocolExitCode 'failure must have a nonzero command exit'
}

Add-CoreTest -Name 'protocol status does not create metadata or perform recovery' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $before = @(Get-ChildItem -LiteralPath $script:BASE -Recurse -Force).Count
    $result = Invoke-CoreRequest -Command status -OperationId ([guid]::NewGuid().ToString('D'))
    Assert-Equal 'none' $result.current 'empty marker represents no account'
    Assert-Equal 'idle' $result.phase 'empty metadata represents idle'
    Assert-Equal $before @(Get-ChildItem -LiteralPath $script:BASE -Recurse -Force).Count 'status is readonly'
}

Add-CoreTest -Name 'protocol status preserves orphan material and reports unknown recovery operation' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    [void][IO.Directory]::CreateDirectory("$script:DATA.previous")
    $result = Invoke-CoreRequest -Command status -OperationId ([guid]::NewGuid().ToString('D'))
    Assert-False $result.success 'orphan recovery material is not a successful idle query'
    Assert-True $result.recoveryRequired 'orphan data blocks mutation'
    Assert-Equal 'recoveryRequired' $result.phase 'recovery state is explicit'
    Assert-Equal ([guid]::Empty.ToString('D')) $result.activeOperationId 'unknown original operation uses the documented empty GUID sentinel'
    Assert-Equal 'unverified' $result.transactionPhase 'unknown metadata is not a fabricated verified phase'
    Assert-True (Test-Path -LiteralPath "$script:DATA.previous") 'status cannot clean up recovery material'
}

Add-CoreTest -Name 'protocol redacts IPv4 IPv6 and credentials before output and cache' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines @{ 'IP一致' = 'warn:203.0.113.7 2001:db8::123 https://user:pass@example.invalid token=not-a-real-secret Bearer not-a-real-bearer' } }
    $result = Invoke-CoreRequest -Command checkdetail -OperationId ([guid]::NewGuid().ToString('D'))
    $json = ConvertTo-Json -InputObject $result -Depth 8
    Assert-False ($json -match '203\.0\.113\.7|2001:db8::123|user:pass|not-a-real-secret|not-a-real-bearer') 'protocol must not expose address or credential literals'
    $cache = [IO.File]::ReadAllText((Join-Path $script:BASE 'last-check.txt'))
    Assert-False ($cache -match '203\.0\.113\.7|2001:db8::123|user:pass|not-a-real-secret|not-a-real-bearer') 'cache must use the same redaction'
}

Add-CoreTest -Name 'protocol rejects noncanonical operation ID before account side effects' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $before = @(Get-ChildItem -LiteralPath $script:BASE -Recurse -Force).Count
    $result = Invoke-CoreRequest -Command switch -Target B -OperationId '{not-a-guid}'
    Assert-False $result.success 'invalid request must fail'
    Assert-Equal 64 $script:ProtocolExitCode 'invalid input has a stable nonzero exit'
    Assert-Equal $before @(Get-ChildItem -LiteralPath $script:BASE -Recurse -Force).Count 'invalid input must not mutate state'
}

Add-CoreTest -Name 'protocol fix reports cancelled authorization as a nonzero failure' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-Fix { $script:FixExitCode=4; 'synthetic cancelled authorization' }
    $result=Invoke-CoreRequest -Command fix -OperationId ([guid]::NewGuid().ToString('D'))
    Assert-False $result.success "cancelled helper cannot be reported as fixed (code=$($result.code), exit=$script:ProtocolExitCode, fix=$script:FixExitCode)"
    Assert-Equal 4 $script:ProtocolExitCode 'cancellation must survive wrapper normalization'
    Assert-Equal 'cancelled' $result.code 'cancellation has an explicit protocol result'
}

Add-CoreTest -Name 'protocol status observes a live operation identity without waiting on its lock' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $owner=[guid]::NewGuid(); $held=Enter-OperationLock -WaitMilliseconds 100
    try {
        Write-CoreActivity $owner 'switch' 'checking'
        $result=Invoke-CoreRequest -Command status -OperationId ([guid]::NewGuid().ToString('D'))
        Assert-Equal 'running' $result.phase 'a live lock owner must be observable'
        Assert-Equal $owner.ToString('D') $result.activeOperationId 'status must report the active owner, not its query ID'
        Assert-Equal 'checking' $result.transactionPhase 'status retains a bounded known phase'
    } finally { Remove-CoreActivity; Exit-OperationLock -Handle $held }
}
