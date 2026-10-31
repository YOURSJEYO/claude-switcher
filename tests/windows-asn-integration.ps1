# 隔离执行真实 ASN 检查语句；只读取仓库源码，外部查询全部打桩。
# powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-asn-integration.ps1
$ErrorActionPreference = 'Stop'
$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }
foreach ($name in @('Test-CheckDisabled', 'Format-OptionalResult')) {
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}
$detail = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CheckDetail' }, $true)
$statement = $detail.Body.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq "Test-CheckDisabled 'ASN属性'"
}
if (-not $statement) { throw '找不到生产 ASN 检查语句' }
$check = [scriptblock]::Create($statement.Extent.Text)
$e = @{ ip = '198.51.100.24' }
$ipInfoUrl = 'https://ipinfo.io/198.51.100.24/json'
$networkUrl = 'https://www.peeringdb.com/api/net?asn=64512&fields=asn,info_type'
$script:CheckConfig = @{ disabled = @(); allowOptionalFailures = $false }
$script:ipInfoJson = '{"ip":"198.51.100.24","org":"AS64512 Example Metro"}'
$script:networkJson = '{"data":[{"asn":64512,"info_type":"Cable/DSL/ISP"}]}'
$script:throwRequest = ''
$script:calls = @()
function curl.exe {
    $url = [string]$args[-1]
    $script:calls += $url
    if ($url -eq $script:throwRequest) { throw 'simulated request failure' }
    if ($url -eq $ipInfoUrl) { return $script:ipInfoJson }
    if ($url -eq $networkUrl) { return $script:networkJson }
    throw "未打桩的请求: $url"
}
function Assert([string]$name, [string]$expected) {
    $actual = @(& $check)
    if ($actual.Count -ne 1 -or $actual[0] -notmatch $expected) { throw "$name : $actual" }
    "PASS  $name"
}

Assert '短名单以外的 ISP 按结构化类型通过，住宅用途仍未验证' '^ASN属性=ok:ISP\(AS64512 Example Metro\);具体 IP 的住宅属性未验证$'
if ($script:calls.Count -ne 2 -or $script:calls[0] -ne $ipInfoUrl -or $script:calls[1] -ne $networkUrl) { throw '查询未绑定已检测出口 IP 和 ASN' }
$script:networkJson = '{"data":[{"asn":64512,"info_type":"Content"}]}'
Assert '其他网络类型报告实际类型，不推断单个 IP 用途' '^ASN属性=warn:Content\(AS64512 Example Metro\);不代表具体 IP 用途$'
$script:networkJson = '{"data":[{"asn":64513,"info_type":"Cable/DSL/ISP"}]}'
Assert '其他 ASN 的 ISP 记录不能作为通过依据' '^ASN属性=warn:网络类型未确认'
$script:networkJson = '{"data":[]}'
Assert '没有网络记录时报告未确认' '^ASN属性=warn:网络类型未确认'
$script:networkJson = '{"data":[{"asn":64512}]}'
Assert '缺失网络类型时报告未确认' '^ASN属性=warn:网络类型未确认'
$script:networkJson = '{'
Assert '网络类型响应损坏时报告未确认' '^ASN属性=warn:网络类型未确认'
$script:throwRequest = $networkUrl
Assert '网络类型查询失败时报告未确认' '^ASN属性=warn:网络类型未确认'
$script:throwRequest = $ipInfoUrl
Assert 'IP 查询失败时报告未获取' '^ASN属性=warn:未获取$'
$script:throwRequest = ''
$script:ipInfoJson = '{'
Assert 'IP 响应损坏时报告未获取' '^ASN属性=warn:未获取$'
$script:ipInfoJson = '{"ip":"198.51.100.25","org":"AS64512 Example Metro"}'
Assert '其他 IP 的响应不能作为通过依据' '^ASN属性=warn:未获取$'
$script:ipInfoJson = '{"ip":"198.51.100.24","org":"Example Metro"}'
Assert '没有 ASN 时不推断运营商类型' '^ASN属性=warn:网络类型未确认'
$e.ip = ''
$script:calls = @()
Assert '没有出口 IP 时不查询' '^ASN属性=warn:未获取$'
if ($script:calls.Count) { throw '没有出口时触发查询' }
$e.ip = '198.51.100.24'
$script:CheckConfig.disabled = @('ASN属性')
Assert '禁用检查显示 skip' '^ASN属性=skip:用户已禁用$'
if ($script:calls.Count) { throw '禁用检查仍触发查询' }
'ALL PASS'
