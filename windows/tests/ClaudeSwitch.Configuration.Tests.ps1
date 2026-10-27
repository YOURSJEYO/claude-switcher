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
