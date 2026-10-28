# Core consumption of versioned user configuration; all files are synthetic.
function Write-CoreConfigurationFixture {
    param([hashtable]$Overrides = @{})
    $config = [ordered]@{ schemaVersion=1; proxyMode='other'; proxyGroup=''; country='JP'; timeZoneId='Tokyo Standard Time'; culture='ja-JP' }
    foreach ($key in $Overrides.Keys) { $config[$key]=$Overrides[$key] }
    [IO.File]::WriteAllText((Join-Path $script:BASE 'config.json'), ($config | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

Add-CoreTest -Tag Configuration -Name 'core loads versioned scalar user settings including the culture target' {
    New-TestWorkspace | Out-Null
    Write-CoreConfigurationFixture
    Assert-True (Import-CoreConfiguration) 'valid config is consumed without executing any code'
    Assert-Equal 'other' $script:PROXY_MODE 'configured proxy mode is applied'
    Assert-Equal 'JP' $script:COUNTRY_TARGET 'configured country is applied'
    Assert-Equal 'Tokyo Standard Time' $script:TZ_TARGET 'configured time zone is applied'
    Assert-Equal 'ja-JP' $script:LOCALE_TARGET 'configured culture is applied'
}

Add-CoreTest -Tag Configuration -Name 'invalid config blocks a gate before any network or process work' {
    New-TestWorkspace | Out-Null
    Write-CoreConfigurationFixture @{ country='CN' }
    $script:ConfigurationProbeCalls=0
    function Invoke-CheckDetail { $script:ConfigurationProbeCalls++; New-CheckLines }
    $gate=Test-LaunchGate
    Assert-False $gate.CanLaunch 'untrusted configuration cannot authorize launch'
    Assert-Equal 'configuration-invalid' $gate.BlockingReason 'configuration failure is explicit'
    Assert-Equal 0 $script:ConfigurationProbeCalls 'invalid config must fail before probe side effects'
}

Add-CoreTest -Tag Configuration -Name 'core rejects malformed unsupported and code-like configuration as data' {
    New-TestWorkspace | Out-Null
    foreach ($changes in @(
        @{ schemaVersion=2 }, @{ schemaVersion='1' }, @{ country='ZZ' },
        @{ culture='en-US' }, @{ timeZoneId='not-a-zone' }, @{ proxyMode='run-script' },
        @{ proxyMode='clash-verge'; proxyGroup='x; Start-Process calc' },
        @{ country=@('JP') }, @{ unexpected='caller script' }
    )) {
        Write-CoreConfigurationFixture $changes
        Assert-False (Import-CoreConfiguration) 'invalid fields or types are rejected'
    }
    [IO.File]::WriteAllText((Join-Path $script:BASE 'config.json'), '{"schemaVersion":1}; throw "not data"')
    Assert-False (Import-CoreConfiguration) 'executable-looking input is not evaluated'
}

Add-CoreTest -Tag Configuration -Name 'missing config preserves legacy installation without writing or guessing a region' {
    New-TestWorkspace | Out-Null
    $script:COUNTRY_TARGET='GB'; $script:TZ_TARGET='GMT Standard Time'
    $before=@(Get-ChildItem -LiteralPath $script:BASE -Force).Count
    Assert-True (Import-CoreConfiguration) 'legacy configured script remains supported'
    Assert-Equal 'GB' $script:COUNTRY_TARGET 'legacy country is not reset to US'
    Assert-Equal 'GMT Standard Time' $script:TZ_TARGET 'legacy time zone is preserved'
    Assert-Equal $before @(Get-ChildItem -LiteralPath $script:BASE -Force).Count 'configuration read creates no files'
}

Add-CoreTest -Tag Configuration -Name 'invalid config blocks repair before proxy or elevated work' {
    New-TestWorkspace | Out-Null
    Write-CoreConfigurationFixture @{ schemaVersion=2 }
    $script:ConfigurationSideEffects=0
    function Test-ProxyAlive { $script:ConfigurationSideEffects++; return $false }
    function Test-TunUp { $script:ConfigurationSideEffects++; return $false }
    function Get-TimeZone { $script:ConfigurationSideEffects++; return [pscustomobject]@{ Id='Synthetic Zone' } }
    function Get-NetAdapterBinding { $script:ConfigurationSideEffects++; return @() }
    function Get-ScheduledTask { $script:ConfigurationSideEffects++; return $null }
    function Start-Process { $script:ConfigurationSideEffects++; throw 'unexpected elevated or proxy process' }
    $output=@(Invoke-Fix)
    Assert-Equal 1 $script:FixExitCode 'invalid config cannot start a repair'
    Assert-Equal 0 $script:ConfigurationSideEffects 'validation precedes all repair side effects'
    Assert-Match '配置' ($output -join '') 'user gets actionable configuration failure'
}

Add-CoreTest -Tag Configuration -Name 'checkdetail uses configured culture rather than fixed US culture' {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($script:CorePath,[ref]$tokens,[ref]$errors)
    $body=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CheckDetail'},$false).Extent.Text
    Assert-Match '\$cult\s+-eq\s+\$LOCALE_TARGET' $body 'culture check must follow validated user target'
}

Add-CoreTest -Tag MainSync -Name 'script updater refuses native configuration before contacting a release service' {
    New-TestWorkspace | Out-Null
    Write-CoreConfigurationFixture
    $script:UpdateProbeCalls=0
    function Get-ReleaseInfo { $script:UpdateProbeCalls++; @{status='latest';current='1.0.0';latest='1.0.0'} }
    $output=@(Invoke-UpdateNow)
    Assert-Equal 0 $script:UpdateProbeCalls 'script updates cannot replace native installation templates'
    Assert-Match 'STATUS=unsupported' ($output -join "`n") 'native updates must direct users to native installation guidance'
    Assert-Equal 1 $script:UpdateExitCode 'unsupported update is nonzero'
}

Add-CoreTest -Tag MainSync -Name 'script updater refuses invalid user configuration before network or file replacement' {
    New-TestWorkspace | Out-Null
    Write-CoreConfigurationFixture @{ country='CN' }
    $script:UpdateProbeCalls=0
    function Get-ReleaseInfo { $script:UpdateProbeCalls++; @{status='latest';current='1.0.0';latest='1.0.0'} }
    $output=@(Invoke-UpdateNow)
    Assert-Equal 0 $script:UpdateProbeCalls 'invalid configuration cannot enter the updater'
    Assert-Match 'STATUS=error' ($output -join "`n") 'invalid configuration is observable'
}

Add-CoreTest -Tag MainSync -Name 'script updater shares the account operation lock before probing releases' {
    New-TestWorkspace | Out-Null
    $script:UpdateProbeCalls=0
    function Get-ReleaseInfo { $script:UpdateProbeCalls++; @{status='latest';current='1.0.0';latest='1.0.0'} }
    $held=Enter-OperationLock
    try {
        $output=@(Invoke-UpdateNow)
        Assert-Equal 0 $script:UpdateProbeCalls 'busy core must block update before network or mutations'
        Assert-Match 'STATUS=busy' ($output -join "`n") 'busy updater state is observable'
        Assert-Equal 2 $script:UpdateExitCode 'contention returns the stable busy exit code'
    } finally { Exit-OperationLock $held }
}

Add-CoreTest -Tag MainSync -Name 'script updater preserves pending recovery material and releases its lock' {
    New-TestWorkspace | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:BASE 'transaction.json'), '{"unverified":true}')
    $script:UpdateProbeCalls=0
    function Get-ReleaseInfo { $script:UpdateProbeCalls++; @{status='latest';current='1.0.0';latest='1.0.0'} }
    $output=@(Invoke-UpdateNow)
    Assert-Equal 0 $script:UpdateProbeCalls 'pending recovery must block updates before release discovery'
    Assert-Match 'STATUS=recovery_required' ($output -join "`n") 'recovery refusal must be explicit'
    Assert-Equal '{"unverified":true}' ([IO.File]::ReadAllText((Join-Path $script:BASE 'transaction.json'))) 'updating must not perform account recovery'
    $available=Enter-OperationLock -WaitMilliseconds 0
    try { Assert-True ($null -ne $available) 'refused update must release its lock' }
    finally { Exit-OperationLock $available }
}

Add-CoreTest -Tag MainSync -Name 'merged rule repair reports its redacted failure through the strict protocol' {
    New-TestWorkspace | Out-Null
    function Invoke-FixCommand {
        param($OperationId)
        $script:CoreExitCode=1
        'FIX:规则 FAIL synthetic 203.0.113.7 token=synthetic-secret'
        'FIX:修复流程结束'
    }
    $result=Invoke-CoreRequest -Command fix -OperationId '3f6f37b4-7f19-4ca7-9eb1-7b99fbc7982f'
    Assert-False $result.success 'rule failure must never become a trusted success'
    Assert-Equal 'fix-failed' $result.code 'the stable failure code is preserved'
    Assert-Match '规则 FAIL' $result.message 'upstream rule diagnostics must survive the native protocol boundary'
    Assert-False ($result.message -match '203\.0\.113\.7|synthetic-secret') 'rule diagnostics must be redacted before reaching either UI'
}

Add-CoreTest -Tag MainSync -Name 'script updater revalidates installation kind after acquiring the operation lock' {
    New-TestWorkspace | Out-Null
    $script:UpdateProbeCalls=0
    function Get-ReleaseInfo { $script:UpdateProbeCalls++; @{status='latest';current='1.0.0';latest='1.0.0'} }
    function Enter-OperationLock {
        Write-CoreConfigurationFixture
        [IO.File]::Open((Join-Path $script:BASE 'operation.lock'),'OpenOrCreate','ReadWrite','None')
    }
    $output=@(Invoke-UpdateNow)
    Assert-Equal 0 $script:UpdateProbeCalls 'configuration created while waiting for the lock must prevent a script update'
    Assert-Match 'STATUS=unsupported' ($output -join "`n") 'installation kind must be revalidated under the lock'
}

Add-CoreTest -Tag MainSync -Name 'read-only update check directs native users to installation guidance' {
    New-TestWorkspace | Out-Null
    Write-CoreConfigurationFixture
    $script:UpdateProbeCalls=0
    function Get-ReleaseInfo { $script:UpdateProbeCalls++; @{status='update_available';current='1.0.0';latest='2.0.0'} }
    $output=@(Invoke-CheckUpdate)
    Assert-Equal 0 $script:UpdateProbeCalls 'native users must not be offered the legacy script updater'
    Assert-Match 'STATUS=unsupported' ($output -join "`n") 'native upgrade guidance is explicit'
    Assert-False ([IO.File]::Exists((Join-Path $script:BASE 'operation.lock'))) 'read-only update check must not acquire or create a lock'
}
