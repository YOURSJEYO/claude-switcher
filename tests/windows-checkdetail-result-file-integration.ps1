# 隔离验证:checkdetail 异常中断时,last-check.txt 不得残留上一轮的结果。
# powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-checkdetail-result-file-integration.ps1
#
# 背景:界面的逐项颜色读 last-check.txt,整体结论读进程退出码。
# 检查中断时若文件里还留着上一轮的结果,界面就会显示「逐项全绿、整体红」。
$ErrorActionPreference = 'Stop'
$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($core, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0].Message }

$testHome = Join-Path $env:TEMP ('cs-checkdetail-' + [guid]::NewGuid().Guid)
$baseDir = Join-Path $testHome '.claude-switcher'
New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
try {
    # 预置一份「上一轮全绿」的旧结果
    $stale = @(
        '代理内核=ok', 'TUN网卡=ok', '出口IP=ok', 'IP一致=ok', '时区=ok', '地区=ok', 'IPv6=ok',
        'DNS=ok', 'WebRTC=skip', '保镖=ok', '规则置顶=ok', '客户端语言=ok', 'ASN属性=warn', '生态可达性=skip'
    )
    [IO.File]::WriteAllLines((Join-Path $baseDir 'last-check.txt'), $stale, (New-Object Text.UTF8Encoding($false)))

    # 复制生产脚本并注入故障:检查过程一开始就崩(只改第一处)
    $text = [IO.File]::ReadAllText($core, [Text.Encoding]::UTF8)
    $anchor = '    $e = Get-Egress'
    $idx = $text.IndexOf($anchor)
    if ($idx -lt 0) { throw '找不到注入点' }
    $text = $text.Substring(0, $idx) + "    throw 'simulated check failure'`n" + $text.Substring($idx)
    $copy = Join-Path $testHome 'claude-switch.ps1'
    [IO.File]::WriteAllText($copy, $text, (New-Object Text.UTF8Encoding($true)))

    $oldHome = $env:USERPROFILE
    $oldEap = $ErrorActionPreference
    $env:USERPROFILE = $testHome
    $ErrorActionPreference = 'Continue'
    try {
        # 注入的故障会让子进程往 stderr 写错误。PS 5.1 下 native stderr 会被升成
        # error record,在 Stop 策略下直接终止本脚本 —— 调用期间降级为 Continue 并
        # 把 stderr 写到文件里。
        $errFile = Join-Path $testHome 'stderr.txt'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $copy checkdetail 2> $errFile | Out-Null
        $exit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
        $env:USERPROFILE = $oldHome
    }

    if ($exit -eq 0) { throw "注入故障后 checkdetail 应当失败退出,实际 exit=$exit" }
    $file = Join-Path $baseDir 'last-check.txt'
    $after = if (Test-Path $file) { @(Get-Content $file -Encoding UTF8) } else { @() }
    $leaked = @($after | Where-Object { $_ -match '=(ok|skip|warn)' })
    if ($leaked.Count) { throw "检查中断后 last-check.txt 仍残留上一轮结果: $($leaked -join ' | ')" }
    'PASS  检查中断后不残留上一轮结果'
} finally {
    Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue
}
'ALL PASS'
