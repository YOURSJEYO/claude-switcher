# Windows 切换流程的隔离集成测试
#
# 只用临时目录 + 打桩的进程/启动命令，不接触真实 Claude、账号快照、注册表、计划任务或网络。
# 在 Windows PowerShell 5.1 或 pwsh 7 下运行：
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-switch-integration.ps1
#
# 覆盖：首次收编 / 新建空槽位 / 往返切换的数据归属 / 暂存目录残留时拒绝覆盖。

$ErrorActionPreference = 'Stop'

$core = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\claude-switch.ps1'
if (-not (Test-Path -LiteralPath $core)) { throw "找不到核心脚本: $core" }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('cs-it-' + [guid]::NewGuid().ToString('N'))
$env:USERPROFILE = Join-Path $root 'user'
$env:APPDATA = Join-Path $root 'appdata'
$env:LOCALAPPDATA = Join-Path $root 'localappdata'
foreach ($d in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# 打桩：不碰真实进程、Appx 包，也不启动任何程序（CmdletBinding 让 -ErrorAction 等公共参数可用）
$script:appxPackage = $null
function global:Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name)
    return $script:appxPackage
}
function global:Get-Process {
    [CmdletBinding()]
    param([string[]]$Name)
    return @()
}
function global:Start-Process {
    [CmdletBinding()]
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$NoNewWindow)
    return $null
}
$script:failOldCleanup = $false
function global:Remove-Item {
    [CmdletBinding()]
    # -ErrorAction 由 [CmdletBinding()] 提供，param 里不能再声明一次（否则调用时报参数重复定义）
    param([string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    if ($script:failOldCleanup -and $LiteralPath -eq "$BASE\staging\Claude.old") { throw 'simulated locked recovery directory' }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}

$failures = 0
function Assert([string]$what, [bool]$condition, [string]$detail = '') {
    if ($condition) {
        "PASS  $what"
    } else {
        "FAIL  $what $detail"
        $script:failures++
    }
}
function Read-Text([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8).Trim()
}

$scriptErrorPreference = $ErrorActionPreference
try {
    # MSIX 数据目录发现的分支与旧版优先级；完成后恢复旧版路径执行通用切换回归
    $legacyData = Join-Path $env:APPDATA 'Claude'
    $msixData = Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_test_pfn'
    New-Item -ItemType Directory -Path $msixData -Force | Out-Null
    . $core *> $null
    $ErrorActionPreference = 'Stop'
    Assert '唯一 MSIX 数据目录回退发现' ($DATA -eq $msixData) "实际=$DATA"
    $script:appxPackage = [pscustomobject]@{ PackageFamilyName = 'Claude_test_pfn' }
    Assert 'Appx PackageFamilyName 主路径发现' ((Find-ClaudeDataPath) -eq $msixData)
    New-Item -ItemType Directory -Path $legacyData -Force | Out-Null
    Assert '旧版数据目录保持优先' ((Find-ClaudeDataPath) -eq $legacyData)
    Remove-Item -LiteralPath $legacyData -Recurse -Force
    $script:appxPackage = $null
    $secondMsixData = Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_other_pfn'
    New-Item -ItemType Directory -Path $secondMsixData -Force | Out-Null
    Assert '多个无包归属的 MSIX 目录不猜测' ((Find-ClaudeDataPath) -eq $legacyData)
    Remove-Item -LiteralPath $secondMsixData -Recurse -Force
    Remove-Item -LiteralPath $msixData -Recurse -Force
    $DATA = $legacyData

    $data = $DATA
    $base = $BASE
    $accounts = Join-Path $base 'accounts'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $data 'config.json') -Value 'A1' -Encoding UTF8 -NoNewline

    # 1. 首次收编：当前登录变成账号 A，且当前数据目录不被删除
    $null = Invoke-Switch 'A'
    Assert '首次收编写入 current=A' ((Read-Text "$base\current.txt") -eq 'A') "实际=$(Read-Text "$base\current.txt")"
    Assert '首次收编生成 A 快照' ((Read-Text "$accounts\A\config.json") -eq 'A1')
    Assert '首次收编保留当前数据' ((Read-Text "$data\config.json") -eq 'A1')

    # 2. 切到空槽位 B：A 重新归档为 A2，B 以全新状态初始化
    Set-Content -LiteralPath (Join-Path $data 'config.json') -Value 'A2' -Encoding UTF8 -NoNewline
    $null = Invoke-Switch 'B'
    Assert '切换后 current=B' ((Read-Text "$base\current.txt") -eq 'B')
    Assert 'A 快照更新为最新内容' ((Read-Text "$accounts\A\config.json") -eq 'A2')
    Assert '空槽位 B 初始化后无 A 的配置' (-not (Test-Path -LiteralPath "$data\config.json"))

    # 3. 在 B 里产生数据，再切回 A：两侧内容各归各
    Set-Content -LiteralPath (Join-Path $data 'config.json') -Value 'B1' -Encoding UTF8 -NoNewline
    $null = Invoke-Switch 'A'
    Assert '切回后 current=A' ((Read-Text "$base\current.txt") -eq 'A')
    Assert 'A 的数据被还原' ((Read-Text "$data\config.json") -eq 'A2')
    Assert 'B 的数据被归档' ((Read-Text "$accounts\B\config.json") -eq 'B1')

    # 4. 暂存残留：拒绝覆盖，当前数据与指针都不变
    New-Item -ItemType Directory -Path "$accounts\A.new" -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $accounts 'A.new\stale.txt') -Value 'stale' -Encoding UTF8
    $r = Invoke-Switch 'B'
    Assert '存在待恢复快照时返回 FAIL' (((@($r) -join "`n") -match '(?m)^FAIL:')) "输出=$r"
    Assert '拒绝覆盖时 current 不变' ((Read-Text "$base\current.txt") -eq 'A')
    Assert '拒绝覆盖时当前数据不变' ((Read-Text "$data\config.json") -eq 'A2')
    Remove-Item -LiteralPath "$accounts\A.new" -Recurse -Force

    # 5. 非法槽位
    $r = Invoke-Switch 'E'
    Assert '非法槽位返回 FAIL' (((@($r) -join "`n") -match '(?m)^FAIL:')) "输出=$r"

    # 6. 不留下暂存/回滚残留
    foreach ($leftover in @("$accounts\A.new", "$accounts\A.previous", "$accounts\B.new", "$accounts\B.previous", "$data.new", "$data.old")) {
        Assert "无残留 $leftover" (-not (Test-Path -LiteralPath $leftover))
    }

    # 7. C 槽位与跨身份保留：只合并显式列出的路径
    Set-Content -LiteralPath (Join-Path $data 'settings.json') -Value 'shared-A' -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $data 'private.txt') -Value 'account-A-only' -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $base 'keep-in-workspace.txt') -Value 'settings.json' -Encoding UTF8
    $null = Invoke-Switch 'C'
    Assert 'C 槽位切换后 current=C' ((Read-Text "$base\current.txt") -eq 'C')
    Assert 'keep 路径进入新账号' ((Read-Text "$data\settings.json") -eq 'shared-A')
    Assert '未列出的账号文件不进入新账号' (-not (Test-Path -LiteralPath "$data\private.txt"))
    Assert 'keep 路径仍归档在原账号' ((Read-Text "$accounts\A\settings.json") -eq 'shared-A')
    Assert 'keep 暂存成功后清理' (-not (Test-Path -LiteralPath "$base\keep-stage"))
    $status = (@(Invoke-Status) -join "`n")
    # 空槽位不落盘：切到 C 后 current=C，但 accounts\C 只有真正有数据时才出现
    Assert '状态包含 C/D 与账号列表' ($status -match 'hasC=0 hasD=0' -and $status -match 'accounts=A,B') "输出=$status"

    # 8. 清理失败：数据和指针仍提交到目标账号，归属明确的残留下次可清理
    $script:failOldCleanup = $true
    $r = Invoke-Switch 'B'
    Assert '旧目录清理失败仍提交 current=B' ((Read-Text "$base\current.txt") -eq 'B') "输出=$r"
    Assert '清理失败的旧目录被保留' (Test-Path -LiteralPath "$base\staging\Claude.old")
    Assert '清理失败有归属标记' (Test-Path -LiteralPath "$base\staging\cleanup.json")
    Assert '默认暂存不在 APPDATA 产生 Claude.new' (-not (Test-Path -LiteralPath "$data.new"))
    Assert '默认备份不在 APPDATA 产生 Claude.old' (-not (Test-Path -LiteralPath "$data.old"))
    $script:failOldCleanup = $false
    $null = Invoke-Switch 'A'
    Assert '下次切换先清理已确认归属的旧目录' (-not (Test-Path -LiteralPath "$base\staging\Claude.old"))
    Assert '归属标记清理后移除' (-not (Test-Path -LiteralPath "$base\staging\cleanup.json"))
    Assert '恢复后 current=A' ((Read-Text "$base\current.txt") -eq 'A')

    # 9. 没有归属证明的旧目录仍拒绝覆盖且不会自动删除
    New-Item -ItemType Directory -Path "$base\staging\Claude.old" -Force | Out-Null
    Set-Content -LiteralPath "$base\staging\Claude.old\only-copy.txt" -Value 'preserve' -Encoding UTF8
    $r = Invoke-Switch 'B'
    Assert '不明旧目录仍拒绝切换' (((@($r) -join "`n") -match '(?m)^FAIL:')) "输出=$r"
    Assert '不明旧目录内容不删除' ((Read-Text "$base\staging\Claude.old\only-copy.txt") -eq 'preserve')
    Assert '不明残留时 current 不变' ((Read-Text "$base\current.txt") -eq 'A')
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath "$base\staging\Claude.old" -Recurse -Force

    # 10. 设置界面的同步核心调用必须让 Windows PowerShell 5.1 收到完整 JSON
    $uiPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'windows\SwitcherUI.ps1'
    $uiText = Get-Content -LiteralPath $uiPath -Raw -Encoding UTF8
    foreach ($functionName in @('Quote-UiArgument','Invoke-Core')) {
        $match = [regex]::Match($uiText, "(?ms)^function $functionName.*?\n\}")
        Assert "提取界面函数 $functionName" $match.Success
        if ($match.Success) { Invoke-Expression $match.Value }
    }
    $settingsJson = '{"disabled":["DNS"],"allowOptionalFailures":false,"logging":true}'
    $saveOutput = Invoke-Core @('set-check-config', $settingsJson)
    Assert '同步调用保存 DNS 跳过设置' ($script:lastCoreExit -eq 0 -and $saveOutput -match '(?m)^OK:') "输出=$saveOutput"
    $savedConfig = Get-Content -LiteralPath "$base\checks.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert '保存结果包含 DNS 禁用项' (@($savedConfig.disabled) -contains 'DNS')
} finally {
    $ErrorActionPreference = $scriptErrorPreference
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    "FAILED: $failures 项"
    exit 1
}
'OK: 全部通过'
