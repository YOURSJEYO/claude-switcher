# Claude 切换器 · Windows 原生版 (Development Beta)

> ⚠️ **开发 Beta / 未签名 (unsigned)，当前没有 Windows release readiness**：源码已包含原生 WPF 应用、受保护 helper、Inno Setup 模板、受控 Preview/Apply 安装流程、原生 SetupClient/协议以及 Windows CI 打包定义。但本机没有 ISCC，**no successful local Setup EXE compile**；也没有安装器执行、UAC、Windows 10/11 VM acceptance 证据。托管 CI workflow 已定义，但 hosted CI 不是 Windows 10/11 acceptance，本文也不声称已有成功的 hosted run。

**证据边界：** no successful local Setup EXE compile；no successful hosted run is claimed；no installer execution, UAC, upgrade/uninstall, Windows 10/11 VM acceptance；no Windows release readiness。

## 当前源码状态

- `ClaudeSwitcher.exe` 是 **self-contained WPF apphost**，发布时旁边还有 .NET/runtime 等文件（`PublishSingleFile=false`）。它不是 portable single-file executable，也不是 Setup EXE。
- `ClaudeSwitcher-<version>-windows-setup.exe` 是 Inno Setup 的 Setup EXE 输出名。`windows/ClaudeSwitcher.iss` 已存在，`scripts/package-windows.ps1` 已定义使用 Inno Setup 6.7.3 的编译流程；本机没有 ISCC，尚未成功产出 Setup EXE。
- `windows/helpers/UserSetup.ps1` 已存在。`windows/install.ps1` 已实现受控的 Preview/Apply 接口，包括 `-NonInteractive`、`-ProxyMode`、`-ProxyGroup`、`-Country`、`-TimeZoneId`、`-Culture`、`-Preview`、`-Json`、`-Initialize`、`-RemoveUserTask` 和 `-RequireNoOtherTasks`。
- 原生应用侧已有 `SetupClient` 和 setup protocol 代码，用于调用预览/应用流程并校验结构化结果；源码存在不等于安装器已经在 Windows VM 中通过验收。
- `ClaudeSwitcher-<version>-windows.zip` 仅用于兼容 UI/CLI。The ZIP does not install the protected helper and does not contain the protected Admin helper executable (`ClaudeSwitcher.Admin.exe`). It provides no full install or system-repair parity. Protected system changes require native setup or a separately documented, auditable administrator procedure. Never run user-writable scripts elevated.
- 原生配置以 `%USERPROFILE%\.claude-switcher\config.json` 的 schemaVersion 1 JSON 保存 `proxyMode` / `proxyGroup` / `country` / `timeZoneId` / `culture`；核心只把它当数据读取，不 dot-source。旧安装没有该文件时保留 `proxy-mode.txt` / 脚本头部配置的 legacy 路径。
- `.github/workflows/checks.yml` 已定义 Windows x64 构建、测试和打包检查；`.github/workflows/release.yml` 已定义受保护发布门槛。两者都不替代 Windows 10/11 VM acceptance。

## 运行时与系统支持

- **运行时**：App 与 Admin 均配置为 **.NET 10 self-contained**、`win-x64` 发布，因此目标机不需要单独安装 .NET Desktop Runtime；该发布路径仍需安装验收。
- **Windows 11 x64**：主要开发目标；安装、UAC、升级/卸载和普通用户启动仍需独立 VM 验收。
- **Windows 10 22H2 x64**：兼容性待单独 VM 验收；在报告通过前不声明支持。
- **Windows ARM64**：当前不支持。
- **PowerShell**：核心兼容 Windows PowerShell 5.1；开发和 CI 同时覆盖 PowerShell 7。
- **代理客户端**：需要支持 TUN。安装器会按配置目录、进程或服务识别 Clash Verge、sing-box、ClashX、Surge、WireGuard；也可选择 `other` / `auto`。Shadowrocket 仅 macOS 可用。
- **Claude 桌面版 Windows** 与支持 TUN 的代理客户端仍是运行前置条件。
- **管理员权限**：受保护的原生安装/系统配置需要一次管理员授权；脚本兼容包不能替代这一步。

> **VM acceptance boundary:** VM acceptance must be executed externally on disposable Windows 11 and Windows 10 VMs; hosted CI is not Windows 10/11 acceptance and must preserve the exact commit, version, and installer-hash evidence.

> **尚未执行的验收要求：** A SID-scoped task must be running, and a fresh heartbeat must match the expected user SID/session. 该条件目前只是待验证要求，不是现有证据。

## 安装与配置入口（源码已定义，尚未验收）

- **首选路径是原生 Inno Setup 安装包**：先开启 TUN，再安装程序文件并由普通用户会话完成配置。原生 Preview 通过 ipinfo → ipapi → ifconfig → Cloudflare trace 多源探测出口地区；任一有效来源为 `CN`、来源国家冲突或地区不支持时拒绝配置。时区无效时继续选取同一国家的有效来源；所有源都失败时直接报错，不使用 `FORCE`、也不会默认成 US。
- 本机没有 ISCC，**尚未成功编译 Setup EXE**；安装器执行、UAC、升级/卸载、数据保留和 Windows 10/11 VM acceptance 均没有证据，因此当前没有可直接宣称已完成的原生安装路径。
- `windows/install.ps1` 提供受控的 Preview/Apply 接口，包括 `-NonInteractive`、`-ProxyMode`、`-ProxyGroup`、`-Country`、`-TimeZoneId`、`-Culture`、`-Preview`、`-Json`、`-Initialize`、`-RemoveUserTask` 和 `-RequireNoOtherTasks`。配置流程先只读 Preview，再进入 Apply；不接受任意命令或脚本。
- `ClaudeSwitcher-<version>-windows.zip` 是脚本兼容包，不是原生安装器。它不包含受保护的 Admin helper，也不安装受保护 helper；其 `install.ps1` 在缺少原生受保护载荷时会以 `protected_payload_required` 拒绝 Apply，不能提供完整安装或系统修复等价能力。**不要以管理员权限运行用户可写脚本。**
- 原生安装写入 `%USERPROFILE%\.claude-switcher\config.json` 的 schemaVersion 1 JSON，保存 `proxyMode` / `proxyGroup` / `country` / `timeZoneId` / `culture`。核心把它当数据读取，不 dot-source；旧安装没有该文件时保留 `proxy-mode.txt` 或脚本头部配置的 legacy 路径。
- **以前装过脚本版**：旧核心的 `status` 仍可能输出 `current=... hasA=... hasB=...` 文本，不支持原生界面的 JSON 协议。原生界面会提示旧版脚本核心需要配置，并只开放“配置安装”；点击后先预览，再确认应用配置，由安装包自带的受保护模板更新用户核心。识别旧核心本身不会自动覆盖脚本或删除账号快照、恢复材料，也不会继续执行旧版检查、修复或账号切换。如果使用较早的测试包看到 `Core output is not one valid JSON document.`，同样先点击“配置安装”，不要删除整个 `.claude-switcher` 目录。
- 若在已具备受保护载荷的受控环境中运行兼容入口并遇到执行策略限制，可仅对当前用户执行 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`；这不会把脚本兼容包变成原生安装器。

## 更新（仅限兼容脚本包）

以下能力只属于 PowerShell 脚本兼容包；**原生 WPF 应用没有更新按钮，原生应用升级尚未完成，也没有 VM 验收证据**。

- **只读检查**：`check-update` 对 legacy 安装查询 GitHub 最新 Release 并报告版本/资产状态，不下载、不备份、不写入；原生安装直接返回 `unsupported` 与原生升级指引，兼容界面也不再显示一键更新按钮。
- **启动自动检查**：兼容界面启动后后台调用 `check-update`，不阻塞界面；24 小时缓存命中时直接复用提示条，避免重复打扰。
- **一键更新仅限 legacy 脚本安装**：`update-now` 在检测到原生 `config.json` 时返回 `unsupported`，非法 `config.json` 会拒绝执行；只有 legacy 脚本路径才继续更新，并需持有核心 `operation.lock`。存在待恢复账号资料或事务残留时拒绝更新。
- **校验与回滚**：下载 Windows ZIP 与 `SHA256SUMS-release.txt`，SHA256 校验通过后才替换 `%USERPROFILE%\.claude-switcher` 下的 `claude-switch.ps1` / `claude-bodyguard.ps1` / `SwitcherUI.ps1`；更新前保留旧脚本配置行并备份，失败自动回滚。
- **更新边界**：更新不会替换原生 WPF/Admin、受保护 helper、Inno Setup 或系统任务，也不会绕过原生升级限制；脚本更新不弹 UAC，但不能把脚本更新视为原生应用升级。
- **稍后与手动检查**：点「稍后」会隐藏提示条，24 小时内不再自动提示；底部「检查更新」会清除缓存并立即检查一次。版本号来自 ZIP 根目录的 `VERSION`，安装后保存在 `%USERPROFILE%\.claude-switcher\version.txt`。
- **验证状态**：该脚本更新流程尚未经过 Windows 真机验收，遇到问题请到 Issues 反馈。

## 多代理客户端支持

| 客户端 | `$PROXY_MODE` | 存活判定 | 说明 |
|---|---|---|---|
| Clash Verge | `clash-verge` | `verge-mihomo` 进程 + TUN | 按 Clash 模式自动配置规则（全局/直连跳过） |
| sing-box | `sing-box` | `sing-box` 进程 + TUN | 置顶规则需自行配置 |
| ClashX | `clashx` | `ClashX` 进程 + TUN | 置顶规则需自行配置 |
| Surge | `surge` | `Surge` 进程 + TUN | 置顶规则需自行配置 |
| WireGuard | `wireguard` | `WireGuardTunnel*` 服务 + TUN | 置顶规则需自行配置 |
| 其他 TUN 客户端 | `other` | 仅 TUN | 不要求特定进程，避免误杀 |
| 自动 | `auto` | 任一已知进程/服务 + TUN | 保镖在 `auto` 下同样只查 TUN |

TUN 判定顺序：先看是否存在 `198.18.x.x` 假 IP（Clash 系 fake-ip）；没有则回退到任意处于 `Up` 状态、描述匹配 `TAP/TUN/WireGuard/Wintun/VPN/Tailscale` 的虚拟网卡。198.18 命中时保持原来的 `TUN网卡=ok`；回退命中时显示 `TUN网卡=ok:通用虚拟网卡`。

## 安装、UAC 与身份边界（源码已定义，尚未验收）

1. 原生 Setup 源码要求管理员权限安装程序文件；安装后的配置入口以 `runasoriginaluser` 启动，避免把日常 Claude 进程提升为管理员。
2. 配置流程先执行只读 Preview，再进入 Apply；用户配置、受保护 helper 调用和系统修复应使用受控参数，不接受任意命令或脚本。
3. UAC 取消、部分 helper 失败、重复入口和从已提升终端启动时的原始用户识别，都必须在 VM 中验证安全失败、可重试且不误写其他用户状态。
4. 用户配置和账号快照应绑定发起安装的普通用户；**Claude 和应用本身必须以普通用户身份运行**，不要从管理员终端启动日常使用。
5. 安装包仍为**未签名**，Windows SmartScreen 可能显示“Windows 已保护你的电脑”。产物可发布后，请先核对下载来源和 `SHA256SUMS-release.txt`，确认无误再选择“更多信息 → 仍要运行”。

## Clash 规则与全局模式

「一键修复」会先识别 Clash 当前模式（Mihomo API `/configs`，失败再读 `clash-verge.yaml` / `verge.yaml` 的 `mode:`），再决定是否动规则：

- **全局 / 直连模式**：规则本来就不生效，修复不写 `Merge.yaml`，也不写 `Script.js`；只有发现旧版遗留的 Merge 规则时才清理并重启一次 Clash。没有遗留时不改动任何配置。
- **规则模式**：只写 `profiles\Script.js` 的托管块（`// >>> claude-switcher managed rules >>>`），不再写 `Merge.yaml`。写入前备份，重启后通过内核 `/rules` 验证前 16 条规则；验证失败会自动从备份回滚 `Script.js`。规则模式需要在 Clash Verge 中启用「全局扩展脚本」，否则验证会失败并回滚。
- **无法识别模式**：跳过规则修改，避免误伤。
- 安装器不再写任何规则；安装完成后请打开切换器点一次「一键修复」完成配置。

旧版切换器写进 `Merge.yaml` 的 `prepend-rules`、单独成行的 `---` 和重复顶层键会被自动备份并清理，不会再写回。全局模式下如果 TUN 已经被旧配置破坏，清理后的那次重启通常即可恢复。

检查列表的「规则置顶」会同步显示 `ok` / `warn` / `fail`；修复失败时，界面 Banner 显示核心返回的可信、脱敏错误。完整的模式/清理诊断可通过 CLI 的 `fix` 查看。

## 与 macOS 版的差异（注意事项）

> macOS 版支持 Clash Verge / Shadowrocket / sing-box / ClashX / Surge 与地区自适应（按出口国家自动锁定时区+地区格式，换节点后 `set-region` 一键重配）。Windows 版已对齐多客户端检测，但 **Shadowrocket 仅 macOS 可用**；原生 `config.json` 会按国家保存对应的 Windows 时区 ID 和 `culture`，旧版脚本头部仍可能保留 `en-US` 默认值。换国家后 Windows 版暂无 `set-region`，需要重新走原生 Preview/Apply；所有地区源失败时不会回退到 US，也不要使用旧文档中的 `FORCE` 流程冒充原生行为。macOS 的 `update` 命令与 12 小时自动检查、48 小时 IP 审查未移植到 Windows；Windows 只有兼容脚本包的 `check-update` / `update-now`，见上文「更新」。

| 项目 | 说明 |
|---|---|
| 时区名称 | Windows 用 `Eastern Standard Time` 这类 ID,安装器会自动把 IP 城市映射过去 |
| 保镖频率 | 计划任务登录启动,隐藏窗口常驻,每 10 秒巡检(与 Mac 一致) |
| 保镖判定 | 显式客户端模式按「客户端进程/服务 + TUN」；`auto` / `other` 只查 TUN |
| IPv6 | 关闭的是所有网卡的 ms_tcpip6 绑定;要恢复: `Enable-NetAdapterBinding -ComponentID ms_tcpip6` |
| SmartScreen | 首次运行可能弹"Windows 已保护你的电脑" → 点「更多信息」→「仍要运行」 |
| 账号数据目录 | Windows 版在 `%APPDATA%\Claude`(与 macOS 路径不同,逻辑相同) |
| 卸载 | 从普通桌面会话运行开始菜单中的 Uninstall Claude Switcher；默认保留配置、快照和 Claude 登录数据 |

## 升级、卸载与数据保留（尚未验收）

- 升级和卸载的验收要求是 **preserve** A/B 账号归档、地区/代理配置和其他用户数据。
- 源码已接入同一路径升级/修复：新 Setup 检测旧安装后启动普通用户 maintenance broker，持续持有 `operation.lock` 和租约；关闭 Claude 与切换器后移除通过归属校验的任务，在受保护的 `%ProgramFiles%\ClaudeSwitcher.maintenance` 中保存校验过的旧载荷，再替换程序、用户模板和版本文件并恢复原有任务。`config.json`、`accounts` 与 `%APPDATA%\Claude` 保持不变。失败时先恢复程序载荷，再恢复用户模板和任务。
- 卸载必须由普通用户入口启动：开始菜单 `Uninstall Claude Switcher` 或“已安装的应用”中的卸载入口。普通用户 broker 持锁，再启动提升后的 Inno 卸载器；默认保留 `%USERPROFILE%\.claude-switcher` 与 `%APPDATA%\Claude`。提示删除用户数据时选择 No 保留（默认）；Yes 后仍需再次确认，才会在用户权限下删除配置、全部快照和 Claude 登录数据。静默卸载始终保留数据。直接运行 `unins000.exe` 会拒绝并提示使用普通用户入口。
- 维护时 Claude 必须完全退出。其他用户的保镖任务、未迁移的 `ClaudeBodyguard`、账号恢复残留、已有 maintenance 备份或失效租约会阻止操作。中断时保留 `installer-maintenance.json`、租约和受保护备份；不要手动删除恢复材料来绕过阻断。卸载不会自动改回时区或 IPv6，避免覆盖用户后续更改。
- 以上升级/卸载实现仍需在 Windows 10/11 一次性 VM 中验证实际安装、UAC、回滚和数据保留；隔离回归与 CI 编译不等于 VM 验收。
- 旧测试包 `0.0.0-ci.40859485103.1` 可能在升级备份阶段提示 `A verified rollback copy could not be created`：注册表 ACL 校验误把 `WriteKey` 中共用的读取权限算作写权限，正常 `Users: ReadKey` 因而被拒绝。修复后的构建只检查实际修改权限，仍拒绝可写 ACL 和异常所有者。新提示会附带阶段码：`20` 注册表快照/ACL，`21` 备份目录，`22` 原文件哈希，`23` 文件复制，`24` 复制校验，`25` 备份记录。遇到错误先取消并保留资料，不要删除账号目录或未知恢复材料。

## 旧版保镖任务迁移

当前构建提供受限的 `ClaudeBodyguard` 自动迁移入口。核心只在旧任务通过固定契约校验后调用受保护 helper；helper 从目标 SID 的 ProfileList 解析用户目录，严格校验旧任务的 principal、触发器、设置、唯一 PowerShell 动作和用户脚本归属，先创建或验证 `ClaudeSwitcher.Bodyguard.<SID>`，成功后才停止并删除旧任务。无法确认归属、动作/脚本校验失败、迁移 helper 失败或删除失败时，旧任务不会被伪报为已迁移。

迁移不会执行旧脚本、导入旧配置或删除账号数据。该入口尚未在 Windows 10/11 真机或隔离 VM 完成验收，不能视为升级、卸载或 VM 验收已经完成。

## 从源码构建和测试

打包要求：

- .NET SDK **10.0.403**（`global.json` 固定版本并禁用 roll-forward）
- Inno Setup **6.7.3**（`ISCC.exe`）
- Windows PowerShell 5.1；PowerShell 7 用于额外测试
- Windows x64 构建主机

```powershell
# PowerShell 核心测试
pwsh -NoProfile -File windows/tests/Invoke-CoreTests.ps1

# WPF 与 Admin xUnit 测试；fresh clone 不传 --no-restore
dotnet test windows/ClaudeSwitcher.App.Tests/ClaudeSwitcher.App.Tests.csproj -c Release
dotnet test windows/ClaudeSwitcher.Admin.Tests/ClaudeSwitcher.Admin.Tests.csproj -c Release

# Setup EXE、脚本兼容 ZIP 和 manifest.json 的打包入口；需要 ISCC 6.7.3
powershell.exe -NoProfile -File scripts/package-windows.ps1 `
  -Version 1.2.3 -OutputDirectory build/artifacts
```

打包器设计为发布 self-contained App 和 Admin，并把 `ClaudeSwitcher.exe`、runtime 文件、受保护 helper 与脚本一起交给 Inno 编译，随后生成脚本兼容 ZIP 和 `manifest.json`。2026-10-27 本地验证：核心测试在 PowerShell 5.1/7 各 174/174，App xUnit 183/183，Admin xUnit 109/109；UserSetup 28/28、InstallerProtocol 15/15、Packaging 21/21 均在两种 PowerShell 通过，Python 验收报告/发布工作流测试 43/43。App/Admin 的 self-contained `win-x64` 目录发布成功，`PublishSingleFile=false`。这些结果不等同于 Setup EXE 编译、安装器执行或 VM acceptance。当前主机没有 ISCC，尚未生成 Setup EXE。不要在 PR 或托管 CI 中执行安装器；安装和卸载行为只能在一次性 Windows VM 中验证。

## ZIP 兼容包安全边界

- `ClaudeSwitcher-<version>-windows.zip` is a compatibility UI/CLI package only. It does not install the protected helper and does not contain the protected Admin executable. It provides no full install or system-repair parity.
- Protected system changes require native setup or a separately documented, auditable administrator procedure. Never run user-writable scripts elevated.
- ZIP 中的 `install.ps1` 是受控 Preview/Apply 脚本，不是原生 Setup EXE，也不能替代受保护 helper 的系统安装。若仅用于兼容 UI/CLI 或排障，请阅读脚本内容并在隔离环境核对来源与哈希。

## 已知限制

- **验收边界：** 升级、修复与默认保留数据的卸载已接入源码和隔离测试。真实安装器、UAC、断电/进程中断回滚及 Windows 10/11 VM 验收仍需执行；未通过前不能视为稳定版。
- Windows 原生版尚未完成 Windows 11/Windows 10 的独立 VM 验收，不能视为稳定版。
- 本机没有 ISCC，未成功编译 Setup EXE；也没有安装器执行、UAC、升级/卸载、数据保留或 release readiness 证据。
- 应用和 Setup EXE 均未签名，SmartScreen 拦截属于预期现象。
- 设备指纹体检（`fingerprint`）与 Web 检测页为 macOS/浏览器能力，Windows 版暂未内置，可用 Web 版检查 Canvas/WebGL；原生界面也尚未完全覆盖这些能力。
- 界面是 WPF 重写的第一版，样式以 Mac 版为准对齐，细节可能有出入。
- Clash Verge 的 TUN 开关在 Windows 上如果被更新重置，目前需要手动在设置里重新打开（一键修复会提示）。
- 账号快照切换前请确保 Claude 已完全退出（托盘图标也要退出）。
- 旧版切换器可能在 `Merge.yaml` 留下 `prepend-rules` / 多文档 `---`，导致 Clash 报 `Merge.yaml ... containing more than one document` 或 TUN 异常。当前「一键修复」会自动备份并清理这些遗留内容，规则模式改用 `Script.js`，不再写 `Merge.yaml`；全局/直连模式跳过规则，只在需要清理旧 Merge 时重启一次。
- 「一键修复」在规则模式写入/清理后会重启 Clash Verge（任务栏/托盘图标会短暂消失，属正常）；全局模式仅在清理历史 Merge 时重启。规则模式重启后会验证内核 `/rules` 前 16 条，失败自动回滚 `Script.js`；控制接口不可用时只提示“无法验证”，不会谎报成功。
- **`auto` / `other` 的 TUN 判定是通用启发式**：只要有一块处于 `Up` 状态、描述里带 `TAP/TUN/WireGuard/Wintun/VPN/Tailscale` 的网卡就会判定 TUN 在线，无法区分“代理隧道已接管”还是“某块虚拟网卡只是存在”。可能误判（例如虚拟网卡残留、其他 VPN 适配器），此时请把 `$PROXY_MODE` 改成实际客户端后重跑配置；若仍不稳定，可在计划任务中暂停 `ClaudeBodyguard`。
- **非 Clash 客户端**：保镖已按客户端模式分派，不再因缺少 `verge-mihomo` 每 10 秒误杀 Claude；但「规则置顶」检查只在 Clash Verge 下按模式判定（全局/直连 ok、规则模式验证 `Script.js` 与内核），非 Clash 用户需要自行在客户端里为 `claude.ai` / `anthropic.com` 等域名配置置顶/直连规则。`DNS` 检查也按 `198.18.x.x` 判断，使用非 fake-ip TUN 时可能显示 `fail`，不代表代理不可用。
- 系统区域为 zh-CN（控制台代码页 936/GBK）时，原生界面和兼容界面均通过 UTF-8 进程管道读取并校验本次 JSON 结果，不使用 `last-check.txt` 缓存补齐检查；空输出、缺项或错误协议会阻断启动。

## 发布门槛

如果只需要给用户提供一个可新装使用的 Windows Beta，可推送 `win-v<版本>` 标签触发 `.github/workflows/windows-beta-release.yml`。工作流在 Windows 2022 runner 上使用 .NET 10.0.403 和 Inno Setup 6.7.3 构建 `ClaudeSwitcher-<版本>-windows-setup.exe`，并创建 GitHub prerelease；发布资产包含 Setup EXE、兼容 ZIP、manifest 和 SHA256 清单。该 Beta 路径只覆盖首次安装，升级、卸载、Windows 10/11 VM 验收和代码签名仍不属于已验证范围。

发布工作流分别构建 macOS/Linux 与 Windows x64 工件，只有单一聚合发布任务能写入 Release。该任务设计为同时取得全部平台工件，并由受保护环境中的 `WINDOWS_VM_REPORT_HMAC_KEY` 验证外部产生的签名 VM 验收报告。报告必须精确绑定当前 commit、版本和 Setup EXE 的 SHA256；缺失、签名错误、哈希不符或任一平台工件缺失都会阻止发布。托管 runner 的构建结果不构成 VM 验收。当前 Setup EXE 编译和 Windows 10/11 VM acceptance 证据均缺失，因此没有 Windows release readiness。
