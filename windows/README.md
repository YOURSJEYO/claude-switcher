# Claude 切换器 · Windows 版 (Beta)

> ⚠️ **本版本为 Beta,未经大规模真机测试**。核心逻辑移植自 macOS 稳定版,但 Windows 环境差异大,遇到问题请到 [Issues](https://github.com/YOURSJEYO/claude-switcher/issues) 反馈。

## 系统要求

- Windows 10 / 11 (64 位)
- PowerShell 5.1+（Windows 自带,无需安装）
- 代理客户端（需支持 TUN 模式），安装器会自动探测并写入 `$PROXY_MODE`:
  - **Clash Verge** —— 存在配置目录即识别，可由「一键修复」按当前模式配置置顶规则
  - **FlClash** —— 识别 `FlClashCore` / `FlClash` 进程
  - **sing-box / ClashX / Surge / WireGuard** —— 按进程或服务识别
  - **其他 TUN 客户端**（Astrill / OpenVPN / Tailscale 等）—— 安装时选 `other`
  - **auto** —— 任一已知进程/服务命中即视为在线（未识别到客户端时的默认选项）
- Claude 桌面版 Windows（传统 EXE 或 MSIX/Appx；MSIX 数据目录可自动发现，但仍待 Windows 真机验收）
- 安装时需要**管理员权限**一次（注册守护任务 / 锁定时区 / 关闭 IPv6）

> 代理模式同时写入 `%USERPROFILE%\.claude-switcher\proxy-mode.txt`，保镖按这个文件分派检测逻辑；缺失时按旧版 Clash Verge 行为处理。

## 安装

1. 先开启代理（TUN 模式）。安装器会检查出口不能是 `CN`，并按当前出口国家写入 `$COUNTRY_TARGET`、`$TZ_TARGET`、`$LOCALE_TARGET`，同时尝试设置系统时区与地区格式；需要美国出口时请先把节点切到美国。地区识别会依次尝试 ipinfo / ipapi / ifconfig / Cloudflare trace，全部失败时可手动选择国家（含 MY）；也可设 `$env:FORCE=1` 强制按 US 继续
2. 右键 `install.ps1` →「使用 PowerShell 运行」,或在管理员 PowerShell 中执行
3. 如果提示禁止运行脚本,先执行一次:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
4. 按提示确认/选择代理客户端，走完流程后桌面会出现「Claude切换器」快捷方式

## 更新

Windows 版启动时会静默检查 GitHub 最新 Release，有新版本时在账号卡下方显示提示条：

- **自动检查**：启动后后台调用 `check-update`，不阻塞界面；24 小时缓存命中时直接显示提示条，不重复打扰
- **一键更新**：点「一键更新」后自动下载 Windows zip 与 `SHA256SUMS-release.txt`，SHA256 校验通过才替换 `%USERPROFILE%\.claude-switcher` 下的 `claude-switch.ps1` / `claude-bodyguard.ps1` / `SwitcherUI.ps1`
- **保留配置**：更新前读取旧脚本的 `$PROXY_MODE` / `$COUNTRY_TARGET` / `$TZ_TARGET` / `$LOCALE_TARGET` / `$PROXY_GROUP`，写入新脚本对应行
- **备份与回滚**：替换前备份到 `backup-<当前版本>-<时间戳>\`；任一步失败会自动回滚并提示原因，旧版本继续可用
- **无需管理员**：更新只改当前用户目录，不弹 UAC；替换后重启 `ClaudeBodyguard` 计划任务并自动重启界面
- **稍后与手动检查**：点「稍后」会隐藏提示条，24 小时内不再自动提示；底部「检查更新」会清除缓存并立即检查一次

版本号来自 zip 根目录的 `VERSION` 文件（由 release 流水线打包时写入），安装后保存在 `%USERPROFILE%\.claude-switcher\version.txt`。**该更新流程尚未经过 Windows 真机验证**，遇到问题请到 Issues 反馈。

## 多代理客户端支持

| 客户端 | `$PROXY_MODE` | 存活判定 | 说明 |
|---|---|---|---|
| Clash Verge | `clash-verge` | `verge-mihomo` 进程 + TUN | 按 Clash 模式自动配置规则（全局/直连跳过） |
| FlClash | `flclash` | `FlClashCore` / `FlClash` 进程 + TUN | 置顶规则需自行配置 |
| sing-box | `sing-box` | `sing-box` 进程 + TUN | 置顶规则需自行配置 |
| ClashX | `clashx` | `ClashX` 进程 + TUN | 置顶规则需自行配置 |
| Surge | `surge` | `Surge` 进程 + TUN | 置顶规则需自行配置 |
| WireGuard | `wireguard` | `WireGuardTunnel*` 服务 + TUN | 置顶规则需自行配置 |
| 其他 TUN 客户端 | `other` | 仅 TUN | 不要求特定进程，避免误杀 |
| 自动 | `auto` | 任一已知进程/服务 + TUN | 保镖在 `auto` 下同样只查 TUN |

TUN 判定顺序：先看是否存在 `198.18.x.x` 假 IP（Clash 系 fake-ip）；没有则回退到任意处于 `Up` 状态、描述匹配 `TAP/TUN/WireGuard/Wintun/VPN/Tailscale` 的虚拟网卡。198.18 命中时保持原来的 `TUN网卡=ok`；回退命中时显示 `TUN网卡=ok:通用虚拟网卡`。

可在主窗口「代理客户端」下拉框切换，或运行 `claude-switch.ps1 set-client <模式>` / `get-client`。该操作会同时更新核心脚本和 `proxy-mode.txt`，保镖下一轮巡检即使用新模式；切换后自动重新执行完整审计。

## Clash 规则与全局模式

「一键修复」会先识别 Clash 当前模式（Mihomo API `/configs`，失败再依次读 `clash-verge.yaml` / `config.yaml` / `verge.yaml` 的 `mode:`），再决定是否动规则：

- **全局 / 直连模式**：规则本来就不生效，修复不写 `Merge.yaml`，也不写 `Script.js`；只有发现旧版遗留的 Merge 规则时才清理并重启一次 Clash。没有遗留时不改动任何配置。
- **规则模式**：只写 `profiles\Script.js` 的托管块（`// >>> claude-switcher managed rules >>>`），不再写 `Merge.yaml`。写入前备份，重启后通过内核 `/rules` 验证前 16 条规则；验证失败会自动从备份回滚 `Script.js`。规则模式需要在 Clash Verge 中启用「全局扩展脚本」，否则验证会失败并回滚。
- **无法识别模式**：跳过规则修改，避免误伤。
- 安装器不再写任何规则；安装完成后请打开切换器点一次「一键修复」完成配置。

旧版切换器写进 `Merge.yaml` 的 `prepend-rules`、单独成行的 `---` 和重复顶层键会被自动备份并清理，不会再写回。全局模式下如果 TUN 已经被旧配置破坏，清理后的那次重启通常即可恢复。

「一键修复」的规则模式/清理结果会显示在界面 Banner；检查列表的「规则置顶」也会同步显示 `ok` / `warn` / `fail`。

### 规则置顶告警怎么读

`规则置顶=warn:规则已写入但无法验证内核加载(...)` 表示 `Script.js` 里的托管块确实存在，但读不到 Mihomo 控制接口，**无法确认内核是否真的加载了这些规则**。括号里是原因：控制接口未配置 / 拒绝连接 / 鉴权失败 / 超时。这是「验证不了」，不等于「规则没生效」，也不等于「已经生效」。

只读排查命令（不修改任何配置、不需要管理员）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-switcher\claude-switch.ps1" rules-status
```

它会打印当前模式、控制接口的来源文件与端点、`/configs` 与 `/rules` 是否可达、`Script.js` 状态，以及内核前 18 条规则（`pinned=yes` 说明 16 条置顶规则都在）。

常见原因与处理：

| 括号里的原因 | 含义 | 处理 |
| --- | --- | --- |
| `控制接口未配置` | `clash-verge.yaml` / `config.yaml` / `verge.yaml` 里都没有 `external-controller` | 在 Clash Verge 设置里打开「外部控制」并设置端口 |
| `控制接口拒绝连接` | 端口没监听：Verge 没开外部控制、端口不对，或刚重启还没起来 | 确认端口后重启 Verge，等 TUN 就绪再检查 |
| `控制接口鉴权失败` | `secret` 与运行实例不一致 | 用 `rules-status` 里的 `auth=` 与配置核对 |
| `控制接口超时` | `/rules` 响应过大或内核无响应 | 稍后重试；`rules-status` 已把超时放宽到 8 秒 |

控制接口地址可以写在三个文件中的任意一个，Windows 版会依次读 `clash-verge.yaml` → `config.yaml` → `verge.yaml`（不支持 unix socket）。若你的 Verge 只用 unix socket，请改用全局模式，或直接在 Verge 的「规则」页面确认前 16 条是否为 Claude 域名。

## 地区自适应与 set-region

- **安装时自动识别**：安装器按出口国家写入 `$COUNTRY_TARGET`、`$TZ_TARGET` 和 `$LOCALE_TARGET`，并尝试设置系统时区与地区格式；出口为 `CN` 时拒绝安装。国家→时区/地区格式映射覆盖 US / JP / TW / HK / SG / GB / DE / FR / KR / AU / CA / MY，其他回退 `America/New_York` / `en-US`。
- **换节点后运行 `set-region`**：
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-switcher\claude-switch.ps1" set-region
  ```
  它会依次尝试 ipinfo / ipapi / ifconfig / Cloudflare trace 重新探测出口，更新脚本头部的三个目标，弹一次 UAC 设置时区，并用用户级 `Set-Culture` 设置地区格式；取消 UAC 或设置失败会给出警告，但配置目标已写入。输出包含 `OK:region=<国家> tz=<IANA> locale=<locale> source=<来源>`。
- **地区检查按 `$LOCALE_TARGET` 比较**：不再写死 `en-US`，而是比较 `[System.Globalization.CultureInfo]::CurrentCulture.Name` 与目标 locale，大小写不敏感；不一致时显示 `地区=fail:<当前>(期望<目标>)`。
- **CN 拒绝**：出口国家为 `CN` 时 `set-region` 输出 `FAIL:出口国家为 CN,已中止`，不写入目标。
- **不会每次检查自动跟随出口**：目标在安装或 `set-region` 时固定，避免节点切换时地区/时区来回变化；需要换区时显式运行 `set-region`。

## 检查设置、客户端日志与诊断导出

主窗口右上角「设置」可分别关闭 `IP一致`、`DNS`、`WebRTC`、`客户端语言`、`ASN属性`、`生态可达性` 这 6 项非关键检查。关闭后对应探测不会执行，界面以灰色 `skip` 显示，**不表示检查通过**。也可选择「将上述非关键项的失败降为警告」，只影响这 6 项，不会放宽出口国家一致性、代理/TUN、Kill-Switch、保镖、账号归档安全或其他硬性安全项。

设置保存在 `%USERPROFILE%\.claude-switcher\checks.json`，也可通过核心命令读取和保存：

```powershell
claude-switch.ps1 get-check-config
claude-switch.ps1 set-check-config '{"disabled":["DNS"],"allowOptionalFailures":false,"logging":true}'
```

脱敏客户端日志默认开启，位于 `%USERPROFILE%\.claude-switcher\logs\client.log`，达到 512 KiB 后轮转为 `client.log.1`。日志只记录命令、退出码、耗时和检查状态，不记录公网/住宅/代理 IP、Bearer/token/session/cookie、账号内容或 Clash 配置。点击主窗口「导出诊断」可生成 zip；也可以运行 `claude-switch.ps1 export-diagnostics <文件路径>`。诊断包只含客户端日志、检查设置和脱敏环境/状态摘要，不包含账号快照、`lastip`、`iphistory` 或原始 `last-check.txt`。

### 客户端语言与 ASN 检查

「客户端语言」读取 Claude 数据目录中 `config.json` 的 `locale`，与目标地区的语言前缀比较，不再用 Windows 显示语言代替。传统版通常位于 `%APPDATA%\Claude`；该目录没有 `config.json` 时，会尝试已发现的 MSIX 数据目录 `%LOCALAPPDATA%\Claude-Data\<PackageFamilyName>`。配置缺失、损坏、语言未设置或不匹配时显示警告；读取配置不等于已验证运行中的 `navigator.language`。

「ASN属性」按已检测出口 IP 查询 IPinfo 的 AS 号，再查询 PeeringDB 的网络类型；`Cable/DSL/ISP` 显示 ISP，通过仅表示 ASN 类型已确认，**不证明具体 IP 属于真实住宅宽带，也不认证其代理信誉**。其他网络类型如实显示为警告；查询失败或记录不完整时显示类型未确认，不再因运营商不在名称短名单中就推断为机房。此检查会将出口 IP 发送给 IPinfo，并将公开 AS 号发送给 PeeringDB；禁用该检查后不会发送这两项查询。

隔离回归：`tests\windows-client-language-integration.ps1` 与 `tests\windows-asn-integration.ps1`，均在 Windows PowerShell 5.1 和 PowerShell 7 下执行，不读取真实账号或请求外网。回滚时恢复修复前的核心脚本即可，修复不修改 Claude 配置、账号存档或系统语言。

## 四账号与跨身份保留

主窗口支持 A–D 四个账号卡片，显示当前账号、已建档状态、快照大小和归档日期。每次切换前会重新完成 14 项审计；输出不完整、硬性项失败或另一操作仍在进行时不会切换。`status` 与 `switch A|B|C|D` 也可在命令行使用，`check` 提供静默总检。启用 `IP一致` 时会维护最近 48 小时出口历史，不同出口达到 3 个会给出警告；禁用该项后不记录这段历史。

同盘安装时，切换暂存和旧目录备份位于 `%USERPROFILE%\.claude-switcher\staging`，不会在 `%APPDATA%` 产生额外的 `Claude.new` / `Claude.old`。数据与账号指针先提交，再清理旧目录；清理失败不会把指针留在旧账号。下次切换只重试清理 `cleanup.json` 能证明归属的残留，不明目录仍需人工确认，绝不自动删除。若 `%APPDATA%` 与 `%USERPROFILE%` 在不同卷，为避免跨卷改名失败，仍使用原 `Claude.new` / `Claude.old` 路径。

跨身份保留默认关闭。在 `%USERPROFILE%\.claude-switcher\keep-in-workspace.txt` 中每行写一个相对当前 Claude 数据目录的路径（如 `settings.json`、`skills/`），切换时先暂存，再合并到目标账号。绝对路径、盘符路径、`..` 越界和重解析点会跳过；暂存或还原失败会阻止启动，已有 `keep-stage` 不会被覆盖。只共享通用配置，不要放登录态、Cookie、缓存或账号专属数据。

## 维护工具

主窗口「工具」提供以下入口，长任务在后台执行：

- `fingerprint`：只读检查地区特征字体、GPU、分辨率和常见虚拟化特征；Canvas/WebGL 仍使用 Web 检测页。
- `cli-info`：只读检查 Claude Code CLI 路径、版本、安装方式、桌面版内置 CLI 和配置目录，不执行升级或卸载。
- `open-safe <http(s)://链接>`：使用 Chrome / Chromium / Edge / Brave 的独立临时 profile，禁用扩展和非代理 UDP；窗口关闭后由独立清理进程删除 profile。代理/TUN 未就绪时拒绝打开。
- `set-region`：换国家节点后重新适配出口地区，可能弹出一次 UAC。

## 加密快照导出与导入

「工具 → 导出/导入加密快照」支持 A–D，也可使用：

```powershell
claude-switch.ps1 snapshot-export A <文件.csnap>
claude-switch.ps1 snapshot-import <文件.csnap> A
```

Windows 使用 `.csnap` 格式：PBKDF2-HMAC-SHA256（200,000 轮）派生密钥，AES-256-CBC 加密，HMAC-SHA256 认证，认证通过后才解压。密码至少 8 位，只经标准输入传递；文件采用流式处理，不会把整份快照读入内存。当前账号不能导出，已有目标槽位、错误密码、文件篡改、账号不匹配、越界路径和链接均会拒绝，失败不会覆盖既有快照。

**`.csnap` 与 macOS 的 AES-256 DMG 不兼容**，不能直接跨系统导入。忘记密码无法找回；导入的是本地登录态，服务端会话失效后仍需重新登录。

## 独立代理诊断

```powershell
claude-switch.ps1 diagnose-proxy --proxy http://127.0.0.1:18080
claude-switch.ps1 diagnose-proxy --config <私有配置.json>
```

也可设置 `CLAUDE_SWITCHER_PROXY_URL`。支持 `http`、`https`、`socks5`、`socks5h`，必须显式包含端口；配置文件只需 `{"proxy_url":"http://127.0.0.1:18080"}`。命令只向 Claude 网页/API 发送无认证请求，输出与 macOS 相同语义的 JSON：退出码 0 表示传输到达，1 表示传输失败，2 表示配置错误。不会继承系统代理、回退直连、创建账号状态、写客户端日志、启动应用或修改系统设置；代理地址和凭据不进入报告，凭据只经 curl 标准输入传递。401/403 不代表账号可用或启动许可。

## 与 macOS 版的差异（注意事项）

> Windows 已对齐 A–D、48 小时出口审查、跨身份保留、指纹/CLI 体检、隔离浏览器、独立代理诊断和加密快照能力。**Shadowrocket 仅 macOS 可用**；Windows 额外支持 WireGuard 与其他 TUN 客户端。Windows 时区映射覆盖美国主要时区、加拿大多伦多/温哥华、日本、韩国、新加坡、台湾、香港、英国、德国、法国、澳大利亚（悉尼/墨尔本）和马来西亚（吉隆坡），其他时区回退到 `Eastern Standard Time`。macOS 使用 launchd 与 `update`，Windows 保留 Release 启动检查 + 一键更新机制。macOS 快照为 DMG，Windows 为上述 `.csnap`。

| 项目 | 说明 |
|---|---|
| 时区名称 | Windows 用 `Eastern Standard Time` 这类 ID,安装器会自动把 IP 城市映射过去 |
| 保镖频率 | 计划任务登录启动,隐藏窗口常驻,每 10 秒巡检(与 Mac 一致) |
| 保镖判定 | 显式客户端模式按「客户端进程/服务 + TUN」；`auto` / `other` 只查 TUN |
| IPv6 | 关闭的是所有网卡的 ms_tcpip6 绑定;要恢复: `Enable-NetAdapterBinding -ComponentID ms_tcpip6` |
| SmartScreen | 首次运行可能弹"Windows 已保护你的电脑" → 点「更多信息」→「仍要运行」 |
| 账号数据目录 | 传统 EXE 版为 `%APPDATA%\Claude`；MSIX/Appx 为 `%LOCALAPPDATA%\Claude-Data\<PackageFamilyName>`，旧版目录不存在时自动发现 |
| 卸载 | 计划任务里删掉 ClaudeBodyguard,删除 `%USERPROFILE%\.claude-switcher` 和桌面快捷方式即可 |

## 已知限制与验证范围

- **本次新增 UI、FlClash、隔离浏览器、代理诊断、加密快照、安装和更新流程尚未做 Windows 真机验收**。仓库中的 Python/XAML 静态检查不等于 Windows 运行验证。可在 Windows PowerShell 中运行隔离回归：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-switch-integration.ps1` 与 `tests\windows-snapshot-integration.ps1`。
- Clash Verge 的 TUN 开关在 Windows 上如果被更新重置,目前需要手动在设置里重新打开(一键修复会提示)。
- 账号快照切换前请确保 Claude 已完全退出(托盘图标也要退出)。若看到 `accounts\<槽位>.new` / `.previous` 或 `staging\Claude.new` / `Claude.old` 残留,说明上次切换被中断；没有有效 `cleanup.json` 归属证明时，先确认数据再清理，不要直接删除。
- WebRTC 检查在 STUN 全部无响应时显示 `warn:STUN 无响应,未确认 UDP 出口`——「探测不到」不等于「零暴露」。
- 旧版切换器可能在 `Merge.yaml` 留下 `prepend-rules` / 多文档 `---`。当前「一键修复」会备份并清理，规则模式改用 `Script.js`；全局/直连模式跳过规则，只在需要清理旧 Merge 时重启一次。规则模式重启后验证内核 `/rules` 前 16 条，失败自动回滚。
- **`auto` / `other` 的 TUN 判定是通用启发式**:虚拟网卡存在不等于代理隧道已接管，可能误判；请改成实际客户端模式后重跑安装器。
- **非 Clash 客户端**:规则置顶需要自行配置。`DNS` 检查按 `198.18.x.x` 判断,使用非 fake-ip TUN 时可能显示 `fail`,不代表代理不可用。
- 系统区域为 zh-CN 时，界面通过 UTF-8 文件或 UTF-8 子进程管道读取检查与修复输出，不依赖控制台代码页。
