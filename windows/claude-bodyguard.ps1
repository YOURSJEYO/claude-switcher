# Claude 保镖 (Windows) —— 代理离线时自动关闭 Claude
# 由安装器注册为计划任务,登录时启动,隐藏窗口常驻
$ErrorActionPreference = 'Stop'
$script:BodyguardBase = Join-Path $env:USERPROFILE '.claude-switcher'

function Test-BodyguardUserSid([string]$Sid) {
    return $Sid -cmatch '^S-1-(?:5-21|12-1)(?:-[0-9]+){4}$'
}

# 版本化用户配置优先；旧脚本安装可读取 proxy-mode.txt。
function Get-BodyguardIdentity {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $sid=$identity.User.Value
        $session=[Diagnostics.Process]::GetCurrentProcess().SessionId
        if (-not (Test-BodyguardUserSid $sid) -or $session -le 0) { throw 'Monitor requires an ordinary interactive user.' }
        return [pscustomobject]@{Sid=$sid;SessionId=$session}
    } finally { $identity.Dispose() }
}

function Get-BodyguardProcessId { return $PID }

function Read-BodyguardOwnedFile([string]$Path, [long]$MaxBytes) {
    $caller=Get-BodyguardIdentity
    $item=Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($null -eq $item -or $item.PSIsContainer -or
        $item.Length -gt $MaxBytes -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Invalid monitor configuration.'
    }
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($null -eq $acl -or
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $caller.Sid) {
        throw 'Invalid monitor configuration.'
    }
    return [IO.File]::ReadAllText($Path)
}

function Get-BodyguardProxyMode {
    $path=Join-Path $script:BodyguardBase 'config.json'
    if (Test-Path -LiteralPath $path) {
        $config=(Read-BodyguardOwnedFile $path 65536) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $config -or $config -is [array] -or
            $config.schemaVersion -ne 1 -or
            $config.proxyMode -isnot [string] -or
            $config.proxyMode -cnotin @('clash-verge','sing-box','clashx','surge','wireguard','auto','other')) {
            throw 'Invalid monitor configuration.'
        }
        return $config.proxyMode
    }
    $legacy=Join-Path $script:BodyguardBase 'proxy-mode.txt'
    if (Test-Path -LiteralPath $legacy) {
        $mode=(Read-BodyguardOwnedFile $legacy 64).Trim()
        if ($mode -cnotin @('clash-verge','sing-box','clashx','surge','wireguard','auto','other')) { throw 'Invalid legacy monitor mode.' }
        return $mode
    }
    return 'clash-verge'
}
function Get-OwnedClaudeProcesses {
    $caller=Get-BodyguardIdentity
    foreach($process in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='Claude.exe'" -ErrorAction Stop)) {
        if ($process.SessionId -ne $caller.SessionId) { continue }
        $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrEmpty($owner.Sid)) { throw 'Process owner could not be verified.' }
        if ($owner.Sid -ne $caller.Sid) { continue }
        $live=Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if ($live -and $live.SessionId -eq $caller.SessionId -and $live.ProcessName -ieq 'Claude') { $live }
    }
}

function Write-BodyguardHeartbeat {
    $caller=Get-BodyguardIdentity
    $record=[ordered]@{schemaVersion=1;userSid=$caller.Sid;sessionId=$caller.SessionId;processId=(Get-BodyguardProcessId);updatedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    $path=Join-Path $script:BodyguardBase 'bodyguard-heartbeat.json'
    $temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$path) }
    } finally { if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)} }
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

# 客户端进程/服务在线判定:auto 与 other 只依赖 TUN,不要求特定进程(避免误杀)
function Test-ClientAlive {
    switch ($PROXY_MODE) {
        'clash-verge' { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
        'sing-box'    { return [bool](Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue) }
        'clashx'      { return [bool](Get-Process -Name 'ClashX' -ErrorAction SilentlyContinue) }
        'surge'       { return [bool](Get-Process -Name 'Surge' -ErrorAction SilentlyContinue) }
        'wireguard'   { return [bool](Get-Service -Name 'WireGuardTunnel*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') }
        'auto'        { return $true }
        'other'       { return $true }
        default       { return [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
    }
}

function Start-Bodyguard {
    $null=Get-BodyguardIdentity
    [void][IO.Directory]::CreateDirectory($script:BodyguardBase)
    while ($true) {
        $alive=$false
        try {
            $script:PROXY_MODE=Get-BodyguardProxyMode
            $alive=(Get-TunStatus).up -and (Test-ClientAlive)
        } catch { $alive=$false }
        try {
            if (-not $alive) {
                $owned=@(Get-OwnedClaudeProcesses)
                if ($owned.Count) { $owned | Stop-Process -Force -ErrorAction Stop }
            }
            Write-BodyguardHeartbeat
        } catch {
            # No fresh heartbeat on uncertain ownership or unsuccessful protection.
            # Core checks will block launching once the previous evidence expires.
        }
        Start-Sleep -Seconds 10
    }
}

if ($MyInvocation.InvocationName -ne '.') { Start-Bodyguard }
