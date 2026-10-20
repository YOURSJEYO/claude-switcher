# AGENTS.md —— Agent 交接提示词

> 这份文件写给 AI Agent。用户把本项目交给你时，请按本文档执行安装与配置。
> 用户也可以直接把本文件内容粘贴给任意本地模型（Kimi Code / Cursor / Claude Code 等）作为指令。

---

## 你的任务

帮助用户在 macOS 上安装并配置「Claude 切换器」：一个带环境安检的 Claude 账号启动/切换工具。目标状态是：**用户双击桌面图标，14 项安全检查全部通过，可以正常启动 Claude**。

## 开始之前：必须先确认的前置条件

逐项检查，缺哪项就先补哪项：

1. **macOS**（Apple Silicon 或 Intel 均可）
2. **Shadowrocket** 已安装并已连接（`scutil --nc list` 中应出现 `com.liguangming.Shadowrocket` 且状态为 `(Connected)`，TUN 已接管：`ifconfig | grep 'inet 198.18.'`）
3. **Claude 桌面版** 在 `/Applications/Claude.app`
4. **python3 与 swiftc** 可用（`xcode-select --install` 可一并补齐）
5. **当前出口 IP 必须已经是美国**——先跑 `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep loc=`，返回 `loc=US` 才能继续。不是美国就停下，让用户先把代理调好（安装程序会按出口 IP 锁定时区，裸连时装机会把时区锁错）

## 安装步骤

首选引导用户运行安装器（双击 `installer/安装.command`，或终端执行它）。如果安装器环境受限，按下面的手动等效步骤执行：

1. 把 `core/claude-switch.sh` 复制为 `~/.local/bin/claude-switch.sh`（可执行），把 `core/stun-probe.py` 放到 `~/.claude-switcher/`
2. 按出口 IP 城市确定锁定时区（`curl -s ipinfo.io/json` 的 timezone 字段），写进脚本顶部 `TZ_TARGET="..."`
3. 参照 `daemons/` 目录的模板，生成保镖与时区看门狗脚本（把 `__HOME__` / `__TZ_TARGET__` 替换为实际值），并安装对应的 launchd 服务到 `/Library/LaunchDaemons/`（需要 sudo）
4. 编译界面 App（需要 Xcode 命令行工具）：
   ```bash
   swiftc -O -parse-as-library app/main.swift -o Claude切换器.app/Contents/MacOS/ClaudeSwitcher -framework SwiftUI -framework AppKit
   ```
   图标已在 `assets/` 里，打进 `Contents/Resources/AppIcon.icns` 并在 `Info.plist` 声明 `CFBundleIconFile`
5. **不要改写 Shadowrocket 配置**。路由覆盖是行为检测：`claude.ai` / `api.anthropic.com` / `claudeusercontent.com` 解析到 `198.18.x.x` 即通过；否则提示用户自己在 Shadowrocket 里加 `DOMAIN-SUFFIX` 规则
6. 时区与 IPv6：`systemsetup -settimezone <TZ_TARGET>`、`networksetup -setv6off Wi-Fi`（需管理员）

## 验收标准（全部满足才算装完）

- 终端执行 `~/.local/bin/claude-switch.sh checkdetail` 输出 14 行且全部 `=ok`
- 双击桌面 App，界面全绿，能正常启动 Claude
- `launchctl print system/local.claude-bodyguard` 与 `system/local.tz-watchdog` 均能查到（服务已注册）
- 切换一次账号 B 再切回 A，A 的登录态完好

## 排障手册（以下全是实战中踩过的坑，按症状直接查）

| 症状 | 根因 | 处理 |
|---|---|---|
| TUN 网卡消失、出口变回国内 | Shadowrocket 断开或系统 VPN 配置被重置 | 打开 Shadowrocket 重新连接；确认 `scutil --nc status Shadowrocket` 为 Connected 且存在 `198.18.x.x`。切换器只做检测，不会重启 Shadowrocket |
| 时区总是自己变回去 | macOS 自动时区或未知程序改动（生产环境已抓 8 次） | 看门狗会自动回滚；查 `~/Library/Logs/tz-watchdog.log` 留痕 |
| 检查结果显示 0/14、数据为空 | 中文日志被 `cut -c` 按字节截断产生非法 UTF-8，Swift 严格解码整体失败 | 脚本必须 `export LC_ALL=en_US.UTF-8`；界面端用容错解码 `String(decoding:as:)` |
| 修改 App 后界面没变化 | 旧进程没死：App 关窗不退 + `pkill` 匹配中文路径会因 Unicode NFD 编码失配而静默失败 | 用 `pkill -x ClaudeSwitcher`（按进程名）；App 必须实现 `applicationShouldTerminateAfterLastWindowClosed` |
| headless Chrome 做 WebRTC 检测无结果 | headless 模式 ICE 子系统不产出候选 | 不要走浏览器路线，用本项目的纯 Python STUN 探针 |
| 代理节点报错但流量没泄漏 | 节点被重置时隧道内请求失败≠泄漏；Fail-Closed 下流量只断不绕 | 换线路即可 |
| 切换账号后对方看到"新设备" | 正常：快照隔离意味着每个账号有独立设备指纹，这正是设计目标 | 无需处理 |

## 安全红线（Agent 必须遵守）

1. **绝不在出口非美国时启动 Claude**——任何时候先验 `loc=US`
2. 切换账号前必须先完全退出 Claude 进程，再交换数据目录
3. 不要在日志、文档、Issue 里暴露用户的住宅/代理 IP 与任何凭据
4. 不要改动 `~/.claude-switcher/accounts/` 下的存档结构

## Windows 版（windows/ 目录, Beta）

Windows 用户请使用 `windows/` 下的 PowerShell 版本。关键差异与注意事项：

- **文件编码**：所有 `.ps1` 文件必须保持 **UTF-8 with BOM**（Windows PowerShell 5.1 无 BOM 会把中文读成乱码）。编辑后若中文变乱码，重新加 BOM。
- **时区 ID 体系不同**：Windows 用 `Eastern Standard Time` 这类 ID，安装器负责把 IANA 时区（America/New_York）映射过去，见 `install.ps1` 的 `$tzMap`。
- **权限模型**：`install.ps1` 需要管理员运行（注册计划任务/锁时区/关 IPv6）；日常使用中「一键修复」通过 `Start-Process -Verb RunAs` 触发 UAC 弹窗。
- **保镖实现**：用计划任务（AtLogOn 触发）启动隐藏 PowerShell 常驻进程，10 秒巡检，与 Mac 版行为一致。
- **robocopy 退出码**：0-7 都是成功，8+ 才是失败——判断切换成败时不要按常规退出码判断。
- **账号数据目录**：`%APPDATA%\Claude`（不是 macOS 的 `~/Library/Application Support/Claude`）。
- **已知限制**：WPF 界面为第一版重写，未经大规模真机测试；Clash Verge 的 TUN 开关被更新重置后在 Windows 端需手动重开。
- SmartScreen 首次运行拦截属正常现象（未签名脚本），引导用户「更多信息 → 仍要运行」。

## Linux 版（linux/ 目录, Beta）

Linux 用户使用 `linux/` 下的 bash 版本。**开始之前必须先理解最大的前提差异**：

- **Claude 官方没有 Linux 桌面版**——使用形态是「网页版(浏览器) + Claude Code CLI」。因此：
  - 账号切换切换的是**浏览器配置目录**（`~/.config/google-chrome` 或 `~/.config/chromium`），即切换 Web 登录态；切换前必须完全退出浏览器
  - 保镖只终止 `claude` CLI 进程，**不要让它去杀浏览器**（网页端保护交给 TUN + 置顶规则）
- **常驻服务**：systemd 用户单元（`~/.config/systemd/user/`，免 sudo、登录自启）
- **系统设置**：时区用 `timedatectl set-timezone`（sudo）；IPv6 用 `sysctl -w net.ipv6.conf.all.disable_ipv6=1` + `/etc/sysctl.d/` 持久化
- **DNS 查询工具**：`dig` → `nslookup` → `getent` 逐级回退（部分发行版默认无 dig，脚本已内置回退，勿改成 dig 硬依赖）
- **界面**：无 GUI，终端菜单（`claude-switch menu`）+ CLI 参数
- **发行版差异**：安装器不区分发行版，但依赖 systemd；非 systemd 发行版（如 Alpine/void 部分配置）需要手工替代保镖常驻方式
- 配置目录路径：Clash Verge Linux 版配置在 `~/.config/io.github.clash-verge-rev.clash-verge-rev/`（脚本已兼容两种常见路径）

## 文件索引

- 核心逻辑：`core/claude-switch.sh`（安检/切换/修复全在这一个文件）
- 泄漏探针：`core/stun-probe.py`
- 界面：`app/main.swift`（单文件 SwiftUI）
- 守护进程模板：`daemons/`
- 安装器：`installer/`
- Windows 版：`windows/`（核心 `claude-switch.ps1` / 界面 `SwitcherUI.ps1` / 安装器 `install.ps1` / 保镖 `claude-bodyguard.ps1`）
- Linux 版：`linux/`（核心 `claude-switch.sh` / 保镖 `claude-bodyguard.sh` / 安装器 `install.sh`）
