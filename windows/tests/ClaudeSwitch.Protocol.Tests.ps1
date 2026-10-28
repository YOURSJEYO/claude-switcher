# Bounded Task 3 core protocol regressions. Dot-sourced by Invoke-CoreTests.ps1.
# Every case uses the synthetic HOME/APPDATA created by New-TestWorkspace and replaces
# the check collector. No Claude, network, proxy, task, or system-setting API is called.

$script:ProtocolTestIds = @(
    'proxy_engine', 'tun_interface', 'egress_country', 'ip_consistency',
    'timezone', 'locale', 'ipv6', 'dns', 'webrtc', 'bodyguard',
    'routing_rules', 'client_language', 'asn', 'ecosystem'
)
$script:ProtocolTestNames = @(
    '代理内核', 'TUN网卡', '出口IP', 'IP一致', '时区', '地区', 'IPv6', 'DNS',
    'WebRTC', '保镖', '规则置顶', '客户端语言', 'ASN属性', '生态可达性'
)

function Assert-ProtocolEnvelope {
    param($Result, [string]$Command, [string]$OperationId)
    Assert-Equal 1 $Result.schemaVersion 'schemaVersion must be one'
    Assert-Equal $OperationId $Result.operationId 'operationId must echo the canonical request ID'
    Assert-Equal $Command $Result.command 'command must echo the request'
    foreach ($property in @('success', 'code', 'message')) {
        Assert-True ($null -ne $Result.PSObject.Properties[$property]) "envelope must include $property"
    }
}

function Assert-ProtocolInvalidChecks {
    param($Result)
    Assert-False $Result.success 'invalid raw check rows must fail'
    Assert-Equal 'invalid-checks' $Result.code 'invalid raw rows use the stable protocol code'
    Assert-False $Result.canLaunch 'invalid raw rows cannot authorize launch'
    Assert-Equal 14 @($Result.checks).Count 'invalid raw rows still return fourteen blocking records'
    Assert-Equal 14 @($Result.checks | Where-Object { $_.status -eq 'unknown' -and $_.blocking }).Count 'all invalid records must be unknown and blocking'
}

Add-CoreTest -Name 'protocol checkdetail returns one complete all-ok envelope' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines }
    $id = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $result = @(Invoke-CoreRequest -Command checkdetail -OperationId $id)
    Assert-Equal 1 $result.Count 'dispatcher returns exactly one object'
    Assert-ProtocolEnvelope $result[0] 'checkdetail' $id
    Assert-True $result[0].success 'all-ok checks succeed'
    Assert-Equal 'ok' $result[0].code 'all-ok code is ok'
    Assert-True $result[0].canLaunch 'all-ok checks authorize launch'
    Assert-Equal 14 @($result[0].checks).Count 'all fourteen checks are returned'
    Assert-Equal ($script:ProtocolTestIds -join '|') (@($result[0].checks | ForEach-Object { $_.id }) -join '|') 'stable IDs remain unique and ordered'
    Assert-Equal 14 @($result[0].checks | Select-Object -ExpandProperty id -Unique).Count 'check IDs are unique'
    Assert-Equal ($script:ProtocolTestNames -join '|') (@($result[0].checks | ForEach-Object { $_.name }) -join '|') 'stable names remain ordered'
    Assert-Equal 0 $script:ProtocolExitCode 'success exits zero'
}

Add-CoreTest -Name 'protocol warning allowlist is exactly ip consistency and asn' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines @{ 'IP一致'='warn:synthetic'; 'ASN属性'='warn:synthetic' } }
    $result = Invoke-CoreRequest -Command checkdetail -OperationId '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    Assert-True $result.success 'allowlisted warnings do not block'
    Assert-True $result.canLaunch 'allowlisted warnings permit launch'
    Assert-Equal 0 $script:ProtocolExitCode 'allowlisted warnings exit zero'
    foreach ($check in @($result.checks)) {
        $expectedBlocking = $check.status -ne 'ok' -and -not ($check.id -in @('ip_consistency','asn') -and $check.status -eq 'warn')
        Assert-Equal $expectedBlocking $check.blocking "blocking flag must be consistent for $($check.id)"
    }
}

Add-CoreTest -Name 'protocol blocks warnings outside the allowlist with fourteen rows' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines @{ 'DNS'='warn:synthetic' } }
    $result = Invoke-CoreRequest -Command checkdetail -OperationId '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    Assert-False $result.success 'disallowed warning fails'
    Assert-Equal 'blocked' $result.code 'disallowed warning is blocked'
    Assert-False $result.canLaunch 'disallowed warning cannot authorize launch'
    Assert-Equal 14 @($result.checks).Count 'blocked result retains fourteen checks'
    Assert-Equal 'warn' $result.checks[7].status 'the warning remains visible'
    Assert-Equal 1 $script:ProtocolExitCode 'blocked result exits one'
}

Add-CoreTest -Name 'protocol rejects missing duplicate and unknown check rows' -Tag Protocol -Body {
    $id = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $cases = @(
        @{ Name='missing'; Rows={ New-CheckLines -Skip @('DNS') } },
        @{ Name='duplicate'; Rows={ @(New-CheckLines) + @('DNS=ok:duplicate') } },
        @{ Name='unknown'; Rows={ @(New-CheckLines) + @('unknown_check=ok:synthetic') } }
    )
    foreach ($case in $cases) {
        New-TestWorkspace | Out-Null
        $rows = & $case.Rows
        $script:ProtocolFixtureRows = @($rows)
        function Invoke-CheckDetail { return $script:ProtocolFixtureRows }
        $result = Invoke-CoreRequest -Command checkdetail -OperationId $id
        Assert-ProtocolEnvelope $result 'checkdetail' $id
        Assert-ProtocolInvalidChecks $result
        Assert-Equal 1 $script:ProtocolExitCode "$($case.Name) rows exit nonzero"
    }
}

Add-CoreTest -Name 'protocol rejects unknown check state' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines @{ 'DNS'='maybe:synthetic' } }
    $result = Invoke-CoreRequest -Command checkdetail -OperationId '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    Assert-ProtocolInvalidChecks $result
    Assert-Equal 1 $script:ProtocolExitCode 'unknown state exits nonzero'
}

Add-CoreTest -Name 'protocol requires canonical nonempty GUID echo' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines }
    foreach ($bad in @('', '{3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f}', '3F6F37B4-7F19-4CA7-9EB1-7B99FBC7982F', 'not-a-guid', [guid]::Empty.ToString('D'))) {
        $result = Invoke-CoreRequest -Command checkdetail -OperationId $bad
        Assert-False $result.success "invalid operation ID must fail: $bad"
        Assert-Equal 'invalid-arguments' $result.code 'invalid IDs use invalid-arguments'
        Assert-Equal 64 $script:ProtocolExitCode 'invalid IDs exit 64'
    }
}

Add-CoreTest -Name 'protocol rejects malformed command and switch target without side effects' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $id = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $before = @(Get-ChildItem -LiteralPath $script:BASE -Recurse -Force).Count
    foreach ($request in @(
        @{ Command='check'; Target='' },
        @{ Command='switch'; Target='C' },
        @{ Command='switch'; Target='a' },
        @{ Command='status'; Target='A' }
    )) {
        $result = Invoke-CoreRequest -Command $request.Command -Target $request.Target -OperationId $id
        Assert-False $result.success 'invalid command/target must fail'
        Assert-Equal 'invalid-arguments' $result.code 'invalid command/target uses invalid-arguments'
        Assert-Equal 64 $script:ProtocolExitCode 'invalid command/target exits 64'
    }
    Assert-Equal $before @(Get-ChildItem -LiteralPath $script:BASE -Recurse -Force).Count 'invalid requests do not mutate synthetic state'
}

Add-CoreTest -Name 'protocol reports status and switch failures with active operation metadata' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $requestId = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $activeId = '76edf30d-d528-47dd-81e0-176f5a3cd895'
    $idle = Invoke-CoreRequest -Command status -OperationId $requestId
    Assert-ProtocolEnvelope $idle 'status' $requestId
    Assert-True $idle.success 'idle status succeeds'
    Assert-Equal 'idle' $idle.phase 'idle status reports idle'
    Assert-Equal 0 $script:ProtocolExitCode 'idle status exits zero'

    [IO.File]::WriteAllText((Join-Path $script:BASE 'current.txt'), 'A')
    [IO.File]::WriteAllText((Join-Path $script:BASE 'transaction.json'), (ConvertTo-Json -InputObject ([ordered]@{ schemaVersion=1; operationId=$activeId; source='A'; target='B'; phase='replacing' }) -Compress))
    $recovery = Invoke-CoreRequest -Command status -OperationId $requestId
    Assert-ProtocolEnvelope $recovery 'status' $requestId
    Assert-False $recovery.success 'recovery status fails'
    Assert-Equal 'recoveryRequired' $recovery.phase 'recovery phase is explicit'
    Assert-True $recovery.recoveryRequired 'recoveryRequired is true'
    Assert-Equal $activeId $recovery.activeOperationId 'status exposes the active transaction ID'
    Assert-Equal 'replacing' $recovery.transactionPhase 'status exposes the transaction phase'
    Assert-Equal 3 $script:ProtocolExitCode 'recovery exits three'

    function Invoke-Switch { param($Target, $OperationId) $script:SwitchExitCode=1; 'FAIL:synthetic switch failure' }
    $switch = Invoke-CoreRequest -Command switch -Target B -OperationId $requestId
    Assert-ProtocolEnvelope $switch 'switch' $requestId
    Assert-False $switch.success 'switch failure cannot claim success'
    Assert-Equal 'A' $switch.current 'switch failure preserves the verified current account'
    Assert-Equal 1 $script:ProtocolExitCode 'switch failure exits nonzero'
}

Add-CoreTest -Name 'protocol treats an orphaned setup lease as recovery material' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $requestId = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    [IO.File]::WriteAllText((Join-Path $script:BASE 'operation.lease.json'), '{"schemaVersion":1,"operationId":"orphaned"}')
    $result = Invoke-CoreRequest -Command status -OperationId $requestId
    Assert-ProtocolEnvelope $result 'status' $requestId
    Assert-False $result.success 'orphaned setup lease must fail status closed'
    Assert-Equal 'recovery-required' $result.code 'orphaned setup lease uses the recovery code'
    Assert-True $result.recoveryRequired 'orphaned setup lease requires explicit review'
    Assert-Equal 3 $script:ProtocolExitCode 'orphaned setup lease exits three'
}

Add-CoreTest -Name 'protocol blocks an orphaned lease directory before mutation' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    $leasePath = Join-Path $script:BASE 'operation.lease.json'
    New-Item -ItemType Directory -Force -Path $leasePath | Out-Null
    $handle = Enter-OperationLock -WaitMilliseconds 0
    Assert-True ($null -eq $handle) 'any orphan lease filesystem entry must block mutation'
    $result = Invoke-CoreRequest -Command status -OperationId '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    Assert-False $result.success 'lease directory must still fail status closed'
    Assert-True $result.recoveryRequired 'lease directory requires recovery review'
}

Add-CoreTest -Name 'protocol JSON mode emits exactly one parseable object and text mode remains fourteen rows' -Tag Protocol -Body {
    New-TestWorkspace | Out-Null
    function Invoke-CheckDetail { New-CheckLines }
    $id = '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    $response = Invoke-CoreRequest -Command checkdetail -OperationId $id
    $json = ConvertTo-Json -InputObject $response -Depth 8 -Compress
    $parsed = @($json | ConvertFrom-Json)
    Assert-Equal 1 $parsed.Count 'serialization produces one object'
    Assert-ProtocolEnvelope $parsed[0] 'checkdetail' $id

    $script:CoreExitCode = 0
    $text = @(Invoke-CheckCommand)
    Assert-Equal 14 $text.Count 'legacy text mode still emits fourteen rows'
    Assert-Equal 14 @($text | Where-Object { $_ -match '^[^=]+=(ok|warn|fail|unknown)(:|$)' }).Count 'legacy rows remain parseable'
    Assert-Equal 0 $script:CoreExitCode 'all-ok text checkdetail exits zero'
}
