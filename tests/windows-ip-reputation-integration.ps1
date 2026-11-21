# 隔离回归:IP 信誉四联检(可插拔数据源)
#
# 锁住的语义:
#   1. 未配置信誉数据源 -> 四项都是 warn(不是 fail,也不是 ok)
#   2. 已配置 + 干净返回 -> 四个维度判定正确
#   3. 已配置 + 脏返回 -> 对应维度 fail,机房维度只 warn
#   4. 数据源缺字段 -> 该项 warn(缺字段不等于「没有风险」)
#   5. 数据源不可达 -> 四项 warn(探测失败不该把检查判红)
#   6. 禁用某一项 -> 该项 skip
#   7. allowOptionalFailures -> fail 降为 warn
#   8. 缓存按「接口+IP」记账,换接口不会读到上一个接口的旧结论
#   9. checks.json 的 ipReputation 往返不被其它设置覆盖掉
#  10. 配置校验:未知字段、越界阈值、越界缓存天数、非 HTTPS 接口都要拒绝
#  11. get-check-config 不回显密钥
#  12. 命中缓存时不再请求数据源,判定与首次一致(盯缓存读回后的对象形状)
#  13. 阈值与缓存天数经 JSON 往返后仍是数字(PS 5.1 给 Int32、PS 7 给 Int64)
#  14. 布尔/字符串形式的阈值与缓存天数被拒绝
#
# 手法沿用 tests\windows-egress-retry-integration.ps1:
# 从生产脚本里按 AST 抽出函数原样 dot-source(不复制一份实现),
# 用同名 PowerShell 函数覆盖 curl.exe,不真的去请求第三方。
#
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-ip-reputation-integration.ps1
$ErrorActionPreference = 'Stop'

$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }

# 抽取生产函数(含被测代码的全部依赖),不复制一份实现。
foreach ($name in @('Get-CheckItemNames','ConvertTo-CheckConfig','Get-CheckConfig','Set-CheckConfigFromJson',
        'Test-CheckDisabled','Format-OptionalResult','Invoke-ProbeText','Test-IpReputationNumber',
        'Get-IpReputationCache','Read-IpReputationCache','Write-IpReputationCache',
        'ConvertFrom-IpReputationPayload','Invoke-IpReputationLookup','Get-IpReputation','Get-IpReputationConfig',
        'Test-ProxyPathAlive')) {
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $fn) { throw "找不到 $name" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$script:Failures = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Output "  OK   $Message" }
    else { Write-Output "  FAIL $Message"; $script:Failures++ }
}
function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    Assert-True ($Text -match $Pattern) $Message
}

# 隔离目录:不碰真实安装态,不读真实 checks.json。
$isolated = Join-Path ([System.IO.Path]::GetTempPath()) ('cs-rep-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $isolated '.claude-switcher') | Out-Null
$BASE = Join-Path $isolated '.claude-switcher'
$CHECK_CONFIG = Join-Path $BASE 'checks.json'
$origProfile = $env:USERPROFILE
$env:USERPROFILE = $isolated

try {
    # ---- curl 打桩 ----
    # 覆盖 curl.exe:PowerShell 函数优先于同名可执行文件。
    # 按 URL 里的标记返回不同内容,覆盖干净/脏/缺字段/不可达四种情况。
    function curl.exe {
        $url = [string]$args[-1]
        $script:probeCalls += $url
        $script:lastCurlArgs = @($args)
        $script:lastCurlStdin = (@($input) -join "`n")
        if ($url -like '*stub-ok*') {
            return @('{"fraud_score":5,"risk_level":"low","is_proxy":false,"is_vpn":false,"is_tor":false,"is_datacenter":false,"blacklist_count":0}')
        }
        if ($url -like '*stub-dirty*') {
            return @('{"fraud_score":92,"risk_level":"high","is_proxy":true,"is_vpn":true,"is_tor":false,"is_datacenter":true,"blacklist_count":3}')
        }
        if ($url -like '*stub-partial*') {
            return @('{"fraud_score":5}')
        }
        if ($url -like '*stub-unreachable*') {
            return @()
        }
        throw "未打桩的请求: $url"
    }

    # 代理路径存活性由环境决定,这里打桩;组合逻辑用生产实现。
    $script:pathAlive = $true
    $script:probeCalls = @()
    function Test-ProxyAlive { return $script:pathAlive }
    function Test-TunUp { return $script:pathAlive }

    # 从 Invoke-CheckDetail 里取出信誉四联检那段单独执行,
    # 避免整轮检查里的网络探测拖慢测试。
    # 注意:那段是两条语句 —— 先给 $ipRepCfg 赋值,再进 if/elseif/else。
    # 只抽 if 的话 $ipRepCfg 在片段里永远是 null,会一直走「未配置」分支,
    # 测出来的是假绿灯。所以两条一起抽。
    $detail = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CheckDetail' }, $true)
    $statements = @($detail.Body.EndBlock.Statements)
    $assignAt = -1
    for ($i = 0; $i -lt $statements.Count; $i++) {
        if ($statements[$i].Extent.Text -match '\$ipRepCfg\s*=') { $assignAt = $i; break }
    }
    if ($assignAt -lt 0) { throw '找不到 IP 信誉四联检的配置赋值语句' }
    $repStatement = $statements[$assignAt + 1]
    if (-not $repStatement -or $repStatement.Extent.Text -notmatch 'IP纯净度') { throw '找不到 IP 信誉四联检语句' }
    $repCheck = [scriptblock]::Create($statements[$assignAt].Extent.Text + "`n" + $repStatement.Extent.Text)

    # 出口 IP 上下文:信誉探测问的是这个地址。
    $e = @{ ip = '198.51.100.24'; loc = 'US'; skipped = $false }

    function Set-ReputationConfig([string]$Url, [int]$Threshold = 25, [string[]]$Disabled = @(), [bool]$AllowFail = $false) {
        $script:CheckConfig = ConvertTo-CheckConfig ([pscustomobject]@{
                disabled = @($Disabled)
                allowOptionalFailures = $AllowFail
                logging = $false
                ipReputation = [pscustomobject]@{ url = $Url; key = ''; threshold = $Threshold; cacheDays = 7 }
            })
    }

    # ---- 1. 未配置 ----
    Write-Output 'case 1: 未配置信誉数据源'
    $script:CheckConfig = ConvertTo-CheckConfig ([pscustomobject]@{ disabled = @(); allowOptionalFailures = $false; logging = $false })
    $actual = @(& $repCheck) -join "`n"
    foreach ($n in @('IP纯净度', 'IP代理标记', 'IP机房属性', 'IP黑名单')) {
        Assert-Match $actual ("(?m)^" + $n + "=warn:") "$n 应为 warn(未配置)"
    }
    Assert-Match $actual '(?m)^IP纯净度=warn:未配置信誉数据源' '应说明是未配置'

    # ---- 2. 干净返回 ----
    Write-Output 'case 2: 已配置 + 干净返回'
    Set-ReputationConfig 'https://stub-ok.example/ip'
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=ok:' 'IP纯净度 应为 ok'
    Assert-Match $actual '(?m)^IP代理标记=ok:' 'IP代理标记 应为 ok'
    Assert-Match $actual '(?m)^IP机房属性=ok:' 'IP机房属性 应为 ok'
    Assert-Match $actual '(?m)^IP黑名单=ok:' 'IP黑名单 应为 ok'

    # ---- 3. 脏返回 ----
    Write-Output 'case 3: 已配置 + 脏返回'
    Set-ReputationConfig 'https://stub-dirty.example/ip'
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=fail:' 'IP纯净度 应为 fail(分数超阈值)'
    Assert-Match $actual '(?m)^IP代理标记=fail:' 'IP代理标记 应为 fail'
    Assert-Match $actual '(?m)^IP机房属性=warn:' 'IP机房属性 应为 warn(机房不等于脏)'
    Assert-Match $actual '(?m)^IP黑名单=fail:' 'IP黑名单 应为 fail'

    # ---- 4. 缺字段 ----
    Write-Output 'case 4: 数据源缺字段'
    Set-ReputationConfig 'https://stub-partial.example/ip'
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP代理标记=warn:' '缺字段的 IP代理标记 应为 warn(缺字段≠没有风险)'
    Assert-Match $actual '(?m)^IP黑名单=warn:' '缺字段的 IP黑名单 应为 warn'
    Assert-Match $actual '(?m)^IP机房属性=warn:' '缺字段的 IP机房属性 应为 warn'

    # ---- 5. 数据源不可达 ----
    Write-Output 'case 5: 数据源不可达'
    Set-ReputationConfig 'https://stub-unreachable.example/ip'
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=warn:' '探测失败应为 warn'
    Assert-Match $actual '(?m)^IP黑名单=warn:' '探测失败应为 warn'

    # ---- 6. 禁用其中一项 ----
    Write-Output 'case 6: 禁用 IP代理标记'
    Set-ReputationConfig 'https://stub-dirty2.example/ip' 25 @('IP代理标记')
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP代理标记=skip:' '禁用的项应为 skip'
    Assert-Match $actual '(?m)^IP纯净度=fail:' '禁用一项不影响其它项'

    # ---- 7. allowOptionalFailures 降级 ----
    Write-Output 'case 7: allowOptionalFailures 把 fail 降为 warn'
    Set-ReputationConfig 'https://stub-dirty3.example/ip' 25 @() $true
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=warn:非关键失败已忽略' 'allowOptionalFailures 应降级为 warn'
    Assert-True ($actual -notmatch '(?m)^IP纯净度=fail:') '降级后不应再有 fail'

    # ---- 8. 缓存按「接口+IP」记账 ----
    Write-Output 'case 8: 缓存键含接口地址'
    $cache = Read-IpReputationCache
    Assert-True ($cache.ContainsKey('https://stub-ok.example/ip|198.51.100.24')) '干净接口的缓存应存在'
    Assert-True (-not $cache.ContainsKey('198.51.100.24')) '缓存键不应是裸 IP'

    # ---- 9. 配置往返 ----
    Write-Output 'case 9: 保存其它设置时保留 ipReputation'
    Set-CheckConfigFromJson ('{"disabled":["WebRTC"],"allowOptionalFailures":false,"logging":true,' +
        '"ipReputation":{"url":"https://stub-ok.example/ip","key":"secret-key","threshold":40,"cacheDays":3}}')
    $saved = Get-Content -LiteralPath $CHECK_CONFIG -Raw | ConvertFrom-Json
    Assert-True ($null -ne $saved.ipReputation) '保存后 ipReputation 不应丢失'
    Assert-True ([string]$saved.ipReputation.url -eq 'https://stub-ok.example/ip') 'url 应保留'
    Assert-True ([string]$saved.ipReputation.key -eq 'secret-key') 'key 应保留'
    Assert-True ([int]$saved.ipReputation.threshold -eq 40) 'threshold 应保留'
    Assert-True ([int]$saved.ipReputation.cacheDays -eq 3) 'cacheDays 应保留'
    Assert-True (@($saved.disabled) -contains 'WebRTC') 'disabled 应保留'

    # ---- 10. 配置校验 ----
    Write-Output 'case 10: 配置校验'
    $bad = 0
    try { Set-CheckConfigFromJson '{"ipReputation":{"bogus":1}}' } catch { $bad++ }
    try { Set-CheckConfigFromJson '{"ipReputation":{"threshold":999}}' } catch { $bad++ }
    try { Set-CheckConfigFromJson '{"ipReputation":{"cacheDays":0}}' } catch { $bad++ }
    try { Set-CheckConfigFromJson '{"ipReputation":{"url":"http://plain.example/ip"}}' } catch { $bad++ }
    Assert-True ($bad -eq 4) '未知字段/越界阈值/越界缓存天数/非 HTTPS 接口都应被拒绝'

    # ---- 11. get-check-config 不回显密钥 ----
    Write-Output 'case 11: get-check-config 不回显密钥'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $core get-check-config 2>$null | Out-String
    Assert-True ($out -notmatch 'secret-key') '密钥不应出现在 get-check-config 输出里'
    Assert-True ($out -match '"configured"') '应告知界面是否已配置'

    # ---- 12. 命中缓存 ----
    # 第二次检查命中缓存、根本不发请求,判定必须和第一次完全一致。
    # 这条回归盯的是缓存读回后的对象形状:ConvertFrom-Json 的产物是 PSCustomObject,
    # 而判定代码按 hashtable 的 ContainsKey 取字段 —— 形状不对就在这里炸。
    Write-Output 'case 12: 命中缓存时不再请求数据源,判定不变'
    Set-ReputationConfig 'https://stub-ok-cache.example/ip'
    $script:probeCalls = @()
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=ok:' '首次查询应判定为 ok'
    Assert-True ($script:probeCalls.Count -eq 1) '首次查询应只请求一次数据源'
    $script:probeCalls = @()
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=ok:' '命中缓存后判定应不变'
    Assert-Match $actual '(?m)^IP代理标记=ok:' '命中缓存后代理标记也应不变'
    Assert-True ($script:probeCalls.Count -eq 0) '命中缓存时不应再请求数据源'

    # ---- 13. 数字字段经 JSON 往返 ----
    # 阈值与缓存天数写进 checks.json 再读回来,必须仍是数字。
    # PowerShell 5.1 的 ConvertFrom-Json 把整数解成 Int32,PowerShell 7 解成 Int64 ——
    # 校验只认一种类型,就会在另一个 shell 上把合法配置判成「不是数字」。
    Write-Output 'case 13: 阈值与缓存天数经 JSON 往返后仍合法'
    $numericOk = 0
    try {
        Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-ok.example/ip","threshold":40,"cacheDays":3}}'
        $numericOk++
        $round = Get-CheckConfig
        if ([double]$round.ipReputation.threshold -eq 40) { $numericOk++ }
        if ([int]$round.ipReputation.cacheDays -eq 3) { $numericOk++ }
    } catch { }
    Assert-True ($numericOk -eq 3) '阈值与缓存天数经 JSON 往返后应仍是数字'

    # ---- 14. 非数字的阈值要被拒绝 ----
    Write-Output 'case 14: 布尔与字符串阈值被拒绝'
    $badNum = 0
    try { Set-CheckConfigFromJson '{"ipReputation":{"threshold":true}}' } catch { $badNum++ }
    try { Set-CheckConfigFromJson '{"ipReputation":{"threshold":"25"}}' } catch { $badNum++ }
    try { Set-CheckConfigFromJson '{"ipReputation":{"cacheDays":"7"}}' } catch { $badNum++ }
    Assert-True ($badNum -eq 3) '布尔/字符串形式的阈值与缓存天数都应被拒绝'

    # ---- 15. 四项全部禁用时绝不发外部请求 ----
    Write-Output 'case 15: 四项全禁用不发网络请求'
    Set-ReputationConfig 'https://stub-all-disabled.example/ip' 25 @('IP纯净度','IP代理标记','IP机房属性','IP黑名单')
    $script:probeCalls = @()
    $actual = @(& $repCheck) -join "`n"
    Assert-True ($script:probeCalls.Count -eq 0) '四项全禁用时不应发起任何外部请求'
    foreach ($n in @('IP纯净度','IP代理标记','IP机房属性','IP黑名单')) {
        Assert-Match $actual ("(?m)^" + $n + "=skip:") "$n 全禁用时应输出 skip"
    }

    # ---- 16. UI 保存省略 key 时保留同 URL 既有密钥，换 URL 或显式空串清空，拒绝控制字符 ----
    Write-Output 'case 16: 密钥保留、更换 URL 隔离与控制字符拒绝'
    Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-ok.example/ip","key":"keep-me-123","threshold":25,"cacheDays":7}}'
    Set-CheckConfigFromJson '{"disabled":["DNS"],"ipReputation":{"url":"https://stub-ok.example/ip","threshold":30,"cacheDays":7}}'
    $kept = Get-CheckConfig
    Assert-True ([string]$kept.ipReputation.key -eq 'keep-me-123') '同 URL 省略 key 保存应保留既有密钥'
    Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-other.example/ip","threshold":30,"cacheDays":7}}'
    $switched = Get-CheckConfig
    Assert-True ([string]$switched.ipReputation.key -eq '') '更换 URL 时不应把旧接口密钥带给新接口'
    Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-ok.example/ip","key":"to-clear","threshold":25,"cacheDays":7}}'
    Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-ok.example/ip","key":"","threshold":25,"cacheDays":7}}'
    $cleared = Get-CheckConfig
    Assert-True ([string]$cleared.ipReputation.key -eq '') '显式传空串 key 应清空密钥'
    $badCtrl = 0
    try { Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-ok.example/ip","key":"bad\r\nX-Evil: 1"}}' } catch { $badCtrl++ }
    try { Set-CheckConfigFromJson '{"ipReputation":{"url":"https://stub-ok.example/ip bad"}}' } catch { $badCtrl++ }
    Assert-True ($badCtrl -eq 2) '含控制字符的 key 和含空白的 url 均应被拒绝'

    # ---- 17. risk_level 等级文本与密钥经 stdin (-K -) 传递 ----
    Write-Output 'case 17: 文本等级解析与密钥不进命令行'
    $script:CheckConfig = ConvertTo-CheckConfig ([pscustomobject]@{
        disabled = @()
        allowOptionalFailures = $false
        logging = $false
        ipReputation = [pscustomobject]@{ url = 'https://stub-ok-keytest.example/ip'; key = 'header-secret-99'; threshold = 25; cacheDays = 7 }
    })
    $script:lastCurlArgs = @()
    $script:lastCurlStdin = ''
    $actual = @(& $repCheck) -join "`n"
    Assert-Match $actual '(?m)^IP纯净度=ok:风险分 5 · low$' '应保留风险等级文本 low'
    Assert-True (($script:lastCurlArgs -join ' ') -notmatch 'header-secret-99') '密钥不应出现在 curl 命令行参数中'
    Assert-True ($script:lastCurlArgs -contains '-K') '带密钥请求应使用 curl -K -'
    Assert-Match $script:lastCurlStdin 'header = "X-API-Key: header-secret-99"' '密钥应经 stdin 传递给 curl -K -'
} finally {
    $env:USERPROFILE = $origProfile
    try { Remove-Item -LiteralPath $isolated -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:Failures -gt 0) {
    Write-Output "FAILED: $script:Failures 项断言未通过"
    exit 1
}
Write-Output 'ALL PASS'
exit 0
