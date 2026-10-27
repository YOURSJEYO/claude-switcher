<div align="center">

# Claude 切换器

[English](README.en.md) · [Releases](https://github.com/YOURSJEYO/claude-switcher/releases/latest)

**Fail-Closed 账号环境管理器 —— 把真实 IP 泄漏拦截在启动之前**

> 🛠️ **本项目持续活跃更新中**——防护项随目标平台风控演进不断增加，见下方[路线图](#路线图)。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/YOURSJEYO/claude-switcher?label=release&color=blue)](https://github.com/YOURSJEYO/claude-switcher/releases/latest)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)]()
[![Windows](https://img.shields.io/badge/Windows-Beta-lightgrey.svg)](windows/)
[![Linux](https://img.shields.io/badge/Linux-Beta-lightgrey.svg)](linux/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-orange.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen.svg)]()

<img src="assets/icon-2048.png" width="128">

</div>

---

## 用途声明

本项目用于在合规地区管理多个 Claude 账号的本地环境与登录态，面向因出差、旅居等原因身处支持地区的用户。请遵守 Anthropic 服务条款；禁止用于账号转售、共享、代注册或规避地区限制。本地环境检查只影响本机配置，不改变服务端记录，也不构成账号不被限制的保证。

## 为什么做这个

AI 服务平台的风控已经从"看 IP"进化到**全维度环境画像**：时区、Locale、DNS 出口、WebRTC 候选地址、设备指纹、行为时序。绝大多数封号不是因为你做错了什么，而是某个你没意识到的场景里，真实出口 IP 悄悄溜出去了一次——哪怕只是一个 TCP SYN 握手包。

本项目的立场：**防御不建立在"用户记得"上，而建立在系统级的硬性约束上**。

> 代理暴毙、软件静默升级、随手乱点——这些场景下受保护进程会被保镖在秒级终止，裸连窗口被压缩到最小。这是**进程级急停**，不是防火墙级保证：巡检周期内存在固有的 TOCTOU 窗口，边界说明见 [SECURITY.md](SECURITY.md)。

## 核心创新

### 1. Block-on-Fail 环境审计引擎

每次启动前强制执行 14 项环境指纹审计，**任一指标不达标，应用物理上不会被拉起**：

| # | 检查项 | 防什么 |
|---|---|---|
| 01 | 代理内核 | 代理根本没在跑就启动 |
| 02 | TUN 网卡 | 系统代理开着但流量没被接管 |
| 03 | 出口 IP | 出口国家/地区异常 |
| 04 | IP 一致性 | 出口 IP 突变（跳节点是风控信号） |
| 05 | 时区 | 系统时区与 IP Geo-location 冲突 |
| 06 | 地区 Locale | 系统区域设置不符 |
| 07 | IPv6 | 双栈旁路直连（最隐蔽的泄漏通道之一） |
| 08 | DNS 隧道 | Fake-IP 校验，杜绝明文 DNS 泄漏 |
| 09 | WebRTC | 多节点 STUN 交叉探测（详见第 2 节） |
| 10 | 保镖守护进程 | Kill-Switch 是否在线（详见第 3 节） |
| 11 | 置顶路由规则 | 生态域名是否被强制走代理（详见第 6 节） |
| 12 | 客户端语言 | 防止 JS 层 `navigator.language` / `Intl` 读出系统中文 |
| 13 | ASN 属性 | 住宅宽带 vs 机房 IP（Residential vs Datacenter） |
| 14 | 生态可达性 | claude.ai / api.anthropic.com 连通性验证 |

> 关于「IP 与上次一致」：除了比对上一次出口，审计引擎还会维护 48 小时出口 IP 历史——**48 小时内出口 IP 变化 ≥3 次会亮黄色警告**（不阻断启动）。IP 频繁漂移意味着账号画像在风控眼里"居无定所"，建议固定一条高质量住宅节点长期使用。

### 2. 纯标准库手写 STUN 协议栈的 WebRTC 泄漏探针

不依赖浏览器内核（headless Chrome 的 ICE 子系统在无人值守场景下根本不工作——我们踩过这个坑），直接用 `socket` + `struct` 手工构造 RFC 5389 Binding Request，解析 XOR-MAPPED-ADDRESS。

真正的创新在**交叉验证拓扑**：探测列表同时包含全球节点（Google/Cloudflare）与国内骨干节点——走隧道时应回传代理出口 IP，裸连时国内节点必然秒回并当场抓获真实 IP。两种状态可区分、零误报、不依赖"恰好不通"。

### 3. Fail-Closed Kill-Switch

常驻守护进程以 10s 周期巡检隧道健康度（内核进程 × 虚拟网卡双因子），隧道中断即刻终止受保护进程。区别于客户端自带的 Fail-Open 容错重试——那种机制会把含真实 IP 的握手包送到对方网关日志里，哪怕最终"超时失败"。

### 4. Session Snapshot 快照隔离

多账号不是"登出再登入"（那会产生大量认证事件与指纹抖动），而是**物理交换数据卷**：每个账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换时原子化封存/载入。对服务端而言，每个账号看到的都是一台恒定不变的设备。

切换开销被压到"零拷贝"级别：归档是**同卷移动**（rename，瞬时完成），载入走 **APFS clonefile / reflink 的写时复制（COW）**——只有日后被修改的数据块才会真正复制。macOS 不支持 clonefile 时自动回退 `ditto` 全量复制，Linux 回退普通 `cp -a`（可用 `CLAUDE_SWITCHER_NO_CLONE=1` 强制走回退路径）。

### 5. 配置漂移自愈（Watchdog）

软件更新会静默重置你的安全配置（我们的生产环境里，TUN 开关被代理客户端更新重置了 4 次，系统时区被改回 8 次）。Watchdog 周期巡检 + 基线回滚 + 全程留痕，配置漂移从"事故"降级为"日志里的一行记录"。

### 6. Pinned Routing 置顶路由

目标服务全家族域名及其生态依赖（Turnstile 人机验证 / Telemetry / Payment / Support）置顶锁定代理路由，优先级高于任何第三方分流规则集——不信任、不验证、直接免疫规则库误判。

## 实战战绩

这不是玩具项目，每个机制都有生产环境实战记录：

```
2026-10-07 00:31:12  代理离线(内核或TUN丢失),已自动关闭 Claude   ← Kill-Switch 真实拦截
2026-10-04 12:55:26  时区异常: [Asia/Shanghai] 已自动恢复        ← Watchdog 第 8 次拦截漂移
```

## 界面

![Screenshot](docs/screenshot.png)

原生 SwiftUI 单文件应用（无 Xcode 工程、无第三方依赖，`swiftc` 一条命令出可执行文件），图标由 Swift 代码程序生成——整个仓库不含一张设计素材。

## 安装

**系统要求**：macOS · Clash Verge / Shadowrocket / sing-box / ClashX / Surge 任一（TUN 可用）· Claude 桌面版 · python3

> **Windows 用户**：[`windows/`](windows/) 目录提供 Windows x64 原生版源码（WPF + PowerShell 核心，Development Beta）。Inno 模板、受保护 helper、受控 Preview/Apply 安装流程、原生 SetupClient/协议和 Windows CI 打包定义均已存在；但本机没有 ISCC，尚未成功编译 Setup EXE，也没有安装器/UAC/Windows 10/11 VM acceptance 或 Windows release readiness。详见 [windows/README.md](windows/README.md)。
> **Linux 用户**：[`linux/`](linux/) 目录提供 Linux 版（bash + systemd，Beta），设计取舍（无官方桌面版→切换浏览器登录态）见 [linux/README.md](linux/README.md)。

### 直接下载（推荐）

到 [Releases](https://github.com/YOURSJEYO/claude-switcher/releases/latest) 下载最新版本，按用途选择：

- `ClaudeSwitcher-<版本>-installer-kit.zip`：**首次安装推荐**。解压后双击 `installer/安装.command`，安装核心脚本、守护进程与桌面 App。
- `ClaudeSwitcher-<版本>-macos-arm64.dmg` / `.zip`：仅包含 macOS 界面 App；核心脚本已安装时可用于替换旧版界面。
- `ClaudeSwitcher-<version>-windows-setup.exe`：**计划中的** Windows x64 Inno Setup 安装包（Development Beta，未签名，.NET 10 self-contained App/Admin）。源码中的 `windows/ClaudeSwitcher.iss`、`windows/helpers/` 和受控安装流程已存在，但本机没有 ISCC，尚未成功编译 Setup EXE；安装/UAC/升级/卸载/保留行为仍待 Windows 10/11 VM acceptance，见 [windows/README.md](windows/README.md)。
- `ClaudeSwitcher-<version>-windows.zip`：**计划中的** Windows PowerShell 脚本兼容包，不是便携原生 EXE，也不是原生安装器。It is a compatibility UI/CLI package only: it does not contain the protected Admin helper executable and does not install the protected helper; it provides no full install or system-repair parity. Protected system changes require native setup or a separately documented, auditable administrator procedure; never run user-writable scripts elevated. 当前没有 Setup EXE 编译或 Windows 10/11 VM acceptance 证据，不要把它当作完整安装路径或当前已发布的资产。
- `ClaudeSwitcher-<版本>-linux.tar.gz`：Linux 脚本包（Beta），说明见 [linux/README.md](linux/README.md)。

> macOS 产物为 ad-hoc 签名、未公证。首次打开若被 Gatekeeper 拦截，请右键打开，或在「系统设置 → 隐私与安全性」中放行。计划中的 Windows 安装包也将是未签名产物，完成后 SmartScreen 可能提示风险；在发布前必须核对 `SHA256SUMS-release.txt` 和下载来源。每个 Release 附带 `SHA256SUMS-release.txt`，可用 `shasum -a 256 -c` 校验下载文件。

> **Windows 验收边界**：托管 CI 只执行构建、测试和打包，不是 Windows 10/11 安装验收；本文不声称已有成功的 hosted run。发布工作流设计为：Windows 原生资产只有在受保护环境中验证了绑定精确 commit、版本和 Setup EXE SHA256 的签名 VM 验收报告后才会发布。当前本机没有 ISCC，未成功编译 Setup EXE，且安装器执行/UAC/升级/卸载/VM acceptance 仍 outstanding；没有 Windows release readiness。

### 从源码安装

```bash
# 克隆后双击 installer/安装.command 即可,自动识别代理客户端、代理组名与地区目标
git clone https://github.com/YOURSJEYO/claude-switcher.git
```

## 地区自适应

不再锁死美国：安装程序按当前出口 IP 的国家自动锁定**目标国家 + 时区 + 地区格式**三件套（出口是 CN 会直接拒装，逼你先挂好代理）。之后换了其他国家的节点，不用重装，一条命令重新适配：

```bash
~/.local/bin/claude-switch.sh set-region
# 自动探测出口国家 → 改写自身配置 → 设地区格式 → 弹一次授权锁时区 → 同步看门狗
# 输出: OK:region=JP tz=Asia/Tokyo locale=ja_JP
```

14 项检查里的「出口 IP / 时区 / 地区」全部按新目标判定，界面无需任何改动。

## 不会配置？交给你的 AI

仓库根目录的 [`AGENTS.md`](AGENTS.md) 是一份完整的 **Agent 交接提示词**：把它直接粘贴给你的本地模型（Kimi Code / Cursor / Claude Code 等），它会按文档自动完成环境检查、安装、配置与验收。里面还附了我们实战踩过的全部坑的排障手册。

## 使用

1. 双击桌面「Claude切换器」→ 等待 14 项检查
2. 全绿 → 选账号启动；有红项 → 「一键修复」自动处理
3. B 账号首次使用登录一次，以后 A/B 随切随用、互不干扰
4. 换了其他国家的节点 → 跑一次 `~/.local/bin/claude-switch.sh set-region`，国家/时区/地区格式一键重新锁定

### macOS 菜单栏常驻

启动后，顶部菜单栏会显示盾牌图标，Dock 不显示应用图标。首次启动自动打开主窗口；关闭窗口或切换账号成功后只隐藏窗口，仍可从盾牌菜单重新打开。

- 菜单显示当前账号和「最近检查」结果（通过 / 有警告 / 失败 / 检查中），提供「打开主窗口」「重新检查」「退出 Claude 切换器」。A/B 切换仍在主窗口完成。
- 启动时检查一次；隐藏期间不轮询网络，展开菜单只读取本地账号状态。每次切换账号前会重新完成全部环境检查，检查失败、超时或输出不完整时不会执行切换；警告沿用现有放行规则。
- 检查、修复、切换和指纹体检期间不会重复执行操作；修复或账号切换期间暂时不能退出。操作结束后可从菜单明确退出。
- 退出切换器不会卸载或停止独立的保镖、时区看门狗和自动更新服务。应用本身不会因此新增登录自启动。

已安装的旧版 GUI 需要重新编译（或重新运行安装器）才会获得菜单栏功能；现有 `update` 命令仅更新核心脚本，不会替换 GUI。

开发者可在 macOS 上运行 `python3 -m unittest discover -s tests -v`，其中菜单栏模型测试使用假核心脚本，不访问真实账号或网络。隔离 UI 验证方法见 [tests/MENU-BAR-TESTING.md](tests/MENU-BAR-TESTING.md)。

## Web 版环境检测（零安装）

手机 / 平板浏览器打开即测，无需安装：[https://yoursjeyo.github.io/claude-switcher/](https://yoursjeyo.github.io/claude-switcher/)

页面逐项评估 6 类浏览器侧信号，并给出总评与失败项：

- **出口 IP / 归属**：ipinfo.io 优先，Cloudflare trace 兜底
- **地区一致性**：浏览器时区、UTC 偏移与语言是否和出口国家矛盾
- **WebRTC 泄漏**：STUN 候选地址与出口 IP 比对，识别 mDNS 混淆与 fake-IP
- **IPv6 暴露**：IPv6 是否可直连、归属国家是否与 IPv4 出口一致
- **DNS 泄漏（近似）**：1.1.1.1 / Google DoH 公共加密解析可达性
- **浏览器指纹展示**：Canvas 哈希、WebGL vendor/renderer、屏幕与设备参数（只展示，不阻断）

纯前端、无追踪、无 localStorage；检测请求只发往公共 API，结果不上传。它只评估浏览器侧信号，**不替代桌面版 14 项审计**，也不检测 TUN / 保镖 / 进程级泄漏。部署方式与完整隐私说明见 [docs/WEB-README.md](docs/WEB-README.md)。

## 设备指纹体检（macOS CLI / App 内置）

14 项审计之外，提供一层按需的深挖体检，点 App 右上角心电图标或运行：

```bash
~/.local/bin/claude-switch.sh fingerprint
```

输出四类信息：

- **字体地区特征**：扫描 `/Library/Fonts` 与 `~/Library/Fonts`，标记 SimSun / 微软雅黑 / 文泉驿 / 方正等随中文办公软件安装的字体——美区机器上很少出现，容易成为地区指纹
- **GPU / 显示**：芯片型号与分辨率（虚拟 GPU、SwiftShader 会明确告警）
- **虚拟机检测**：`kern.hv_vmm_present` 与虚拟化厂商字符串
- **Canvas/WebGL 指引**：原生进程读不到 Claude Electron 渲染器的指纹，这部分用 [Web 检测页](https://yoursjeyo.github.io/claude-switcher/) 查看

该体检不阻断启动，也不修改系统；如需彻底隐藏字体特征，可在「字体册」里停用可疑字体。

## Claude Code CLI 体检（macOS）

桌面版内置的 CLI 和自己用 npm/Homebrew 装的 CLI 经常版本不一致，或 PATH 里指向了旧版。只读检查：

```bash
~/.local/bin/claude-switch.sh cli-info
```

输出包含：

- PATH 中的 `claude` 路径、解析后的真实路径、`--version`
- 安装方式推断（native / Homebrew / npm·bun / 未知）
- 桌面版内置 CLI 的版本（`~/Library/Application Support/Claude/claude-code/...`）
- 是否同时存在 npm 全局包与 Homebrew 包（多份安装容易互相覆盖）
- `~/.claude` 配置目录是否存在及体积

该命令**只检测不修改**：不会卸载、升级或删除任何东西；需要重装时按输出里的建议自行执行对应包管理器命令。

## 安全打开链接（open-safe，macOS）

邮件里的验证链接、Magic Link、来路不明的登录链接，可以用一次性隔离浏览器打开：

```bash
~/.local/bin/claude-switch.sh open-safe "https://example.com/magic-link?token=..."
```

- 使用独立临时 Chrome/Chromium/Edge/Brave profile：**不继承日常浏览器的 cookies、历史、插件和登录态**
- 强制 `disable_non_proxied_udp`（WebRTC 不走非代理 UDP），语言跟随当前锁定地区
- 打开前检查代理/TUN 是否就绪，未就绪直接拒绝，避免裸连
- 只接受 `http/https`；窗口关闭后临时 profile 自动销毁
- **注意**：该窗口里的登录会话会随窗口关闭一起丢弃；如果链接需要保留登录，请在确认可信后改用日常浏览器

## 账号快照加密导出（macOS）

换机、重装系统或防灾难时，可以把已保存的账号快照导出为 **AES-256 加密镜像**，在另一台 Mac 上导入：

```bash
# 导出账号 A(先切换到 B,让 A 完成归档)
~/.local/bin/claude-switch.sh snapshot-export A ~/Desktop/account-a.dmg

# 在另一台 Mac 导入(目标槽位必须为空)
~/.local/bin/claude-switch.sh snapshot-import ~/Desktop/account-a.dmg A
```

- 密码至少 8 位，交互输入两次；脚本内通过 stdin 传给 `hdiutil`，不进入命令行参数或日志
- 镜像根目录带格式标记，导入时会校验格式与账号槽位；账号不匹配、密码错误、槽位已存在都会拒绝，不会覆盖现有快照
- **密码无法找回**：忘记密码等于镜像作废，请自行保存在密码管理器里
- 导入的是本地登录态快照；若服务端会话已过期或被撤销，仍需重新登录
- 仅 macOS（依赖系统 `hdiutil`）；导出/导入不会修改当前账号，也不会启动或关闭 Claude

## 已有代理的独立诊断（macOS CLI）

已有 HTTP/SOCKS 入口、由其他工具管理账号时，可以先单独检查 Claude 的网络传输，无需运行安装器或启动 Claude：

```bash
bash core/claude-switch.sh diagnose-proxy --proxy http://127.0.0.1:18080
# 已安装版本:
~/.local/bin/claude-switch.sh diagnose-proxy --config /path/to/private-proxy.json
```

私有配置文件只需包含 `{"proxy_url":"http://127.0.0.1:18080"}`。也可明确设置 `CLAUDE_SWITCHER_PROXY_URL`；命令行/配置文件优先于该变量。需要代理认证时优先使用私有配置或变量，避免凭据出现在本命令的参数中。支持 `http`、`https`、`socks5`、`socks5h`，地址必须包含端口；不会自动扫描代理或回退直连。

命令只向固定的 Claude 网页/API 地址发送无账号认证的请求，输出 JSON，不读取账号存档、不创建状态目录、不更改系统设置、不启动/关闭应用。代理地址和凭据不进入报告；代理凭据通过 curl 标准输入传递。它随现有核心脚本分发和更新，无需额外服务。

- 退出码 `0`：两个目标均收到经过 TLS 验证的 HTTP 响应。API 的 `401` 单独标为 `unauthenticated`，网页的 `403` 标为 `access_restricted`，均不等于账号或业务可用。
- 退出码 `1`：至少一项传输失败、超时或输出异常；未完成的检查保持未知。
- 退出码 `2`：代理或参数配置无效。普通 `HTTP_PROXY` / `NO_PROXY` 等继承值不会代替明确选择的入口。

该命令仅诊断上述官方域名的传输，不验证自定义 API Base URL/第三方供应商、DNS/WebRTC/IPv6 泄漏，不产生启动许可，也不绕过或修改原有的 TUN 启动审计。可用 `CLAUDE_SWITCHER_PYTHON` 选择已有 Python 解释器；默认 `python3`。

隔离回归测试（不连接真实代理或账号）：`python3 -m unittest discover -s tests -v`。

## 使用卫生与被封急救

### WebRTC 泄漏与国内直连规则

常见现象：TUN 正常、出口 IP 正确，但 WebRTC 检测失败，提示暴露了国内 IP。根因通常不是隧道坏了，而是规则集把 `stun.miwifi.com` / `stun.chat.bilibili.com` 这类国内 STUN 域名判为 **DIRECT 直连**——STUN 走的是 UDP，直连规则让它绕过了隧道。

Clash Verge 模式下，运行「一键修复」会把本项目规则写入**全局扩展脚本** `profiles/Script.js`，直接前置到 `config.rules`。已有的 `main(config, profileName)` 会先执行；随后加入 Claude 生态域名规则和 UDP `3478 / 5349 / 19302` 三个常见 STUN/TURN 端口规则。仅迁移旧 `Merge.yaml` 中本项目标记块，其他内容保留，改动前生成 `.bak.*` 备份。

两种策略：

| 策略 | 行为 | 使用场景 |
|---|---|---|
| `proxy`（默认） | 这些 UDP 请求走安装时选定的实际代理组；当前节点必须支持 UDP | 希望保留 WebRTC 通话能力 |
| `reject` | 拒绝这三个端口的 UDP，Claude 生态域名仍走代理组 | 接受部分语音、视频会议和 P2P 受影响 |

在 macOS 终端中切换策略并执行修复：

```bash
WEBRTC_POLICY=reject ~/.local/bin/claude-switch.sh fix
# 恢复默认代理策略
WEBRTC_POLICY=proxy ~/.local/bin/claude-switch.sh fix
```

策略在成功写入后保存到 `~/.claude-switcher/webrtc-policy`，后续 GUI、检查和修复会沿用。**一键修复会重启 Clash Verge**。代理组不存在、当前节点是 DIRECT、节点不支持 UDP、全局脚本未启用、控制接口不可用或内核未加载置顶规则时，都不会显示规则修复成功。节点不支持 UDP 时请换节点或主动选择 `reject`；Mihomo 可能继续向下匹配规则，`proxy` 策略不能保证阻止这种回落。

检查读取本机 Mihomo 的 `/configs`、`/proxies`、`/rules`，核对 rule 模式、代理组及实际规则的顺序、目标和启用状态；不再把文件中的文字或 fake-IP 解析当成规则生效。**全局模式（Global）视为合规**：该模式不经过规则匹配、全部流量已走代理，检查会标注「全局模式(全部流量走代理)」，无需写入 Script.js；规则置顶与 WebRTC 端口策略仅在 rule 模式下生效。控制接口连接优先使用配置中的 Unix socket，失效时回退到服务实际使用的 `/var/run/clash-verge-service/users/<uid>/verge-mihomo.sock`。**STUN 无响应不等于没有泄漏**：默认策略会报告未验证；仅在已验证拒绝规则的 `reject` 策略下，才把探测无响应解释为该端口策略的预期结果。

首次从旧版迁移：请退出 Claude 后，使用最新版仓库的安装器重新安装，再检查结果。旧版 `update` 保留“新版自检失败即回滚”的行为，旧规则未迁移时可能回滚；不要为更新成功而跳过检查。安装器若提示缺少可组合的 `main`，请先备份并在 Clash Verge 的全局扩展脚本中整理现有代码，再重试。其他代理客户端的配置仍由用户自行管理。

这些规则仅覆盖三个常见 UDP 端口，无法覆盖自定义端口、所有 TURN 传输或所有应用的泄漏路径。浏览器插件的作用也限于该浏览器。修复后仍需查看检查结果；不要把一次检测通过视为全系统防泄漏保证。

工具能兜底技术泄漏，兜不住主动作死。以下每条都是社区里用账号堆出来的教训：

- **先退出 Claude，再断/换代理**。断线重连的那几秒是全年最高危时刻——保镖会兜底杀进程，但正确姿势永远是先退客户端再动网络，不要反过来挑战物理
- **不要把订阅账号接入任何第三方工具/中转站/拼车服务**（2026 年头号封号诱因，没有之一）。你的会话凭证经过谁的机器，谁就拥有你的账号
- **支付卡段、账单地址尽量与出口国家一致**。美国出口配国内双币卡 + 北京账单地址，等于在风控表格里自己填了"我是跨区用户"
- **新账号前几天不要拉满高档位用量**。注册即跑满额度的行为序列，是批量养号工作室的指纹，正常用户不长这样
- **真被封了**：先用被封账号登录 [claude.ai/restricted](https://claude.ai/restricted) 提交申诉（社区历史成功率约十分之一，值得一试）；申诉前先在封号提示页导出你的数据；**不要立刻用同一台机器、同一张卡、同一个邮箱再注册新号**——绕过封禁本身违反条款，而且关联指纹会让新号活得比旧号还短

## 项目结构

```
├── app/main.swift          # SwiftUI 界面(单文件)
├── core/
│   ├── claude-switch.sh    # 核心逻辑:审计/切换/修复
│   └── stun-probe.py       # STUN 探针(手工协议实现)
├── windows/                # Windows x64 原生版(PowerShell 核心 + WPF 界面, Development Beta)
├── linux/                  # Linux 版(bash 核心 + systemd 保镖 + 终端菜单, Beta)
├── docs/                   # Web 版环境检测页(index.html 等, GitHub Pages 从这里发布) + 项目文档
├── daemons/                # Kill-Switch / Watchdog / 自动更新 launchd 模板
├── installer/              # 双击安装/卸载
├── scripts/gen-sums.sh     # 重新生成 SHA256SUMS(改动 core/daemons/installer 后必跑)
├── SHA256SUMS              # 发布工件完整性校验清单(自动更新逐项比对)
└── assets/                 # 程序生成图标
```

## 二改指南

- **改界面**：编辑 `app/main.swift`，`swiftc -O -parse-as-library` 重编译即可
- **加检查项**：`core/claude-switch.sh` 的 `checkdetail()` + UI 的 `keyMap` 各加一行
- **改防护策略**：`daemons/` 里的模板即全部守护逻辑

欢迎 Fork / PR。Issue 区接受场景补充——你遇到的每一个真实泄漏场景，都可能成为下一个检查项。

## 微信交流群

欢迎加入 **claude-switcher 交流群**，交流安装配置、使用心得和问题排查。使用微信扫描下方二维码即可入群：

![claude-switcher 微信交流群二维码](assets/wechat-group.png)

> 当前二维码标注 **2026 年 11 月 2 日前有效**。若二维码过期或无法入群，请通过 [Issue](https://github.com/YOURSJEYO/claude-switcher/issues) 提醒维护者更新。

Bug 反馈和功能建议仍建议提交 Issue，便于跟踪与处理。

## 问题反馈

- 提交 [Issue](https://github.com/YOURSJEYO/claude-switcher/issues)
- 在 [Linux.do](https://linux.do) 论坛发帖讨论
- **安全问题请走非公开渠道**：见 [SECURITY.md](SECURITY.md)（GitHub Private Vulnerability Reporting 优先）

反馈掉登录、弹盾类问题时，请附上「应用设置 → 日志」导出的日志，里面不含密码和 Cookie 原文；如果可以，也请附上可复现步骤。

## 路线图

本项目按"实战驱动"迭代——风控怎么进化，防护就怎么跟上：

- [x] macOS 版：14 项环境审计 + Kill-Switch + 快照切换 + 漂移自愈（已稳定）
- [x] Windows 版（Development Beta）：PowerShell 核心、WPF/Admin 源码、受控安装流程、Inno 模板和发布/打包自动化已接入
- [x] Linux 版（Beta）：bash 核心 + systemd 保镖 + 终端菜单
- [ ] Windows 版稳定化：在本机成功编译 Setup EXE，并完成安装器执行/UAC/升级/卸载与数据保留验证，再通过 Windows 11/Windows 10 签名 VM acceptance；托管 CI 不替代真机验收
- [ ] Linux 版稳定化：多客户端/地区自适应/COW 快照已落地（桩测试通过），多发行版真机回归持续进行
- [x] Web 版环境检测页：手机/平板浏览器打开即测，零安装
- [x] 更多指纹维度：桌面端 `fingerprint` 命令覆盖字体地区特征 + GPU/虚拟机特征，Canvas/WebGL 由 Web 检测页覆盖
- [x] 更多代理客户端适配：已支持 Clash Verge / Shadowrocket / sing-box / ClashX / Surge（含 auto 自动识别）
- [x] 快照切换提速：归档改为同卷移动 + 载入走 COW 克隆（APFS clonefile / Linux reflink），不再产生全量复制
- [x] 应用内自动更新：launchd 每 12 小时自动检查更新，自检失败自动回滚，也可手动 `claude-switch.sh update` 保底

> 有想优先看到的功能，去 [Issues](https://github.com/YOURSJEYO/claude-switcher/issues) 投票或提需求，热度高的先做。

## 帮忙吆喝一声

如果这个工具让你少被封了一个号，希望有条件的佬哥能帮我们在 [Linux.do](https://linux.do) 论坛发个帖子推荐一下——仓库地址 <https://github.com/YOURSJEYO/claude-switcher>，一句话定位：**"Claude 账号的 Fail-Closed 环境保护罩：14 项环境审计不过就物理上不让启动"**。让更多被风控折磨的兄弟少走弯路。

## Star History

<a href="https://www.star-history.com/?repos=yoursjeyo%2Fclaude-switcher&type=timeline&legend=bottom-right">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=yoursjeyo/claude-switcher&type=timeline&theme=dark&legend=bottom-right" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=yoursjeyo/claude-switcher&type=timeline&legend=bottom-right" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=yoursjeyo/claude-switcher&type=timeline&legend=bottom-right" />
 </picture>
</a>

## License

MIT © Claude Switcher Contributors
