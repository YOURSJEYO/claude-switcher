# Claude 切换器 · Windows 原生版 (Development Beta)

> ⚠️ **开发 Beta / 未签名 (unsigned)，当前没有 Windows release readiness**：源码已包含原生 WPF 应用、受保护 helper、Inno Setup 模板、受控 Preview/Apply 安装流程、原生 SetupClient/协议以及 Windows CI 打包定义。但本机没有 ISCC，**no successful local Setup EXE compile**；也没有安装器执行、UAC、Windows 10/11 VM acceptance 证据。托管 CI workflow 已定义，但 hosted CI 不是 Windows 10/11 acceptance，本文也不声称已有成功的 hosted run。

**证据边界：** no successful local Setup EXE compile；no successful hosted run is claimed；no installer execution, UAC, upgrade/uninstall, Windows 10/11 VM acceptance；no Windows release readiness。

## 当前源码状态

- `ClaudeSwitcher.exe` 是 **self-contained WPF apphost**，发布时旁边还有 .NET/runtime 等文件（`PublishSingleFile=false`）。它不是 portable single-file executable，也不是 Setup EXE。
- `ClaudeSwitcher-<version>-windows-setup.exe` 是 Inno Setup 的 Setup EXE 输出名。`windows/ClaudeSwitcher.iss` 已存在，`scripts/package-windows.ps1` 已定义使用 Inno Setup 6.7.3 的编译流程；本机没有 ISCC，尚未成功产出 Setup EXE。
- `windows/helpers/UserSetup.ps1` 已存在。`windows/install.ps1` 已实现受控的 Preview/Apply 接口，包括 `-NonInteractive`、`-ProxyMode`、`-ProxyGroup`、`-Country`、`-TimeZoneId`、`-Culture`、`-Preview`、`-Json`、`-Initialize`、`-RemoveUserTask` 和 `-RequireNoOtherTasks`。
- 原生应用侧已有 `SetupClient` 和 setup protocol 代码，用于调用预览/应用流程并校验结构化结果；源码存在不等于安装器已经在 Windows VM 中通过验收。
- `ClaudeSwitcher-<version>-windows.zip` 仅用于兼容 UI/CLI。The ZIP does not install the protected helper and does not contain the protected Admin helper executable (`ClaudeSwitcher.Admin.exe`). It provides no full install or system-repair parity. Protected system changes require native setup or a separately documented, auditable administrator procedure. Never run user-writable scripts elevated.
- `.github/workflows/checks.yml` 已定义 Windows x64 构建、测试和打包检查；`.github/workflows/release.yml` 已定义受保护发布门槛。两者都不替代 Windows 10/11 VM acceptance。

## 运行时与系统支持

- **运行时**：App 与 Admin 均配置为 **.NET 10 self-contained**、`win-x64` 发布，因此目标机不需要单独安装 .NET Desktop Runtime；该发布路径仍需安装验收。
- **Windows 11 x64**：主要开发目标；安装、UAC、升级/卸载和普通用户启动仍需独立 VM 验收。
- **Windows 10 22H2 x64**：兼容性待单独 VM 验收；在报告通过前不声明支持。
- **Windows ARM64**：当前不支持。
- **PowerShell**：核心兼容 Windows PowerShell 5.1；开发和 CI 同时覆盖 PowerShell 7。
- **Claude 桌面版**、支持 TUN 的代理客户端仍是运行前置条件。

> **VM acceptance boundary:** VM acceptance must be executed externally on disposable Windows 11 and Windows 10 VMs; hosted CI is not Windows 10/11 acceptance and must preserve the exact commit, version, and installer-hash evidence.

> **尚未执行的验收要求：** A SID-scoped task must be running, and a fresh heartbeat must match the expected user SID/session. 该条件目前只是待验证要求，不是现有证据。

## 安装、UAC 与身份边界（源码已定义，尚未验收）

1. 原生 Setup 源码要求管理员权限安装程序文件；安装后的配置入口以 `runasoriginaluser` 启动，避免把日常 Claude 进程提升为管理员。
2. 配置流程先执行只读 Preview，再进入 Apply；用户配置、受保护 helper 调用和系统修复应使用受控参数，不接受任意命令或脚本。
3. UAC 取消、部分 helper 失败、重复入口和从已提升终端启动时的原始用户识别，都必须在 VM 中验证安全失败、可重试且不误写其他用户状态。
4. 用户配置和账号快照应绑定发起安装的普通用户；**Claude 和应用本身必须以普通用户身份运行**，不要从管理员终端启动日常使用。
5. 安装包仍为**未签名**，Windows SmartScreen 可能显示“Windows 已保护你的电脑”。产物可发布后，请先核对下载来源和 `SHA256SUMS-release.txt`，确认无误再选择“更多信息 → 仍要运行”。

## 升级、卸载与数据保留（尚未验收）

- 升级和卸载的验收要求是 **preserve** A/B 账号归档、地区/代理配置和其他用户数据。
- 当前开发 Beta 保留新装入口，但检测到已有原生安装时会在文件变更前拒绝升级；卸载入口也会直接拒绝，不删除任务或程序文件。尚未实现覆盖整个文件变更阶段的持续锁，不能把这些拒绝行为视为已支持安全升级/卸载。
- IPv6、时区等系统设置只有在明确请求卸载清理、且当前值仍与安装器写入值一致时才应恢复；不得覆盖后来由用户或其他软件设置的值。
- 以上是源码设计与待验收要求，不代表已经在安装器或 Windows 10/11 上验证。卸载前仍建议自行备份 `%USERPROFILE%\.claude-switcher` 和 `%APPDATA%\Claude`。

## 旧版保镖任务迁移

当前构建不提供 `ClaudeBodyguard` 的自动迁移。核心返回 `migration-required` 时，原生界面和兼容界面会保留这条说明；重复运行修复或配置向导不能视为迁移完成。

迁移需要先在隔离 VM 中完成以下核对：旧任务属于当前 SID、使用限定的 PowerShell 动作和用户脚本路径、运行实例属于同一 SID/会话；停止并移除已核实的旧任务及其运行实例后，再注册受保护任务。无法确认归属时保留旧任务，停止迁移。不得通过执行旧脚本导入配置，也不得删除账号归档或恢复材料。当前尚无已验收的迁移入口，请继续使用原有安装，等待迁移实现及 VM 验收。

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

- **发布阻塞：** 覆盖文件变更全过程的核心 `operation.lock` 持续租约仍未实现。当前已禁止已有原生安装的升级和卸载，避免在持锁范围不足时替换/删除程序。需要解决原始用户、卸载身份和多用户协调，完成隔离 VM 验证后才能启用这些入口及发布安装包。
- Windows 原生版尚未完成 Windows 11/Windows 10 的独立 VM 验收，不能视为稳定版。
- 本机没有 ISCC，未成功编译 Setup EXE；也没有安装器执行、UAC、升级/卸载、数据保留或 release readiness 证据。
- 应用和 Setup EXE 均未签名，SmartScreen 拦截属于预期现象。
- 设备指纹体检等能力仍以 macOS/Web 版为准；Windows 原生界面尚未完全覆盖。
- Clash Verge 的 TUN 设置若被其更新重置，需要在客户端中手动重新启用。
- 切换账号前必须完全退出 Claude；快照切换和保镖逻辑不会绕过这一要求。

## 发布门槛

发布工作流分别构建 macOS/Linux 与 Windows x64 工件，只有单一聚合发布任务能写入 Release。该任务设计为同时取得全部平台工件，并由受保护环境中的 `WINDOWS_VM_REPORT_HMAC_KEY` 验证外部产生的签名 VM 验收报告。报告必须精确绑定当前 commit、版本和 Setup EXE 的 SHA256；缺失、签名错误、哈希不符或任一平台工件缺失都会阻止发布。托管 runner 的构建结果不构成 VM 验收。当前 Setup EXE 编译和 Windows 10/11 VM acceptance 证据均缺失，因此没有 Windows release readiness。
