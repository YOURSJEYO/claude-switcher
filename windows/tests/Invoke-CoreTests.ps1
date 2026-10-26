[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

$script:CoreTests = @()
$script:TestFailures = 0
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-switch-core-tests-" + [guid]::NewGuid().Guid)
$script:CorePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'claude-switch.ps1'
$script:SavedEnvironment = @{
    USERPROFILE = $env:USERPROFILE
    APPDATA = $env:APPDATA
    LOCALAPPDATA = $env:LOCALAPPDATA
    TEMP = $env:TEMP
    TMP = $env:TMP
}

function Add-CoreTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $script:CoreTests += [pscustomobject]@{ Name = $Name; Body = $Body }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "ASSERT: $Message (expected=$Expected actual=$Actual)" }
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message)
    if ($Actual -notmatch $Pattern) { throw "ASSERT: $Message (pattern=$Pattern actual=$Actual)" }
}

function New-TestWorkspace {
    $root = Join-Path $script:TestRoot ([guid]::NewGuid().Guid)
    $userHome = Join-Path $root 'home'
    $appData = Join-Path $root 'appdata'
    $localAppData = Join-Path $root 'localappdata'
    New-Item -ItemType Directory -Force -Path $userHome, $appData, $localAppData | Out-Null
    $script:BASE = Join-Path $userHome '.claude-switcher'
    $script:DATA = Join-Path $appData 'Claude'
    $script:LOG = Join-Path $script:BASE 'claude-switch.log'
    $script:CLASH_DIR = Join-Path $appData 'synthetic-clash'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BASE 'accounts'), $script:DATA | Out-Null
    $script:SwitchExitCode = 0
    return $root
}

function New-CheckLines {
    param(
        [hashtable]$Overrides = @{},
        [string[]]$Skip = @()
    )
    $names = @(
        '代理内核', 'TUN网卡', '出口IP', 'IP一致', '时区', '地区', 'IPv6',
        'DNS', 'WebRTC', '保镖', '规则置顶', '客户端语言', 'ASN属性', '生态可达性'
    )
    foreach ($name in $names) {
        if ($Skip -contains $name) { continue }
        $state = if ($Overrides.ContainsKey($name)) { $Overrides[$name] } else { 'ok:test' }
        "$name=$state"
    }
}

New-Item -ItemType Directory -Force -Path $script:TestRoot | Out-Null
$env:USERPROFILE = Join-Path $script:TestRoot 'process-home'
$env:APPDATA = Join-Path $script:TestRoot 'process-appdata'
$env:LOCALAPPDATA = Join-Path $script:TestRoot 'process-localappdata'
$env:TEMP = Join-Path $script:TestRoot 'process-temp'
$env:TMP = $env:TEMP
New-Item -ItemType Directory -Force -Path $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP | Out-Null

try {
    . $script:CorePath *> $null
    . (Join-Path $PSScriptRoot 'ClaudeSwitch.Core.Tests.ps1')

    $script:CoreFunctions = @{}
    foreach ($name in @(
        'Invoke-CheckDetail', 'Invoke-Switch', 'Test-LaunchGate', 'Get-StunAssessment',
        'Get-StunPublicIP', 'Get-Egress', 'Stop-ClaudeApp', 'Save-Account', 'Start-ClaudeApp',
        'Get-TimeZone', 'Get-ScheduledTask', 'Test-ProxyAlive', 'Get-TunStatus', 'Test-WebRTC'
    )) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.CommandType -eq 'Function') {
            $script:CoreFunctions[$name] = $command.ScriptBlock
        }
    }

    foreach ($test in $script:CoreTests) {
        foreach ($name in $script:CoreFunctions.Keys) {
            Set-Item -Path "Function:\$name" -Value $script:CoreFunctions[$name]
        }
        $script:SwitchExitCode = 0
        try {
            . $test.Body
            Write-Host ("PASS {0}" -f $test.Name)
        } catch {
            $script:TestFailures++
            Write-Host ("FAIL {0}" -f $test.Name)
            Write-Host ("     {0}" -f $_.Exception.Message)
        }
    }

    $total = $script:CoreTests.Count
    $passed = $total - $script:TestFailures
    Write-Host ("RESULT total={0} passed={1} failed={2}" -f $total, $passed, $script:TestFailures)
    if ($script:TestFailures -gt 0) { exit 1 }
    exit 0
} finally {
    foreach ($name in $script:SavedEnvironment.Keys) {
        Set-Item -Path "Env:\$name" -Value $script:SavedEnvironment[$name] -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
