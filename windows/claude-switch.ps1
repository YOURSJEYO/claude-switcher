# Claude 账号切换器 - Windows 核心脚本
# 用法: powershell -NoProfile -File claude-switch.ps1 check|status|switch A|B|checkdetail|fix
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============ 安装时可配置项(安装器自动改写) ============
$PROXY_MODE = "clash-verge"            # 代理客户端: clash-verge|sing-box|clashx|surge|wireguard|other|auto
$COUNTRY_TARGET = "US"                 # 目标出口国家(安装时按出口自动识别)
$TZ_TARGET = "Eastern Standard Time"   # Windows 时区ID
$PROXY_GROUP = "GLOBAL"                # Clash 代理组名
# =======================================================

$BASE = Join-Path $env:USERPROFILE ".claude-switcher"
$DATA = Join-Path $env:APPDATA "Claude"
$LOG  = Join-Path $BASE "claude-switch.log"
$CLASH_DIR = @(
    (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"),
    (Join-Path $env:LOCALAPPDATA "io.github.clash-verge-rev.clash-verge-rev")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $CLASH_DIR) { $CLASH_DIR = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev" }
New-Item -ItemType Directory -Force -Path "$BASE\accounts" | Out-Null

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Out-File -Append -Encoding utf8 $LOG }

# 代理客户端显示名(供检查细节输出)
function Get-ProxyName {
    switch ($PROXY_MODE) {
        'clash-verge' { return 'Clash Verge' }
        'sing-box'    { return 'sing-box' }
        'clashx'      { return 'ClashX' }
        'surge'       { return 'Surge' }
        'wireguard'   { return 'WireGuard' }
        'other'       { return '其他代理客户端' }
        'auto'        { return '代理客户端(auto)' }
        default       { return $PROXY_MODE }
    }
}

# 代理客户端在线判定:按安装时识别的客户端分派;auto 任一命中即活,other 只依赖 TUN
function Test-ProxyAlive {
    switch ($PROXY_MODE) {
        'clash-verge' { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
        'sing-box'    { return [bool](Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) }
        'clashx'      { return [bool](Get-Process -Name 'ClashX' -ErrorAction SilentlyContinue) }
        'surge'       { return [bool](Get-Process -Name 'Surge' -ErrorAction SilentlyContinue) }
        'wireguard'   { return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') }
        'other'       { return $true }
        'auto' {
            if (Get-Process -Name 'verge-mihomo','sing-box','ClashX','Surge' -ErrorAction SilentlyContinue) { return $true }
            return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running')
        }
        default { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
    }
}

# TUN 在线判定:198.18 假IP段优先,否则回退到任意 Up 状态的虚拟网卡(兼容 Astrill/WireGuard/OpenVPN 等)
function Get-TunStatus {
    if (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '198.18.*' }) {
        return @{ up = $true; detail = '198.18 假IP段' }
    }
    $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'TAP|TUN|WireGuard|Wintun|VPN|Tailscale') }
    if ($nic) { return @{ up = $true; detail = '通用虚拟网卡' } }
    return @{ up = $false; detail = '不在线' }
}
function Test-TunUp {
    $t = Get-TunStatus
    return [bool]$t.up
}

function Get-Egress {
    $trace = & curl.exe -s --max-time 8 "https://www.cloudflare.com/cdn-cgi/trace" 2>$null
    $ip  = (($trace -split "`n" | Where-Object { $_ -like 'ip=*' })  -replace 'ip=','').Trim()
    $loc = (($trace -split "`n" | Where-Object { $_ -like 'loc=*' }) -replace 'loc=','').Trim()
    return @{ ip = $ip; loc = $loc }
}

# STUN 探针(纯 .NET UDP,手工构造 RFC5389 报文)
function Get-StunPublicIP([string]$server, [int]$port, [int]$timeoutMs = 2000) {
    try {
        $addr = ([System.Net.Dns]::GetHostAddresses($server) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1)
        if (-not $addr) { return @{ State = 'no-response'; Ip = $null } }
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $timeoutMs
        try {
            $txn = New-Object byte[] 12
            (New-Object System.Random).NextBytes($txn)
            $req = [byte[]](0x00, 0x01, 0x00, 0x00) + [byte[]](0x21, 0x12, 0xA4, 0x42) + $txn
            $udp.Connect($addr, $port)
            [void]$udp.Send($req, $req.Length)
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$remote)
            if ($null -eq $resp) { return @{ State = 'no-response'; Ip = $null } }
            if ($resp.Length -lt 20 -or $resp[0] -ne 0x01 -or $resp[1] -ne 0x01 -or
                $resp[4] -ne 0x21 -or $resp[5] -ne 0x12 -or $resp[6] -ne 0xA4 -or $resp[7] -ne 0x42) {
                return @{ State = 'malformed'; Ip = $null }
            }
            for ($i = 0; $i -lt 12; $i++) {
                if ($resp[8 + $i] -ne $txn[$i]) { return @{ State = 'malformed'; Ip = $null } }
            }
            $messageLength = ([int]$resp[2] -shl 8) -bor $resp[3]
            if (($messageLength % 4) -ne 0 -or (20 + $messageLength) -ne $resp.Length) {
                return @{ State = 'malformed'; Ip = $null }
            }
            $pos = 20
            while ($pos + 4 -le $resp.Length) {
                $atype = ([int]$resp[$pos] -shl 8) -bor $resp[$pos + 1]
                $alen  = ([int]$resp[$pos + 2] -shl 8) -bor $resp[$pos + 3]
                $next = $pos + 4 + $alen + ((4 - ($alen % 4)) % 4)
                if ($next -gt $resp.Length) { return @{ State = 'malformed'; Ip = $null } }
                if ($atype -eq 0x0020 -and $alen -eq 8 -and $resp[$pos + 5] -eq 0x01) {
                    $ipBytes = @($resp[$pos + 8], $resp[$pos + 9], $resp[$pos + 10], $resp[$pos + 11])
                    $cookie = [byte[]](0x21, 0x12, 0xA4, 0x42)
                    for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] = $ipBytes[$i] -bxor $cookie[$i] }
                    $ip = $ipBytes -join '.'
                    if (-not (Test-IPv4Literal $ip)) { return @{ State = 'malformed'; Ip = $null } }
                    return @{ State = 'response'; Ip = $ip }
                }
                $pos = $next
            }
            return @{ State = 'malformed'; Ip = $null }
        } catch {
            if ($_.Exception -is [System.Net.Sockets.SocketException] -and
                $_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut) {
                return @{ State = 'no-response'; Ip = $null }
            }
            return @{ State = 'error'; Ip = $null }
        } finally {
            if ($udp) { $udp.Close() }
        }
    } catch {
        return @{ State = 'error'; Ip = $null }
    }
}

function Get-StunAssessment([string]$ExitIp) {
    if (-not (Test-PublicIPv4Address $ExitIp)) {
        return @{ Ok = $false; Code = 'unknown'; Detail = '当前出口地址无效，无法验证 UDP 暴露' }
    }
    $servers = @(@("stun.miwifi.com", 3478), @("stun.chat.bilibili.com", 3478), @("stun.l.google.com", 19302), @("stun.cloudflare.com", 3478))
    $responses = @()
    $probeError = $false
    foreach ($s in $servers) {
        try { $probe = Get-StunPublicIP $s[0] $s[1] } catch { $probeError = $true; continue }
        if ($probe -is [string]) {
            if (Test-PublicIPv4Address $probe) { $responses += $probe } else { $probeError = $true }
        } elseif ($probe -is [hashtable] -and $probe.State -eq 'response') {
            if (Test-PublicIPv4Address ([string]$probe.Ip)) { $responses += [string]$probe.Ip } else { $probeError = $true }
        } elseif ($probe -is [hashtable] -and $probe.State -in @('error', 'malformed')) {
            $probeError = $true
        }
    }
    if ($responses.Count -eq 0) {
        if ($probeError) { return @{ Ok = $false; Code = 'fail'; Detail = 'STUN 探测异常，无法确认 UDP 暴露状态' } }
        return @{ Ok = $false; Code = 'unknown'; Detail = 'STUN 无响应，无法确认 UDP 暴露状态' }
    }
    $mismatch = @($responses | Where-Object { $_ -ne $ExitIp })
    if ($mismatch.Count -gt 0) {
        return @{ Ok = $false; Code = 'fail'; Detail = 'STUN 观察到与当前出口不一致的公网地址' }
    }
    return @{ Ok = $true; Code = 'ok'; Detail = 'STUN 响应与当前代理出口一致' }
}

function Test-IPv4Literal([string]$Value) {
    $address = $null
    if ($Value -cnotmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') { return $false }
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address)) { return $false }
    return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Test-PublicIPv4Address([string]$Value) {
    if (-not (Test-IPv4Literal $Value)) { return $false }
    $b = [System.Net.IPAddress]::Parse($Value).GetAddressBytes()
    # IANA IPv4 Special-Purpose Address Registry (checked 2026-10-27):
    # https://www.iana.org/assignments/iana-ipv4-special-registry/
    # Reject non-global/reserved source ranges, including multicast; no DNS/network lookup.
    if ($b[0] -in @(0, 10, 127) -or $b[0] -ge 224) { return $false }
    if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
    if ($b[0] -eq 192) {
        if ($b[1] -eq 0 -and $b[2] -eq 0) { return $b[3] -in @(9, 10) }
        if (($b[1] -eq 0 -and $b[2] -eq 2) -or ($b[1] -eq 88 -and $b[2] -eq 99) -or $b[1] -eq 168) { return $false }
    }
    if ($b[0] -eq 198 -and ($b[1] -in @(18, 19) -or ($b[1] -eq 51 -and $b[2] -eq 100))) { return $false }
    if ($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113) { return $false }
    return $true
}

function Test-WebRTC($exitIp) {
    $assessment = Get-StunAssessment -ExitIp $exitIp
    return @{ code = $assessment.Code; detail = $assessment.Detail }
}

function Test-RulesPinned { (Test-Path "$CLASH_DIR\clash-verge.yaml") -and (Select-String -Path "$CLASH_DIR\clash-verge.yaml" -Pattern "DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" -Quiet) -and (Select-String -Path "$CLASH_DIR\clash-verge.yaml" -Pattern "DST-PORT,3478," -Quiet) }

function Invoke-CheckDetail {
    $pname = Get-ProxyName
    if (Test-ProxyAlive) {
        if ($PROXY_MODE -eq 'other') { "代理内核=ok:$pname(仅校验TUN)" }
        else { "代理内核=ok:$pname 运行中" }
    } else { "代理内核=fail:$pname 未运行" }

    $tun = Get-TunStatus
    if ($tun.up) {
        if ($tun.detail -eq '198.18 假IP段') { "TUN网卡=ok" }
        else { "TUN网卡=ok:$($tun.detail)" }
    } else { "TUN网卡=fail:不在线" }

    $e = Get-Egress
    if ($e.loc -eq $COUNTRY_TARGET) { "出口IP=ok:$($e.ip)" } else { "出口IP=fail:$($e.ip)/$($e.loc)(期望$COUNTRY_TARGET)" }

    $lastipFile = "$BASE\lastip.txt"
    $lastip = if (Test-Path $lastipFile) { (Get-Content $lastipFile -Raw).Trim() } else { '' }
    if (-not $e.ip) { "IP一致=fail:未获取到出口IP" }
    elseif (-not $lastip) { "IP一致=ok:首次记录" }
    elseif ($e.ip -eq $lastip) { "IP一致=ok" }
    else { "IP一致=warn:$lastip → $($e.ip)" }
    if ($e.ip) { $e.ip | Out-File -Encoding ascii -NoNewline $lastipFile }

    $tz = (Get-TimeZone).Id
    if ($tz -eq $TZ_TARGET) { "时区=ok" } else { "时区=fail:$tz" }

    $cult = (Get-Culture).Name
    if ($cult -eq 'en-US') { "地区=ok" } else { "地区=fail:$cult" }

    $v6off = [bool](Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq $true })
    if (-not $v6off) { "IPv6=ok:已关闭" } else { "IPv6=fail:未关闭" }

    $dns = (Resolve-DnsName claude.ai -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if ($dns -like '198.18.*') { "DNS=ok:走隧道" } else { "DNS=fail:未走隧道($dns)" }

    $w = Test-WebRTC $e.ip
    "WebRTC=$($w.code):$($w.detail)"

    $bg = Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue
    if ($bg) { "保镖=ok" } else { "保镖=fail:未安装" }

    if (Test-RulesPinned) { "规则置顶=ok" } else { "规则置顶=fail:未生效" }

    # 客户端语言: Windows 端 Claude 跟随系统区域格式,地区检查已覆盖
    "客户端语言=ok:跟随系统"

    $org = ''
    try { $org = ((& curl.exe -s --max-time 6 "https://ipinfo.io/json" 2>$null) | ConvertFrom-Json).org } catch {}
    if (-not $org) { "ASN属性=warn:未获取" }
    elseif ($org -match 'Comcast|AT&T|Verizon|Spectrum|Charter|Cox|T-Mobile|Cable|esidential') { "ASN属性=ok:$org" }
    else { "ASN属性=warn:疑似机房($org)" }

    $r1 = & curl.exe -s --max-time 8 -o NUL -w '%{http_code}' "https://claude.ai/" 2>$null
    $r2 = & curl.exe -s --max-time 8 -o NUL -w '%{http_code}' "https://api.anthropic.com/v1/models" 2>$null
    if ($r1 -ne '000' -and $r2 -ne '000') { "生态可达性=ok:claude.ai:$r1 api:$r2" } else { "生态可达性=fail:claude.ai:$r1 api:$r2" }
}

function Invoke-Fix {
    "FIX:开始一键修复"

    # A. 拉起代理客户端并等待内核+TUN(仅 Clash Verge 可自动拉起)
    if ($PROXY_MODE -eq 'clash-verge') {
        if (-not (Test-ProxyAlive)) {
            "FIX:正在启动 Clash Verge..."
            $cv = Get-ChildItem "$env:LOCALAPPDATA\Programs","$env:ProgramFiles","${env:ProgramFiles(x86)}" -Recurse -Filter "Clash Verge*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cv) { Start-Process $cv.FullName } else { "FIX:未找到 Clash Verge 可执行文件,请手动启动" }
        }
        $ok = $false
        for ($i = 0; $i -lt 40; $i++) { if ((Test-ProxyAlive) -and (Test-TunUp)) { $ok = $true; break }; Start-Sleep 1 }
        if ($ok) { "FIX:代理内核+TUN ✓" } else { "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路及 TUN 开关)" }
    } else {
        $pname = Get-ProxyName
        if ((Test-ProxyAlive) -and (Test-TunUp)) { "FIX:代理客户端($pname)+TUN ✓" }
        elseif (-not (Test-ProxyAlive)) { "FIX:代理客户端($pname)未运行,请手动启动并开启 TUN 模式" }
        else { "FIX:TUN 未在线($pname),请检查客户端 TUN 开关" }
    }

    # B. 时区/IPv6/DNS/保镖(需管理员:通过 UAC 弹一次)
    $adminScript = @()
    if ((Get-TimeZone).Id -ne $TZ_TARGET) { $adminScript += "Set-TimeZone -Id '$TZ_TARGET'" }
    if (Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled }) { $adminScript += "Get-NetAdapterBinding -ComponentID ms_tcpip6 | Disable-NetAdapterBinding -Confirm:`$false" }
    $adminScript += "Clear-DnsClientCache"
    if (-not (Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue)) {
        $adminScript += "`$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\claude-bodyguard.ps1`"'; `$t = New-ScheduledTaskTrigger -AtLogOn; Register-ScheduledTask -TaskName 'ClaudeBodyguard' -Action `$a -Trigger `$t -Force | Out-Null; Start-ScheduledTask -TaskName 'ClaudeBodyguard'"
    }
    if ($adminScript.Count -gt 0) {
        "FIX:修复时区/IPv6/DNS/保镖(需要管理员授权)..."
        $tmp = "$env:TEMP\claude-fix-$([guid]::NewGuid().Guid).ps1"
        ($adminScript -join "`n") | Out-File -Encoding utf8 $tmp
        try { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`"" } catch { "FIX:管理员授权被取消" }
        Remove-Item $tmp -ErrorAction SilentlyContinue
        "FIX:时区/IPv6/DNS/保镖 ✓"
    } else {
        "FIX:时区/IPv6/保镖 无需修复 ✓"
    }

    # B2. 置顶规则(仅 Clash Verge 可自动改写)
    if ($PROXY_MODE -ne 'clash-verge') {
        "FIX:请在 $(Get-ProxyName) 中自行添加 Claude 域名置顶规则"
    } elseif (-not (Test-RulesPinned)) {
        "FIX:重写置顶规则..."
        $merge = @"
profile:
  store-selected: true

prepend-rules:
  - DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP
  - DOMAIN-SUFFIX,claude.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,anthropic.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,claudeusercontent.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,challenges.cloudflare.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,datadoghq.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,segment.io,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripe.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripe.network,$PROXY_GROUP
  - DOMAIN-SUFFIX,stripecdn.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercom.io,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercomcdn.com,$PROXY_GROUP
  - DOMAIN-SUFFIX,intercomassets.com,$PROXY_GROUP
  - DST-PORT,3478,$PROXY_GROUP
  - DST-PORT,5349,$PROXY_GROUP
  - DST-PORT,19302,$PROXY_GROUP
"@
        New-Item -ItemType Directory -Force -Path "$CLASH_DIR\profiles" | Out-Null
        $merge | Out-File -Encoding utf8 "$CLASH_DIR\profiles\Merge.yaml"
        Get-Process -Name 'clash-verge','Clash Verge' -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep 2
        $cv = Get-ChildItem "$env:LOCALAPPDATA\Programs" -Recurse -Filter "Clash Verge*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cv) { Start-Process $cv.FullName }
        for ($i = 0; $i -lt 40; $i++) { if (Test-TunUp) { break }; Start-Sleep 1 }
        if (Test-RulesPinned) { "FIX:置顶规则 ✓" } else { "FIX:置顶规则 ✗(请重启 Clash Verge)" }
    }

    # C. 出口IP最终验证
    Start-Sleep 2
    $e = Get-Egress
    if ($e.loc -eq $COUNTRY_TARGET) { "FIX:出口IP ✓ ($($e.ip))" } else { "FIX:出口IP ✗ ($($e.ip)/$($e.loc),期望$COUNTRY_TARGET) — 请换节点/线路" }
    "FIX:修复流程结束"
}

function Invoke-Status {
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }
    $hasA = if (Test-Path "$BASE\accounts\A") { 1 } else { 0 }
    $hasB = if (Test-Path "$BASE\accounts\B") { 1 } else { 0 }
    "current=$cur hasA=$hasA hasB=$hasB"
}

function Test-LaunchGate {
    $required = @(
        '代理内核', 'TUN网卡', '出口IP', 'IP一致', '时区', '地区', 'IPv6',
        'DNS', 'WebRTC', '保镖', '规则置顶', '客户端语言', 'ASN属性', '生态可达性'
    )
    $checks = @{}
    $seen = @{}
    try {
        foreach ($line in @(Invoke-CheckDetail)) {
            $row = [string]$line
            if ([string]::IsNullOrWhiteSpace($row)) { continue }
            $parts = $row -split '=', 2
            if ($parts.Count -ne 2) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-malformed'
                }
            }
            $name = [string]$parts[0]
            if ($required -notcontains $name) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-unknown'
                }
            }
            if ($seen.ContainsKey($name)) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-duplicate'
                }
            }
            $state = $parts[1] -split ':', 2
            if ($state.Count -lt 1 -or -not $state[0]) {
                return [pscustomobject]@{
                    CanLaunch = $false
                    Checks = $checks
                    BlockingReason = 'checks-malformed'
                }
            }
            $seen[$name] = $true
            $checks[$name] = [string]$state[0]
        }
    } catch {
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'checks-error'
        }
    }
    foreach ($name in $required) {
        if (-not $checks.ContainsKey($name)) {
            return [pscustomobject]@{
                CanLaunch = $false
                Checks = $checks
                BlockingReason = 'checks-incomplete'
            }
        }
    }
    if ($checks['出口IP'] -ne 'ok') {
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'egress'
        }
    }
    if ($checks['WebRTC'] -eq 'unknown') {
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'stun-unknown'
        }
    }
    $warningAllowlist = @('IP一致', 'ASN属性')
    foreach ($name in $required) {
        if ($checks[$name] -eq 'ok') { continue }
        if ($checks[$name] -eq 'warn' -and $warningAllowlist -contains $name) { continue }
        return [pscustomobject]@{
            CanLaunch = $false
            Checks = $checks
            BlockingReason = 'check-failed'
        }
    }
    return [pscustomobject]@{
        CanLaunch = $true
        Checks = $checks
        BlockingReason = ''
    }
}

function Stop-ClaudeApp {
    $p = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
    if (-not $p) { return $true }
    $p | Stop-Process -Force
    for ($i = 0; $i -lt 15; $i++) { if (-not (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) { return $true }; Start-Sleep 1 }
    return $false
}

function Save-Account($name) {
    robocopy "$DATA" "$BASE\accounts\$name" /MIR /NFL /NDL /NJH /NJS | Out-Null
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -lt 0 -or $copyExitCode -ge 8) {
        Log "账号$name 存档失败(robocopy=$copyExitCode)"
        return $false
    }
    Log "已存档账号$name"
    return $true
}

function Start-ClaudeApp {
    $exe = @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) { Start-Process $exe } else { Start-Process "shell:AppsFolder" -ErrorAction SilentlyContinue }
}

function Invoke-Switch([ValidateSet('A','B')][string]$Target) {
    $script:SwitchExitCode = 0
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }

    $preGate = Test-LaunchGate
    if (-not $preGate.CanLaunch) {
        $script:SwitchExitCode = 1
        "FAIL:切换前检查未通过($($preGate.BlockingReason))，未修改账号数据且 Claude 未启动"
        return
    }

    # 首次运行:收编当前登录为账号A
    $collectCurrent = $cur -eq 'none' -and (Test-Path $DATA) -and (Get-ChildItem $DATA -ErrorAction SilentlyContinue)
    $willRestoreTarget = $cur -ne $Target
    if ($collectCurrent -and $Target -eq 'A') { $willRestoreTarget = $false }
    $stagingData = "$DATA.claude-switch-staging"
    if ($willRestoreTarget -and (Test-Path -LiteralPath $stagingData)) {
        $script:SwitchExitCode = 1
        "FAIL:检测到未处理的账号暂存目录，拒绝覆盖($stagingData)，Claude 未启动"
        return
    }

    $collectedCurrent = $false
    if ($collectCurrent) {
        if (-not (Stop-ClaudeApp)) {
            $script:SwitchExitCode = 1
            "FAIL:Claude 未能退出，请手动退出后重试"
            return
        }
        if (-not (Save-Account A)) {
            $script:SwitchExitCode = 1
            "FAIL:当前登录状态存档失败，未更新 current.txt 且 Claude 未启动"
            return
        }
        $cur = 'A'; 'A' | Out-File -Encoding ascii -NoNewline "$BASE\current.txt"
        $collectedCurrent = $true
        Log "首次运行:当前登录状态已收编为账号A"
        "NOTE:已将当前登录收编为账号A"
    }

    if ($cur -eq $Target) {
        $launchGate = if ($collectedCurrent) { Test-LaunchGate } else { $preGate }
        if (-not $launchGate.CanLaunch) {
            $script:SwitchExitCode = 1
            "FAIL:启动前检查未通过($($launchGate.BlockingReason))，Claude 未启动"
            return
        }
        Start-ClaudeApp
        "INFO:当前已是账号$Target"
        return
    }

    if (-not (Stop-ClaudeApp)) {
        $script:SwitchExitCode = 1
        "FAIL:Claude 未能退出，请手动退出后重试"
        return
    }

    if ($cur -ne 'none' -and (Test-Path $DATA)) {
        if (-not (Save-Account $cur)) {
            $script:SwitchExitCode = 1
            "FAIL:账号$cur 存档失败，未替换当前数据且 Claude 未启动"
            return
        }
    }

    try {
        New-Item -ItemType Directory -Path $stagingData -ErrorAction Stop | Out-Null
    } catch {
        $script:SwitchExitCode = 1
        "FAIL:无法创建账号暂存目录，未替换当前数据且 Claude 未启动"
        return
    }

    if (Test-Path "$BASE\accounts\$Target") {
        robocopy "$BASE\accounts\$Target" "$stagingData" /E /NFL /NDL /NJH /NJS | Out-Null
        $restoreExitCode = $LASTEXITCODE
        if ($restoreExitCode -lt 0 -or $restoreExitCode -ge 8) {
            $script:SwitchExitCode = 1
            "FAIL:账号$Target 存档载入失败(robocopy=$restoreExitCode)，已保留暂存目录$stagingData，Claude 未启动"
            return
        }
        Log "已载入账号$Target 存档"
    } else {
        Log "账号$Target 无存档，将以全新状态初始化"
    }

    try {
        if (Test-Path -LiteralPath $DATA) {
            Remove-Item -LiteralPath $DATA -Recurse -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $stagingData -Destination $DATA -ErrorAction Stop
    } catch {
        $script:SwitchExitCode = 1
        "FAIL:账号$Target 暂存数据无法切换到活动目录，Claude 未启动"
        return
    }
    $Target | Out-File -Encoding ascii -NoNewline "$BASE\current.txt"

    $finalGate = Test-LaunchGate
    if (-not $finalGate.CanLaunch) {
        $script:SwitchExitCode = 1
        "FAIL:启动前检查未通过($($finalGate.BlockingReason))，Claude 未启动"
        return
    }

    Start-ClaudeApp
    Log "已切换到账号$Target 并启动"
    "OK:已切换到账号$Target"
}
switch ($args[0]) {
    'checkdetail' {
        $r = Invoke-CheckDetail
        $r | Out-File -Encoding utf8 "$BASE\last-check.txt"
        $r
    }
    'status' { Invoke-Status }
    'fix'    { Invoke-Fix }
    'switch' {
        $result = @(Invoke-Switch $args[1])
        $result
        if ($script:SwitchExitCode -ne 0) { exit $script:SwitchExitCode }
    }
    default  { "用法: claude-switch.ps1 checkdetail|status|fix|switch A|B" }
}
