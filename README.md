<div align="center">

# Claude 切换器

**Fail-Closed 账号环境管理器 —— 让真实 IP 在物理上无法泄漏**

> 🛠️ **本项目持续活跃更新中**——防护项随目标平台风控演进不断增加，见下方[路线图](#路线图)。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)]()
[![Windows](https://img.shields.io/badge/Windows-Beta-lightgrey.svg)](windows/)
[![Linux](https://img.shields.io/badge/Linux-Beta-lightgrey.svg)](linux/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-orange.svg)]()
[![Dependencies](https://img.shields.io/badge/Dependencies-Zero-brightgreen.svg)]()

<img src="assets/icon-2048.png" width="128">

</div>

---

## 为什么做这个

AI 服务平台的风控已经从"看 IP"进化到**全维度环境画像**：时区、Locale、DNS 出口、WebRTC 候选地址、设备指纹、行为时序。绝大多数封号不是因为你做错了什么，而是某个你没意识到的场景里，真实出口 IP 悄悄溜出去了一次——哪怕只是一个 TCP SYN 握手包。

本项目的立场：**防御不建立在"用户记得"上，而建立在系统级的硬性物理约束上**。

> 哪怕代理暴毙、哪怕软件静默升级、哪怕随手乱点，也绝对发不出一次直连请求。

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
| 11 | 路由覆盖 | Claude 全家族域名是否真的命中了代理规则（详见第 6 节） |
| 12 | 客户端语言 | 防止 JS 层 `navigator.language` / `Intl` 读出系统中文 |
| 13 | ASN 属性 | 住宅宽带 vs 机房 IP（Residential vs Datacenter） |
| 14 | 生态可达性 | claude.ai / api.anthropic.com 连通性验证 |

### 2. 纯标准库手写 STUN 协议栈的 WebRTC 泄漏探针

不依赖浏览器内核（headless Chrome 的 ICE 子系统在无人值守场景下根本不工作——我们踩过这个坑），直接用 `socket` + `struct` 手工构造 RFC 5389 Binding Request，解析 XOR-MAPPED-ADDRESS。

真正的创新在**交叉验证拓扑**：探测列表同时包含全球节点（Google/Cloudflare）与国内骨干节点——走隧道时应回传代理出口 IP，裸连时国内节点必然秒回并当场抓获真实 IP。两种状态可区分、零误报、不依赖"恰好不通"。

### 3. Fail-Closed Kill-Switch

常驻守护进程以 10s 周期巡检隧道健康度（内核进程 × 虚拟网卡双因子），隧道中断即刻终止受保护进程。区别于客户端自带的 Fail-Open 容错重试——那种机制会把含真实 IP 的握手包送到对方网关日志里，哪怕最终"超时失败"。

### 4. Session Snapshot 快照隔离

多账号不是"登出再登入"（那会产生大量认证事件与指纹抖动），而是**物理交换数据卷**：每个账号持有独立的 Device Fingerprint、OAuth Credential 与本地状态，切换时原子化封存/载入。对服务端而言，每个账号看到的都是一台恒定不变的设备。

### 5. 配置漂移自愈（Watchdog）

软件更新会静默重置你的安全配置（我们的生产环境里，TUN 开关被代理客户端更新重置了 4 次，系统时区被改回 8 次）。Watchdog 周期巡检 + 基线回滚 + 全程留痕，配置漂移从"事故"降级为"日志里的一行记录"。

### 6. Route Coverage 路由覆盖

不读配置文件、只验行为：Claude 全家族域名（claude.ai / api.anthropic.com / claudeusercontent.com）必须解析到 Shadowrocket 的 Fake-IP。拿到 Fake-IP 就证明命中代理规则；拿到真实 IP 就判定路由未覆盖。配置文本可以撒谎，DNS 结果不会。

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

**系统要求**：macOS · [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118)（VPN 已连接、TUN/Fake-IP 生效）· Claude 桌面版 · python3 · Xcode 命令行工具（编译界面）

> **macOS 版已适配 Shadowrocket**：安装器不再依赖 Clash Verge，也不会改写代理配置（Windows / Linux 目录仍基于 Clash Verge）。
> **Windows 用户**：[`windows/`](windows/) 目录提供 Windows 版（PowerShell + WPF，Beta），安装与注意事项见 [windows/README.md](windows/README.md)。
> **Linux 用户**：[`linux/`](linux/) 目录提供 Linux 版（bash + systemd，Beta），设计取舍（无官方桌面版→切换浏览器登录态）见 [linux/README.md](linux/README.md)。

```bash
# 克隆后双击 installer/安装.command 即可,自动识别时区并现场编译界面
git clone https://github.com/YOURSJEYO/claude-switcher.git
```

## 不会配置？交给你的 AI

仓库根目录的 [`AGENTS.md`](AGENTS.md) 是一份完整的 **Agent 交接提示词**：把它直接粘贴给你的本地模型（Kimi Code / Cursor / Claude Code 等），它会按文档自动完成环境检查、安装、配置与验收。里面还附了我们实战踩过的全部坑的排障手册。

## 使用

1. 双击桌面「Claude切换器」→ 等待 14 项检查
2. 全绿 → 选账号启动；有红项 → 「一键修复」自动处理
3. B 账号首次使用登录一次，以后 A/B 随切随用、互不干扰

## 项目结构

```
├── app/main.swift          # SwiftUI 界面(单文件)
├── core/
│   ├── claude-switch.sh    # 核心逻辑:审计/切换/修复
│   └── stun-probe.py       # STUN 探针(手工协议实现)
├── windows/                # Windows 版(PowerShell 核心 + WPF 界面, Beta)
├── linux/                  # Linux 版(bash 核心 + systemd 保镖 + 终端菜单, Beta)
├── daemons/                # Kill-Switch / Watchdog 模板
├── installer/              # 双击安装/卸载
└── assets/                 # 程序生成图标
```

## 二改指南

- **改界面**：编辑 `app/main.swift`，`swiftc -O -parse-as-library` 重编译即可
- **加检查项**：`core/claude-switch.sh` 的 `checkdetail()` + UI 的 `keyMap` 各加一行
- **改防护策略**：`daemons/` 里的模板即全部守护逻辑

欢迎 Fork / PR。Issue 区接受场景补充——你遇到的每一个真实泄漏场景，都可能成为下一个检查项。

## 问题反馈

- 提交 [Issue](https://github.com/YOURSJEYO/claude-switcher/issues)
- 在 [Linux.do](https://linux.do) 论坛发帖讨论

反馈掉登录、弹盾类问题时，请附上「应用设置 → 日志」导出的日志，里面不含密码和 Cookie 原文；如果可以，也请附上可复现步骤。

## 路线图

本项目按"实战驱动"迭代——风控怎么进化，防护就怎么跟上：

- [x] macOS 版：14 项环境审计 + Kill-Switch + 快照切换 + 漂移自愈（已稳定）
- [x] Windows 版（Beta）：核心逻辑全移植
- [x] Linux 版（Beta）：bash 核心 + systemd 保镖 + 终端菜单
- [ ] Windows 版稳定化：真机测试迭代，收敛 Beta
- [ ] Linux 版稳定化：多发行版实测迭代
- [ ] Web 版环境检测页：手机/平板浏览器打开即测，零安装
- [ ] 更多指纹维度：字体地区特征、Canvas/WebGL 渲染特征
- [ ] 更多代理客户端适配：Clash Verge / Surge / sing-box / ClashX
- [ ] 快照切换提速：增量归档（只写差量）
- [ ] 应用内自动更新

> 有想优先看到的功能，去 [Issues](https://github.com/YOURSJEYO/claude-switcher/issues) 投票或提需求，热度高的先做。

## License

MIT © Claude Switcher Contributors
