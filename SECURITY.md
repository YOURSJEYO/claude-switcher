# SECURITY.md —— 安全策略

## 支持版本

仅支持 `main` 分支最新代码。自动更新机制（`claude-switch.sh update` / 每 12 小时 LaunchAgent）会持续把已安装版本对齐到 main，请保持该机制启用。

## 漏洞通报

- **首选**：GitHub Private Vulnerability Reporting（仓库 → Security 页 → "Report a vulnerability"），非公开渠道，我们会在修复发布前保密处理
- 不便使用上述渠道时：开 Discussion 或 Issue（**请不要在公开内容里附带可利用细节、你的出口 IP 或任何凭据**）

## 安全边界（诚实声明）

本项目把"防到什么程度"写在明处，不夸大：

- **Kill-Switch 是进程级急停，不是防火墙级 fail-closed**。保镖以 10 秒周期巡检"内核进程 × TUN 网卡"双因子，从隧道断开到进程被杀存在已知时间窗口（TOCTOU）；窗口内恰好发出的数据包不在防护范围内。急停范围覆盖桌面版 Claude 与安装用户的 Claude Code CLI 进程（native `claude`/`claude.exe` 及 npm/bun 的 `@anthropic-ai/claude-code`），仅按安装用户与进程签名匹配，不按名字扫全系统；进程级边界与 TOCTOU 窗口不因扩展覆盖范围而改变。未来版本评估引入 pf 防火墙锚点做网络级 fail-closed
- **CLI 账号联动的保证边界以 `claude-switch.sh cli` 为界**。切换器按官方 `CLAUDE_CONFIG_DIR` 机制把 CLI 隔离到当前桌面账号的目录（A 用既有 `~/.claude`，B–D 用 `~/.claude-switcher/cli-accounts/<槽位>`，0700），并拒绝认证环境变量覆盖与冲突的 `CLAUDE_CONFIG_DIR`；但直接运行原始 `claude` 完全绕过这些防线，无法保证与桌面账号一致。macOS 钥匙串条目由 CLI 按配置目录自行隔离，本项目不读取、导出或改写钥匙串内容，也不把 CLI 配置目录纳入加密桌面快照
- **自动更新的信任根是 GitHub 仓库本身**。每次更新前会对照仓库根的 `SHA256SUMS` 逐项校验 zip 工件（core 脚本 + daemons 模板 + installer），可防传输层篡改/中间人换包；但如果仓库账号本身被攻陷，校验清单和工件会同时被替换——这是目前的信任边界。维护侧的发布纪律：`core/`、`daemons/`、`installer/` 任何改动提交前必须运行 `scripts/gen-sums.sh` 重新生成 SHA256SUMS，二者永远同提交
- **守护进程脚本 root 所有、用户态不可写**。保镖与时区看门狗安装在 `/Library/Application Support/claude-switcher/`（root:wheel, 755），launchd 以 root 执行这些脚本，普通用户进程无法篡改其内容——本地权限提升面已收敛
- **自动更新运行在用户态**（LaunchAgent），不再持有 root；需要 root 的守护脚本变更只提示用户运行安装器，绝不自动写系统目录

## 安全变更记录

### 2026-11-01（CLI 多账号联动边界）

1. **保镖急停范围扩展**：代理离线时除桌面版外，同时终止安装用户的 Claude Code CLI 进程（native `claude`/`claude.exe` 及 npm/bun 的 `@anthropic-ai/claude-code`）；进程匹配仍限定安装用户，不按名字扫全系统
2. **新增 `cli` 启动防线**：按桌面当前账号映射 `CLAUDE_CONFIG_DIR`，拒绝认证环境变量覆盖、冲突的 `CLAUDE_CONFIG_DIR`、审计失败与审计期间账号变化；同步诚实声明直接运行原始 `claude` 不在联动保证范围内

### 2026-10-21（三项外部审查发现修复）

1. **本地权限提升修复**：launchd 系统服务原来以 root 执行 `~/.local/bin/` 下用户可写的脚本，任何能写该目录的进程都可提权。现守护脚本移入 root 所有的 `/Library/Application Support/claude-switcher/`，用户目录只保留 plist 副本
2. **供应链加固**：自动更新从 root 级 LaunchDaemon 改为用户态 LaunchAgent；新增 zip 工件逐项 SHA256 校验（对照仓库 `SHA256SUMS`），任一文件不匹配即中止
3. **Merge.yaml 覆盖修复**：安装器/一键修复原来 `cat >` 整文件覆盖 Clash Verge 全局扩展配置，会丢失用户已有配置。现改为带标记块的智能合并（幂等替换、保留用户规则、改前自动备份）；代理组探测到多个 select 组时改为让用户选择，不再静默取第一个
