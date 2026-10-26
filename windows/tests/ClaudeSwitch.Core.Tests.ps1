# STUN positive fixtures use IANA anycast literals only as data; every probe is stubbed, never sent.
Add-CoreTest 'same-account launch blocks when fresh egress check fails' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    $script:GateCalls = 0
    $script:LaunchCalls = 0
    function Invoke-CheckDetail {
        $script:GateCalls++
        New-CheckLines @{ '出口IP' = 'fail:synthetic-egress' }
    }
    function Start-ClaudeApp { $script:LaunchCalls++ }

    $output = @(Invoke-Switch 'A')

    Assert-Equal 1 $script:GateCalls 'the same-account branch must run the fresh gate once'
    Assert-Equal 0 $script:LaunchCalls 'the launcher must not run after a failed egress check'
    Assert-Equal 1 $script:SwitchExitCode 'a blocked launch must return nonzero'
    Assert-Match '^FAIL:' ($output -join "`n") 'the blocked launch must report a failure'
}

Add-CoreTest 'A-to-B pre-mutation gate failure blocks all account side effects' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts\B') | Out-Null
    $sentinel = Join-Path $script:DATA 'sentinel.txt'
    'unchanged' | Out-File -Encoding ascii -NoNewline $sentinel
    $script:GateCalls = 0
    $script:StopCalls = 0
    $script:SaveCalls = 0
    $script:LaunchCalls = 0
    function Stop-ClaudeApp { $script:StopCalls++; return $true }
    function Save-Account { param($name) $script:SaveCalls++ }
    function Invoke-CheckDetail {
        $script:GateCalls++
        New-CheckLines @{ '出口IP' = 'fail:synthetic-country' }
    }
    function Start-ClaudeApp { $script:LaunchCalls++ }

    $output = @(Invoke-Switch 'B')

    Assert-Equal 1 $script:GateCalls 'the pre-mutation gate must run exactly once'
    Assert-Equal 0 $script:StopCalls 'a failed pre-mutation gate must not stop Claude'
    Assert-Equal 0 $script:SaveCalls 'a failed pre-mutation gate must not archive an account'
    Assert-Equal 0 $script:LaunchCalls 'a failed pre-mutation gate must not launch Claude'
    Assert-True (Test-Path $sentinel) 'a failed pre-mutation gate must not replace account data'
    Assert-Equal 'unchanged' ((Get-Content $sentinel -Raw).Trim()) 'a failed pre-mutation gate must leave data unchanged'
    Assert-Equal 'A' ((Get-Content (Join-Path $script:BASE 'current.txt') -Raw).Trim()) 'a failed pre-mutation gate must leave current.txt unchanged'
    Assert-Equal 1 $script:SwitchExitCode 'a blocked switch must return nonzero'
    Assert-Match '^FAIL:' ($output -join "`n") 'the blocked switch must report a failure'
}

Add-CoreTest 'STUN no response is unknown rather than safe' {
    function Get-StunPublicIP { param($server, $port, $timeoutMs) return $null }

    $result = Get-StunAssessment -ExitIp '192.0.0.9'

    Assert-False $result.Ok 'no STUN response must block'
    Assert-Equal 'unknown' $result.Code 'no STUN response must be reported as unknown'
}

Add-CoreTest 'STUN malformed response blocks' {
    function Get-StunPublicIP { param($server, $port, $timeoutMs) return @{ State = 'malformed'; Ip = $null } }

    $result = Get-StunAssessment -ExitIp '192.0.0.9'

    Assert-False $result.Ok 'a malformed STUN response must block'
    Assert-Equal 'fail' $result.Code 'a malformed STUN response must fail'
}

Add-CoreTest 'STUN mismatched public address blocks without exposing it' {
    function Get-StunPublicIP { param($server, $port, $timeoutMs) return '192.0.0.10' }

    $result = Get-StunAssessment -ExitIp '192.0.0.9'

    Assert-False $result.Ok 'a mismatched STUN address must block'
    Assert-Equal 'fail' $result.Code 'a mismatched STUN address must fail'
    Assert-False ($result.Detail -match '192\.0\.0\.10') 'user-facing detail must omit the observed address'
}

Add-CoreTest 'STUN probe exception blocks' {
    function Get-StunPublicIP { param($server, $port, $timeoutMs) throw 'synthetic probe error' }

    $result = Get-StunAssessment -ExitIp '192.0.0.9'

    Assert-False $result.Ok 'a STUN probe exception must block'
    Assert-Equal 'fail' $result.Code 'a STUN probe exception must fail'
}

Add-CoreTest 'STUN matching fresh egress is safe' {
    function Get-StunPublicIP { param($server, $port, $timeoutMs) return '192.0.0.9' }

    $result = Get-StunAssessment -ExitIp '192.0.0.9'

    Assert-True $result.Ok 'a valid response matching fresh egress must pass'
    Assert-Equal 'ok' $result.Code 'a matching STUN response must be ok'
}

Add-CoreTest 'invalid account target is rejected before side effects' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    $script:StopCalls = 0
    $script:LaunchCalls = 0
    $script:SaveCalls = 0
    function Stop-ClaudeApp { $script:StopCalls++; return $true }
    function Save-Account { param($name) $script:SaveCalls++ }
    function Start-ClaudeApp { $script:LaunchCalls++ }

    $threw = $false
    try { Invoke-Switch 'C' | Out-Null } catch { $threw = $true }

    Assert-True $threw 'an invalid target must be rejected by parameter validation'
    Assert-Equal 0 $script:StopCalls 'invalid targets must not stop Claude'
    Assert-Equal 0 $script:SaveCalls 'invalid targets must not touch account data'
    Assert-Equal 0 $script:LaunchCalls 'invalid targets must not launch Claude'
}

Add-CoreTest 'launch gate blocks output that omits a required check' {
    function Invoke-CheckDetail { New-CheckLines -Skip @('WebRTC') }

    $result = Test-LaunchGate

    Assert-False $result.CanLaunch 'incomplete check output must block launch'
    Assert-Equal 'checks-incomplete' $result.BlockingReason 'incomplete output must have a stable reason'
    Assert-False $result.Checks.ContainsKey('WebRTC') 'the missing check must remain absent from parsed checks'
}

Add-CoreTest 'launch gate permits a complete all-ok check output' {
    function Invoke-CheckDetail { New-CheckLines }

    $result = Test-LaunchGate

    Assert-True $result.CanLaunch 'a complete all-ok output must permit launch'
    Assert-Equal '' $result.BlockingReason 'a passing gate must have no blocking reason'
    Assert-Equal 14 $result.Checks.Count 'all required checks must be retained in the result'
}

Add-CoreTest 'successful A-to-B switch runs pre-gate, then final gate, then launch' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts\B') | Out-Null
    $script:Events = @()
    function Stop-ClaudeApp { $script:Events += 'stop'; return $true }
    function Save-Account { param($name) $script:Events += 'save'; return $true }
    function Invoke-CheckDetail {
        $script:Events += 'gate'
        New-CheckLines
    }
    function robocopy { $script:Events += 'target-copy'; $global:LASTEXITCODE = 7; 'synthetic robocopy output' }
    function Start-ClaudeApp { $script:Events += 'launch' }

    Invoke-Switch 'B' | Out-Null

    Assert-Equal 6 $script:Events.Count 'the switch must pre-gate, stop, save, stage target, final-gate, then launch'
    Assert-Equal 'gate' $script:Events[0] 'the first gate must run before any account mutation'
    Assert-Equal 'stop' $script:Events[1] 'Claude must stop only after the pre-gate passes'
    Assert-Equal 'save' $script:Events[2] 'the source account must be archived after stopping Claude'
    Assert-Equal 'target-copy' $script:Events[3] 'target restore must finish before the final gate'
    Assert-Equal 'gate' $script:Events[4] 'the final fresh gate must run after account mutation'
    Assert-Equal 'launch' $script:Events[5] 'the launcher must run only after the final gate'
    Assert-Equal 0 $script:SwitchExitCode 'a permitted launch must return success'
}

Add-CoreTest 'A-to-B final gate failure after mutation blocks launch' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts\B') | Out-Null
    $script:GateCalls = 0
    $script:LaunchCalls = 0
    function Stop-ClaudeApp { return $true }
    function Save-Account { param($name) return $true }
    function Invoke-CheckDetail {
        $script:GateCalls++
        if ($script:GateCalls -eq 1) { New-CheckLines }
        else { New-CheckLines @{ '出口IP' = 'fail:synthetic-final-egress' } }
    }
    function robocopy { $global:LASTEXITCODE = 0; 'synthetic robocopy output' }
    function Start-ClaudeApp { $script:LaunchCalls++ }

    $output = @(Invoke-Switch 'B')

    Assert-Equal 2 $script:GateCalls 'the final fresh gate must run after account mutation'
    Assert-Equal 0 $script:LaunchCalls 'a failed final gate must not launch Claude'
    Assert-Equal 1 $script:SwitchExitCode 'a failed final gate must return nonzero'
    Assert-Equal 'B' ((Get-Content (Join-Path $script:BASE 'current.txt') -Raw).Trim()) 'the committed target must be reported accurately'
    Assert-Match '^FAIL:启动前检查未通过' ($output -join "`n") 'the final gate failure must identify the launch-time check'
}

Add-CoreTest 'launch gate permits only IP consistency and ASN warnings' {
    function Invoke-CheckDetail {
        New-CheckLines @{
            'IP一致' = 'warn:synthetic-ip-change'
            'ASN属性' = 'warn:synthetic-datacenter'
        }
    }

    $result = Test-LaunchGate

    Assert-True $result.CanLaunch 'IP consistency and ASN warnings must not block launch'
    Assert-Equal '' $result.BlockingReason 'allowed warnings must not set a blocking reason'
    Assert-Equal 'warn' $result.Checks['IP一致'] 'the IP consistency warning must be retained'
    Assert-Equal 'warn' $result.Checks['ASN属性'] 'the ASN warning must be retained'
}

Add-CoreTest 'first-run collection to same account requires a fresh gate before launch' {
    New-TestWorkspace | Out-Null
    'initial' | Out-File -Encoding ascii -NoNewline (Join-Path $script:DATA 'sentinel.txt')
    $script:Events = @()
    function Stop-ClaudeApp { $script:Events += 'stop'; return $true }
    function Save-Account { param($name) $script:Events += "save:$name"; return $true }
    function Invoke-CheckDetail {
        $script:Events += 'gate'
        if (@($script:Events | Where-Object { $_ -eq 'gate' }).Count -eq 1) { New-CheckLines }
        else { New-CheckLines @{ '出口IP' = 'fail:synthetic-first-run-final' } }
    }
    function Start-ClaudeApp { $script:Events += 'launch' }

    $output = @(Invoke-Switch 'A')

    Assert-Equal 4 $script:Events.Count 'first-run collection must pre-gate, stop, save, then final-gate'
    Assert-Equal 'gate' $script:Events[0] 'the initial gate must run before collection'
    Assert-Equal 'stop' $script:Events[1] 'Claude must stop after the initial gate'
    Assert-Equal 'save:A' $script:Events[2] 'the current login must be archived as A'
    Assert-Equal 'gate' $script:Events[3] 'a fresh gate must run after collection changes state'
    Assert-Equal 0 @($script:Events | Where-Object { $_ -eq 'launch' }).Count 'the launcher must not run after the final gate fails'
    Assert-Equal 1 $script:SwitchExitCode 'the blocked first-run launch must return nonzero'
    Assert-Match 'FAIL:启动前检查未通过' ($output -join "`n") 'the final gate failure must identify the launch-time check'
}
Add-CoreTest 'same-account switch without mutation runs only one fresh gate' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    $script:Events = @()
    function Invoke-CheckDetail { $script:Events += 'gate'; New-CheckLines }
    function Start-ClaudeApp { $script:Events += 'launch' }

    Invoke-Switch 'A' | Out-Null

    Assert-Equal 2 $script:Events.Count 'an unchanged same-account launch must gate once and launch once'
    Assert-Equal 'gate' $script:Events[0] 'the gate must run before launch'
    Assert-Equal 'launch' $script:Events[1] 'the launch must follow the gate'
    Assert-Equal 0 $script:SwitchExitCode 'the unchanged same-account launch must succeed'
}
Add-CoreTest 'launch gate blocks non-allowlisted warnings' {
    function Invoke-CheckDetail { New-CheckLines @{ 'DNS' = 'warn:synthetic-dns' } }

    $result = Test-LaunchGate

    Assert-False $result.CanLaunch 'warnings outside the two-item allowlist must block'
    Assert-Equal 'check-failed' $result.BlockingReason 'a disallowed warning must use the stable failed-check reason'
    Assert-Equal 'warn' $result.Checks['DNS'] 'the disallowed warning must remain visible in the result'
}
Add-CoreTest 'launch gate blocks duplicate required checks' {
    function Invoke-CheckDetail { @(New-CheckLines) + @('出口IP=ok:synthetic-duplicate') }

    $result = Test-LaunchGate

    Assert-False $result.CanLaunch 'duplicate required checks must block launch'
    Assert-Equal 'checks-duplicate' $result.BlockingReason 'duplicate checks must have a stable reason'
}

Add-CoreTest 'launch gate blocks unknown check rows' {
    function Invoke-CheckDetail { @(New-CheckLines) + @('未知检查=ok:synthetic-unknown') }

    $result = Test-LaunchGate

    Assert-False $result.CanLaunch 'unknown check rows must block launch'
    Assert-Equal 'checks-unknown' $result.BlockingReason 'unknown checks must have a stable reason'
}

Add-CoreTest 'launch gate blocks nonempty delimiter-free rows' {
    function Invoke-CheckDetail { @(New-CheckLines) + @('malformed synthetic check row') }

    $result = Test-LaunchGate

    Assert-False $result.CanLaunch 'nonempty malformed rows must block launch'
    Assert-Equal 'checks-malformed' $result.BlockingReason 'malformed rows must have a stable reason'
}

Add-CoreTest 'source archive accepts robocopy exit codes zero through seven' {
    New-TestWorkspace | Out-Null
    function robocopy {
        $global:LASTEXITCODE = $script:MockRobocopyExitCode
        'synthetic robocopy output'
    }

    foreach ($exitCode in 0..7) {
        $script:MockRobocopyExitCode = $exitCode
        Assert-True (Save-Account 'A') "robocopy exit code $exitCode must be successful"
    }
}

Add-CoreTest 'source archive robocopy failure blocks all later switch steps' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts\B') | Out-Null
    $sentinel = Join-Path $script:DATA 'sentinel.txt'
    'active-data' | Out-File -Encoding ascii -NoNewline $sentinel
    $script:Events = @()
    $script:RoboCalls = @()
    $script:GateCalls = 0
    $script:LaunchCalls = 0
    function Stop-ClaudeApp { $script:Events += 'stop'; return $true }
    function Invoke-CheckDetail { $script:GateCalls++; $script:Events += 'gate'; New-CheckLines }
    function Start-ClaudeApp { $script:LaunchCalls++; $script:Events += 'launch' }
    function robocopy {
        $script:RoboCalls += ,@($args)
        $script:Events += 'source-archive'
        $global:LASTEXITCODE = 8
        'synthetic robocopy output'
    }

    $output = @(Invoke-Switch 'B')

    Assert-Equal 1 $script:RoboCalls.Count 'only the source archive copy may run'
    Assert-Equal 1 $script:GateCalls 'a failed source archive must not run the final gate'
    Assert-Equal 0 $script:LaunchCalls 'a failed source archive must not launch Claude'
    Assert-Equal 'gate,stop,source-archive' ($script:Events -join ',') 'source archive failure must stop the switch immediately'
    Assert-Equal 'A' ((Get-Content (Join-Path $script:BASE 'current.txt') -Raw).Trim()) 'source archive failure must preserve current.txt'
    Assert-Equal 'active-data' ((Get-Content $sentinel -Raw).Trim()) 'source archive failure must preserve active DATA'
    Assert-Equal 1 $script:SwitchExitCode 'source archive failure must return nonzero'
    Assert-Match '^FAIL:' ($output -join "`n") 'source archive failure must report a failure'
}

Add-CoreTest 'target archive robocopy failure preserves active data and staging' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts\B') | Out-Null
    $sentinel = Join-Path $script:DATA 'sentinel.txt'
    'active-data' | Out-File -Encoding ascii -NoNewline $sentinel
    $staging = "$script:DATA.claude-switch-staging"
    $script:Events = @()
    $script:RoboCalls = @()
    $script:GateCalls = 0
    $script:LaunchCalls = 0
    function Stop-ClaudeApp { $script:Events += 'stop'; return $true }
    function Invoke-CheckDetail { $script:GateCalls++; $script:Events += 'gate'; New-CheckLines }
    function Start-ClaudeApp { $script:LaunchCalls++; $script:Events += 'launch' }
    function robocopy {
        $script:RoboCalls += ,@($args)
        if ($script:RoboCalls.Count -eq 1) {
            $script:Events += 'source-archive'
            $global:LASTEXITCODE = 7
        } else {
            $script:Events += 'target-restore'
            New-Item -ItemType Directory -Force -Path $args[1] | Out-Null
            'partial-target-copy' | Out-File -Encoding ascii -NoNewline (Join-Path $args[1] 'partial.txt')
            $global:LASTEXITCODE = 8
        }
        'synthetic robocopy output'
    }

    $output = @(Invoke-Switch 'B')

    Assert-Equal 2 $script:RoboCalls.Count 'source archive and staged target restore must both run'
    Assert-Equal $staging $script:RoboCalls[1][1] 'target restore must copy to a sidecar beside active DATA'
    Assert-Equal 1 $script:GateCalls 'a failed target restore must not run the final gate'
    Assert-Equal 0 $script:LaunchCalls 'a failed target restore must not launch Claude'
    Assert-Equal 'A' ((Get-Content (Join-Path $script:BASE 'current.txt') -Raw).Trim()) 'target restore failure must preserve current.txt'
    Assert-Equal 'active-data' ((Get-Content $sentinel -Raw).Trim()) 'target restore failure must preserve active DATA'
    Assert-True (Test-Path (Join-Path $staging 'partial.txt')) 'failed staging must remain for explicit recovery'
    Assert-Equal 1 $script:SwitchExitCode 'target restore failure must return nonzero'
    Assert-Match '^FAIL:' ($output -join "`n") 'target restore failure must report a failure'
}

Add-CoreTest 'switch refuses to overwrite a prior restore staging residue' {
    New-TestWorkspace | Out-Null
    'A' | Out-File -Encoding ascii -NoNewline (Join-Path $script:BASE 'current.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts\B') | Out-Null
    $sentinel = Join-Path $script:DATA 'sentinel.txt'
    'active-data' | Out-File -Encoding ascii -NoNewline $sentinel
    $staging = "$script:DATA.claude-switch-staging"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    'recovery-data' | Out-File -Encoding ascii -NoNewline (Join-Path $staging 'recovery.txt')
    $script:GateCalls = 0
    $script:StopCalls = 0
    $script:LaunchCalls = 0
    $script:RoboCalls = 0
    function Stop-ClaudeApp { $script:StopCalls++; return $true }
    function Invoke-CheckDetail { $script:GateCalls++; New-CheckLines }
    function Start-ClaudeApp { $script:LaunchCalls++ }
    function robocopy { $script:RoboCalls++; $global:LASTEXITCODE = 0 }

    $output = @(Invoke-Switch 'B')

    Assert-Equal 1 $script:GateCalls 'the pre-mutation gate may run once'
    Assert-Equal 0 $script:StopCalls 'a prior staging residue must be detected before stopping Claude'
    Assert-Equal 0 $script:RoboCalls 'a prior staging residue must not be overwritten by robocopy'
    Assert-Equal 0 $script:LaunchCalls 'a prior staging residue must block launch'
    Assert-Equal 'A' ((Get-Content (Join-Path $script:BASE 'current.txt') -Raw).Trim()) 'a prior staging residue must preserve current.txt'
    Assert-Equal 'active-data' ((Get-Content $sentinel -Raw).Trim()) 'a prior staging residue must preserve active DATA'
    Assert-Equal 'recovery-data' ((Get-Content (Join-Path $staging 'recovery.txt') -Raw).Trim()) 'the prior staging contents must remain unchanged'
    Assert-Equal 1 $script:SwitchExitCode 'a prior staging residue must return nonzero'
    Assert-Match '^FAIL:' ($output -join "`n") 'a prior staging residue must report a failure'
}

Add-CoreTest 'public IPv4 validation rejects private reserved and noncanonical addresses' {
    foreach ($ip in @('0.0.0.0','10.1.2.3','100.64.0.1','127.0.0.1','169.254.1.1','172.16.1.1','192.168.1.1','192.0.0.8','192.0.2.1','192.88.99.1','198.18.0.1','198.51.100.1','203.0.113.1','224.0.0.1','240.0.0.1','255.255.255.255','127.1','0x7f000001','010.1.1.1','::1')) {
        Assert-False (Test-PublicIPv4Address $ip) ('must reject nonpublic/noncanonical input: ' + $ip)
    }
    # IANA special-purpose globally reachable anycast literals; no network call.
    Assert-True (Test-PublicIPv4Address '192.0.0.9') 'the IANA globally reachable exception must be accepted'
    Assert-True (Test-PublicIPv4Address '192.0.0.10') 'the second globally reachable exception must be accepted'
}

Add-CoreTest 'STUN matching private exit cannot authorize launch' {
    function Get-StunPublicIP { param($server,$port,$timeoutMs) return @{ State='response'; Ip='10.1.2.3' } }
    $assessment = Get-StunAssessment -ExitIp '10.1.2.3'
    Assert-False $assessment.Ok 'matching private inputs are not verified public egress'
}