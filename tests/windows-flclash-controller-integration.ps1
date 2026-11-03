# 通过真实 PowerShell AST 提取生产函数；配置、进程与后台操作全部隔离打桩。
# powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-flclash-controller-integration.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'windows\claude-switch.ps1'
$ui = Join-Path $root 'windows\SwitcherUI.ps1'

function Import-Function([Management.Automation.Language.Ast]$Ast, [string]$Name) {
    $fn = $Ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if (-not $fn) { throw "找不到生产函数 $Name" }
    Set-Item -Path "function:script:$Name" -Value ([scriptblock]::Create($fn.Body.Extent.Text))
}
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "$Name : expected=[$Expected] actual=[$Actual]" }
    "PASS  $Name"
}

$parseErrors = $null
$coreAst = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }
foreach ($name in @('ConvertTo-LoopbackClashEndpoint','Get-FlClashApi','Get-ClashApi','Get-ClashMode')) {
    Import-Function $coreAst $name
}
$selector = $coreAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-FlClashClientSelected' }, $true)
if ($selector) { . ([scriptblock]::Create($selector.Extent.Text)) }

$script:override = ''
$script:flclashConfig = 'C:\isolated\com.follow\clash\config.yaml'
$script:flclashApi = $null
$script:yamlValues = @{}
function Get-FlClashControllerOverride { return $script:override }
function Get-FlClashConfigPath { return $script:flclashConfig }
function Get-YamlScalar([string]$Path, [string]$Key) {
    $fullKey = $Path + '|' + $Key
    if ($script:yamlValues.ContainsKey($fullKey)) { return $script:yamlValues[$fullKey] }
    return $null
}
function Get-FlClashListenCandidates { return @() }
function Join-Path([string]$Path, [string]$Child) { return $Path + '\' + $Child }
function Test-Path { return $true }
function Get-Content([string]$LiteralPath) {
    if ($LiteralPath -like '*com.follow*') { return @('mode: rule') }
    return @('mode: global')
}
function Invoke-ClashApi { return @{ ok = $false; data = $null } }
function Get-Process {
    [CmdletBinding()] param([string[]]$Name)
    if ($Name -contains 'FlClash' -or $Name -contains 'FlClashCore') { return [pscustomobject]@{ Id = 123 } }
    return $null
}

$script:override = '127.0.0.1:19090'
$script:yamlValues[$script:flclashConfig + '|secret'] = 'isolated-secret'
Assert-Equal (Get-FlClashConfigPath) $script:flclashConfig '隔离 config 路径桩'
Assert-Equal (Get-YamlScalar $script:flclashConfig 'secret') 'isolated-secret' '隔离 secret 桩'
$api = Get-FlClashApi
Assert-Equal $api.headers.Authorization 'Bearer isolated-secret' 'override 保留 FlClash config secret'
Assert-Equal $api.base 'http://127.0.0.1:19090' 'override 端口仍优先于 config'

function Get-FlClashApi { return $script:flclashApi }
$PROXY_MODE = 'flclash'
$CLASH_DIR = 'C:\stale-verge'
$script:flclashApi = $null
$script:yamlValues[$CLASH_DIR + '\clash-verge.yaml|external-controller'] = '127.0.0.1:7890'
Assert-Equal (Get-ClashApi) $null 'FlClash 发现失败不得回退 Verge API'
Assert-Equal (Get-ClashMode) 'rule' 'FlClash API 失败不得采用 Verge global'

$PROXY_MODE = 'auto'
$script:flclashApi = @{ base = 'http://127.0.0.1:19090'; headers = @{}; source = 'flclash-override' }
Assert-Equal (Get-ClashApi).source 'flclash-override' 'auto 按运行进程优先选择 FlClash'
Assert-Equal (Get-ClashMode) 'rule' 'auto 的 YAML 回退不得让旧 Verge 配置抢占 FlClash'

$uiParseErrors = $null
$uiAst = [Management.Automation.Language.Parser]::ParseFile($ui, [ref]$null, [ref]$uiParseErrors)
if ($uiParseErrors.Count) { throw $uiParseErrors[0].Message }
foreach ($name in @('Set-Busy','Apply-FlClashPort')) { Import-Function $uiAst $name }
$lostFocus = $uiAst.Find({ param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Member.Value -eq 'Add_LostFocus'
}, $true)
if (-not $lostFocus) { throw '找不到 FlClashPort LostFocus 生产处理器' }
$onLostFocus = [scriptblock]::Create($lostFocus.Arguments[0].Extent.Text)

$script:box = [pscustomobject]@{ Text = ''; IsEnabled = $true }
$win = [pscustomobject]@{}
$win | Add-Member -MemberType ScriptMethod -Name FindName -Value {
    param($name)
    if ($name -eq 'FlClashPort') { return $script:box }
    return [pscustomobject]@{ IsEnabled = $true }
}
$script:suppressPortEvent = $false
$script:portLoaded = $false
$script:isBusy = $false
$script:environmentReady = $false
$script:currentClient = 'flclash'
$script:updateRunning = $false
$script:savedFlClashPort = ''
$script:saveCalls = 0
function Start-CommandOperation {
    $script:saveCalls++
    Set-Busy $true
    if ($script:box.IsEnabled) { throw '保存期间端口框未禁用' }
    Set-Busy $false
}
Apply-FlClashPort 'port=127.0.0.1:9090'
& $onLostFocus
Assert-Equal $script:saveCalls 0 'LostFocus 值未变化时不保存'
$script:box.Text = '9091'
& $onLostFocus
Assert-Equal $script:saveCalls 1 'LostFocus 值变化时保存且保存期间禁用端口框'
'ALL PASS'
