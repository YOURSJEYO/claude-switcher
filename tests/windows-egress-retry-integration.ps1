# 隔离执行真实出口探测代码;外部请求全部打桩,不联网。
# powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-egress-retry-integration.ps1
#
# 锁住三件事:
# 1. 代理路径可能失效时,出口探测一个包都不发,立刻失败 —— 不在可能泄漏的路径上敲门;
# 2. 链路失败时 Get-Egress 降级成"未取到",不再抛异常中断整轮检查;
# 3. 路径在线时单次抖动会重试,不会把一次隧道内故障直接判成 fail。
$ErrorActionPreference = 'Stop'
$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }

# 抽取生产函数(含被测代码的全部依赖),不复制一份实现。
foreach ($name in @('Invoke-ProbeText', 'Invoke-ProbeCode', 'Test-ProxyPathAlive', 'Get-Egress', 'Test-CheckDisabled', 'Format-OptionalResult')) {
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $fn) { throw "找不到 $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

# 路径存活性由环境决定,这里打桩;组合逻辑(Test-ProxyPathAlive)用生产实现。
$script:pathAlive = $true
function Test-ProxyAlive { return $script:pathAlive }
function Test-TunUp { return $script:pathAlive }

# 从 Invoke-CheckDetail 里取出「出口IP」判定语句(赋值 + 紧随其后的 if)。
$detail = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CheckDetail' }, $true)
$statements = @($detail.Body.EndBlock.Statements)
$egressAt = -1
for ($i = 0; $i -lt $statements.Count; $i++) {
    $s = $statements[$i]
    if ($s -is [Management.Automation.Language.AssignmentStatementAst] -and
        $s.Left.Extent.Text -eq '$e' -and
        $s.Right.Extent.Text -match 'Get-Egress') { $egressAt = $i; break }
}
if ($egressAt -lt 0) { throw '找不到出口IP 探测语句' }
if ($statements[$egressAt + 1] -isnot [Management.Automation.Language.IfStatementAst]) { throw '出口IP 探测后不是判定语句' }
$egressCheck = [scriptblock]::Create($statements[$egressAt].Extent.Text + "`n" + $statements[$egressAt + 1].Extent.Text)

# 「生态可达性」判定语句。
$reachStatement = $statements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -eq "Test-CheckDisabled '生态可达性'"
} | Select-Object -First 1
if (-not $reachStatement) { throw '找不到生态可达性检查语句' }
$reachCheck = [scriptblock]::Create($reachStatement.Extent.Text)

$COUNTRY_TARGET = 'US'
$script:CheckConfig = @{ disabled = @(); allowOptionalFailures = $false }

# ---- curl 打桩 ----
$script:calls = 0
$script:failFirst = 0
$script:trace = @('fl=123abc', 'ip=198.51.100.24', 'loc=US', 'ts=1')
$script:codes = @{}
$script:perUrl = @{}
function curl.exe {
    $script:calls++
    $url = [string]$args[-1]
    if (-not $script:perUrl.ContainsKey($url)) { $script:perUrl[$url] = 0 }
    $script:perUrl[$url]++
    if ($script:calls -le $script:failFirst) { return @() }
    if ($url -like '*/cdn-cgi/trace') { return $script:trace }
    if ($script:codes.ContainsKey($url)) { return $script:codes[$url] }
    throw "未打桩的请求: $url"
}
function Reset([int]$fail = 0) {
    $script:calls = 0
    $script:failFirst = $fail
    $script:trace = @('fl=123abc', 'ip=198.51.100.24', 'loc=US', 'ts=1')
    $script:codes = @{}
    $script:perUrl = @{}
}
function Assert-Like([string]$name, [string]$expected, $actual) {
    $text = (@($actual) -join ' | ')
    if ($text -notmatch $expected) { throw "$name : 实际[$text] 不匹配 $expected" }
    "PASS  $name"
}
function Assert-Equal([string]$name, $expected, $actual) {
    if ($actual -ne $expected) { throw "$name : 实际[$actual] 期望[$expected]" }
    "PASS  $name"
}

# ---- 1. 路径可能失效时不发任何探测请求 ----
$script:pathAlive = $false
Reset 0
$e = Get-Egress
Assert-Equal '路径失效时不发起任何请求' 0 $script:calls
Assert-Equal '路径失效时标记为已跳过' $true $e.skipped
Assert-Equal '路径失效时不返回出口 IP' '' $e.ip

$actual = @(& $egressCheck)
Assert-Like '路径失效时出口IP 立刻失败' '^出口IP=fail:代理路径失效,已跳过探测' ($actual -join ' | ')
Assert-Equal '路径失效时检查本身不发起请求' 0 $script:calls

Reset 0
$actual = @(& $reachCheck)
Assert-Like '路径失效时生态可达性跳过探测' '^生态可达性=fail:代理路径失效,已跳过探测' ($actual -join ' | ')
Assert-Equal '路径失效时生态可达性不发请求' 0 $script:calls

# ---- 2. 路径在线:降级与重试 ----
$script:pathAlive = $true
Reset 99
$e = Get-Egress
Assert-Like '链路完全失败时降级为空而不是抛异常' '^$' "$($e.ip)$($e.loc)"
Assert-Equal '链路完全失败时探测次数' 3 $script:calls

Reset 1
$e = Get-Egress
Assert-Equal '抖动后重试能取到出口 IP' '198.51.100.24' $e.ip
Assert-Equal '抖动后重试能取到出口地区' 'US' $e.loc
Assert-Equal '抖动后只需第二次' 2 $script:calls

Reset 0
$e = Get-Egress
Assert-Equal '一次成功时不重试' 1 $script:calls

Reset 0
$script:trace = @('ip=198.51.100.24')
$e = Get-Egress
Assert-Equal '响应缺少地区时不算有效答案' 3 $script:calls
Assert-Equal '响应缺少地区时 IP 仍可读出' '198.51.100.24' $e.ip
Assert-Equal '响应缺少地区时地区为空' '' $e.loc

# ---- 3. 出口IP 检查行不再中断 ----
Reset 99
$actual = @(& $egressCheck)
Assert-Like '链路失败时输出 fail 行而不是抛异常' '^出口IP=fail:' ($actual -join ' | ')

Reset 0
$actual = @(& $egressCheck)
Assert-Like '链路正常时输出 ok 行' '^出口IP=ok:198\.51\.100\.24$' ($actual -join ' | ')

# ---- 4. 生态可达性 重试 ----
Reset 0
$script:codes = @{
    'https://claude.ai/'                 = @('403')
    'https://api.anthropic.com/v1/models' = @('401')
}
$actual = @(& $reachCheck)
Assert-Like '两个站点都可达时通过' '^生态可达性=ok:claude\.ai:403 api:401$' ($actual -join ' | ')
Assert-Equal '可达时每个站点只探测一次' 1 $script:perUrl['https://claude.ai/']
Assert-Equal '可达时 API 只探测一次' 1 $script:perUrl['https://api.anthropic.com/v1/models']

Reset 0
$script:codes = @{
    'https://claude.ai/'                 = @('403')
    'https://api.anthropic.com/v1/models' = @('000')
}
$actual = @(& $reachCheck)
Assert-Like '单站不可达时判失败' '^生态可达性=fail:claude\.ai:403 api:000$' ($actual -join ' | ')
Assert-Equal '不可达时重试三次' 3 $script:perUrl['https://api.anthropic.com/v1/models']
Assert-Equal '可达站点不受影响' 1 $script:perUrl['https://claude.ai/']

# ---- 5. 杀进程层不做任何网络探测,也没有重试 ----
$guard = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-bodyguard.ps1'
$guardText = [IO.File]::ReadAllText($guard)
if ($guardText -match 'curl|Invoke-WebRequest|Invoke-RestMethod|Start-Sleep -Milliseconds') {
    throw '保镖不应发起网络探测或做重试退避'
}
if ($guardText -notmatch 'Stop-Process -Force') {
    throw '保镖失去杀进程能力'
}
'PASS  杀进程层不探测不重试,保持立刻急停'

'ALL PASS'
