# AGENTS.md —— Agent 交接提示词

> 这份文件写给 AI Agent。用户把本项目交给你时，请按本文档执行安装与配置。
> 用户也可以直接把本文件内容粘贴给任意本地模型（Kimi Code / Cursor / Claude Code 等）作为指令。

---

## 你的任务

帮助用户在 macOS 上安装并配置「Claude 切换器」：一个带环境安检的 Claude 账号启动/切换工具。目标状态是：**用户双击桌面图标，14 项检查均已完成，硬性安全项全部通过；仅用户显式配置的非关键项可显示跳过或警告，且可以正常启动 Claude**。

## 开始之前：必须先确认的前置条件

逐项检查，缺哪项就先补哪项：

1. **macOS**（Apple Silicon 或 Intel 均可）
2. **代理客户端**已安装且代理可用，支持 Clash Verge / Shadowrocket / sing-box / ClashX / Surge 任一（TUN 可用）。Clash Verge 的配置目录应存在于 `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/`；Shadowrocket 以 VPN 配置形式存在（`scutil --nc list` 可见）
3. **Claude 桌面版** 在 `/Applications/Claude.app`
4. **python3** 可用（`python3 --version` 能输出版本号；没有则引导用户运行 `xcode-select --install`）
5. **当前出口 IP 所在国家不能是 CN**——先跑 `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep loc=`，返回的 `loc` 不是 `CN` 才能继续。是 CN 就停下，让用户先把代理调好（安装程序会按出口 IP 自动锁定地区目标：国家/时区/地区格式三件套，裸连时装机会把它们锁错）

## 安装步骤

首选引导用户运行安装器（双击 `installer/安装.command`，或终端执行它）。如果安装器环境受限，按下面的手动等效步骤执行：

1. 把 `core/claude-switch.sh` 复制为 `~/.local/bin/claude-switch.sh`（可执行），把 `core/stun-probe.py` 放到 `~/.claude-switcher/`
2. 探测代理客户端并写进脚本顶部 `PROXY_MODE="..."`：存在 Clash Verge 配置目录 → `clash-verge`；否则 `scutil --nc list` 有 Shadowrocket VPN 配置 → `shadowrocket`；都没有则让用户在 clash-verge/shadowrocket/sing-box/clashx/surge/auto 中选择
3. Clash Verge 模式下，从 `clash-verge.yaml` 的 `proxy-groups:` 找第一个 `type: select` 的组名写进 `PROXY_GROUP="..."`（其他客户端跳过）
4. 按出口 IP 自动锁定地区目标：多源依次尝试 ipinfo.io（country/timezone）→ ipapi.co（country_code/timezone）→ ifconfig.co（country_iso/timezone）→ Cloudflare trace（loc，时区用国家默认映射），全失败时让用户在 US/JP/TW/HK/SG/GB/DE/FR/KR/AU/CA 中手动选，`FORCE=1` 按 US + America/New_York；country → `COUNTRY_TARGET`，timezone → `TZ_TARGET`，country 经映射表（US→en_US、JP→ja_JP、TW→zh_TW、HK→zh_HK、SG→en_SG、GB→en_GB、DE→de_DE、FR→fr_FR、KR→ko_KR、AU→en_AU、CA→en_CA，其余→en_US）→ `LOCALE_TARGET`，三项都写进脚本头部
5. 参照 `daemons/` 目录的模板，物化保镖与时区看门狗脚本（把 `__HOME__` / `__TZ_TARGET__` / `__PROXY_MODE__` 替换为实际值），用 sudo 装入 **root 所有的** `/Library/Application Support/claude-switcher/`（chown root:wheel、chmod 755，用户态不可写防提权）；`local.claude-bodyguard` / `local.tz-watchdog` 两个 LaunchDaemon 安装到 `/Library/LaunchDaemons/`（plist 的 ProgramArguments 已写死指向系统目录，直接 cp 即可）。自动更新 `local.claude-update` 是**用户态 LaunchAgent**：plist 放 `~/Library/LaunchAgents/`，用 `launchctl bootstrap gui/$(id -u)` 注册，不走 root（模板 `daemons/local.claude-update.plist`，每 12 小时跑一次 `update --auto`）
6. 现场编译界面 App（需要 Xcode 命令行工具，必须带 `-target` 否则新 SDK 产物在老系统拒启动）：
   ```bash
   swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" app/main.swift -o Claude切换器.app/Contents/MacOS/ClaudeSwitcher -framework SwiftUI -framework AppKit
   ```
   图标用 `assets/icon-2048.png` 经 sips 生成 iconset 再 `iconutil -c icns` 打进 `Contents/Resources/AppIcon.icns`，`Info.plist` 声明 `CFBundleIconFile`，最后 `codesign --force --deep -s -`
7. Clash Verge 模式下通过核心脚本的 `write-merge-rules` 隐藏入口生成「全局扩展脚本」(profiles/Script.js)，直接前置 `config.rules`，保留已有 main，备份并迁移 Merge.yaml 中本项目旧标记块；重启 Clash Verge 后必须验证内核 `/rules`。其他客户端提示用户自行添加 DOMAIN-SUFFIX 置顶规则
8. 时区与 IPv6（已是目标值则跳过对应命令）：`systemsetup -settimezone <TZ_TARGET>`、`networksetup -setv6off Wi-Fi`（需管理员）
9. 收尾自检：运行 `~/.local/bin/claude-switch.sh checkdetail` 确认各项状态

日常维护命令：`check`（静默总检）/ `checkdetail`（14 项逐项）/ `fix`（一键修复）/ `switch A|B|C|D`（切换账号）/ `set-region`（换国家节点后重锁地区目标）/ `set-client <mode>`（安装后更换代理客户端：clash-verge|flclash|shadowrocket|sing-box|clashx|surge|auto）/ `fingerprint`（设备指纹体检：字体地区特征/GPU/虚拟机；Canvas/WebGL 用 Web 检测页）/ `cli-info`（Claude Code CLI 只读体检：版本/安装方式/多份安装冲突，不执行卸载升级）/ `open-safe <url>`（一次性隔离浏览器打开 http/https 链接；代理未就绪会拒绝，窗口关闭后销毁临时 profile）/ `snapshot-export <A|B|C|D> <file>` / `snapshot-import <file> <A|B|C|D>`（macOS 加密快照导出/导入，AES-256 DMG，密码经 stdin，目标槽位非空会拒绝）/ `update [--check|--auto]` / `update-check`（自动更新：`update-check` 为只读检查入口，只下载并校验、比对配置行后报告是否为新版本，不备份不写入；旧版核心不识别该入口时会安全退出，不会误触发真实更新；`update --check` 在新版中等价；`--auto` 由用户态 LaunchAgent 每 12 小时调用、输出落 `~/.claude-switcher/update.log`；手动跑则直接打印。完整流程：拉取 main → 逐项 SHA256 校验工件（对照仓库 SHA256SUMS，不符即中止）→ 剔除 5 个配置行比对去重 → 备份 .bak → 注入配置 → 守护脚本仅比对并提示 → 自检，含任何 `=fail` 自动回滚）

检查设置：`get-check-config` / `set-check-config <json>` 读写 `~/.claude-switcher/checks.json`，App 齿轮与菜单栏也提供设置入口。只允许关闭 `IP一致`、`DNS`、`WebRTC`、`客户端语言`、`ASN属性`、`生态可达性`；禁用项必须真正跳过探测并显示灰色 `skip`，不能当作通过。`allowOptionalFailures` 只把这 6 项的失败降为警告。出口国家一致性、代理/TUN、Kill-Switch、保镖、账号归档安全、root 权限边界与更新 SHA256 等硬性安全项不可关闭或降级。

客户端日志与诊断：默认在 `~/Library/Logs/claude-switcher/client.log` 记录脱敏命令元数据，512 KiB 后轮转为 `client.log.1`，可用配置中的 `logging` 关闭。`export-diagnostics <file>` 与 App「导出诊断日志」生成 zip，只含客户端日志、检查设置和脱敏环境/状态摘要。不得把公网/住宅/代理 IP、Bearer/token/session/cookie、账号内容、Clash 配置、`lastip`、`iphistory` 或原始 `last-check.txt` 写入日志或诊断包。

跨身份保留（可选，默认关闭）：`~/.claude-switcher/keep-in-workspace.txt` 每行一个相对 Claude 数据目录的路径（如 `settings.json`、`skills/`），`#` 注释、空行忽略。切换时先收进 `~/.claude-switcher/keep-stage/`，还原目标账号后合并回去；绝对路径、含 `..` 和符号链接会跳过并记 WARN。文件不存在或为空时行为与未启用完全一致。只放通用配置，不要放登录态/缓存等账号专属文件。

## 独立代理诊断

`bash core/claude-switch.sh diagnose-proxy --config /path/to/private-proxy.json` 只验证明确指定代理到 Claude 网页/API 的无认证传输，详见 README。它可直接从仓库运行，不适用上述安装/启动前置条件，不启动或关闭应用，不创建账号状态、不修改系统设置。输出 JSON；401/403 分别标注认证或访问状态，传输到达不等于账号可用、启动许可或防泄漏通过。不要为运行诊断先安装后台或改 TUN/时区。

隔离回归：`python3 -m unittest discover -s tests -v`。测试使用本机假 curl 和隔离 HOME，不使用真实登录资料或代理。

## 验收标准（全部满足才算装完）

- 终端执行 `~/.local/bin/claude-switch.sh checkdetail` 输出完整 14 行；硬性安全项全部 `=ok`，非关键项只能是 `=ok`、既有警告，或用户显式配置的 `=skip`/降级警告
- 双击桌面 App，无红色硬性安全项，能正常启动 Claude；灰色 `skip` 不得当成绿色通过
- `launchctl print system/local.claude-bodyguard`、`system/local.tz-watchdog` 与 `gui/$(id -u)/local.claude-update` 均能查到（服务已注册）
- `/Library/Application Support/claude-switcher/` 下两个守护脚本属 root:wheel、权限 755，当前用户不可写
- 切换一次账号 B 再切回 A，A 的登录态完好

## 排障手册（以下全是实战中踩过的坑，按症状直接查）

| 症状 | 根因 | 处理 |
|---|---|---|
| TUN 网卡消失、出口变回国内 | **Clash Verge 更新/异常重启会把 `enable_tun_mode` 重置为 false**（生产环境已发生 4 次） | 退出 App → 改 `verge.yaml` 为 true → 重启 App。切换器的一键修复已内置此逻辑 |
| 时区总是自己变回去 | macOS 自动时区或未知程序改动（生产环境已抓 8 次） | 看门狗会自动回滚；查 `~/Library/Logs/tz-watchdog.log` 留痕 |
| 检查结果显示 0/11、数据为空 | 中文日志被 `cut -c` 按字节截断产生非法 UTF-8，Swift 严格解码整体失败 | 脚本必须 `export LC_ALL=en_US.UTF-8`；界面端用容错解码 `String(decoding:as:)` |
| 修改 App 后界面没变化 | 菜单栏版本关闭窗口仅隐藏；`pkill` 匹配中文路径还可能因 Unicode NFD 编码失配而静默失败 | 先从盾牌菜单选「退出 Claude 切换器」，再替换 App；开发排障也可按进程名退出测试实例。不要把关窗改回退出，以免破坏菜单栏驻留 |
| headless Chrome 做 WebRTC 检测无结果 | headless 模式 ICE 子系统不产出候选 | 不要走浏览器路线，用本项目的纯 Python STUN 探针 |
| 代理节点报错但流量没泄漏 | 节点被重置时隧道内请求失败≠泄漏；Fail-Closed 下流量只断不绕 | 换线路即可 |
| 切换账号报「存在待恢复快照，拒绝覆盖」 | 上次归档被中断，`~/.claude-switcher/accounts/<账号>.new` 或 `.previous` 残留（可能是唯一副本） | 先确认 `<账号>/` 是否完整；若有 `.previous` 且正式目录缺失，用它恢复；确认无价值后再删除 `.new`/`.previous` 重试 |
| 规则置顶显示「未生效」/检查提示运行规则未验证 | Clash 处于 global 模式时规则本不生效(正常);rule 模式下多为 Script.js 未启用、代理组不存在或控制 socket 失效 | 全局模式无需处理;rule 模式先确认全局扩展脚本启用与代理组名,再跑 `fix`;控制接口失联时会自动回退服务 socket |
| WebRTC 检测失败但 TUN 正常 | STUN 被国内直连规则匹配、全局脚本未启用、代理组或节点 UDP 能力不符 | Clash Verge 运行 `fix` 写入全局 Script.js；FlClash 运行 `fix` 备份并在当前 Profile 事务写入域名与 UDP 3478/5349/19302 规则，重启验证，失败回滚。默认 proxy；`WEBRTC_POLICY=reject claude-switch.sh fix` 可切换并持久化拒绝策略（影响部分通话）。不要再向全局 Merge.yaml 手写 prepend-rules，不要把无 STUN 响应视为零暴露 |
| 安装器未能识别出口国家 | 只探测 ipinfo.io，代理规则判直连/被墙/限流时国家为空直接退出 | 已改为 ipinfo → ipapi → ifconfig → Cloudflare trace 多源自动兜底；仍失败时检查代理规则是否把这些域名判直连，或 `FORCE=1` + 手动选地区 |
| Windows 地区检查误红（非美国用户） | `$LOCALE_TARGET` 与系统「区域格式」不一致；旧版曾写死 `en-US` | 运行 `claude-switch.ps1 set-region`；或在「设置 → 时间和语言 → 语言和区域 → 区域格式」中改成目标 locale，并确认 `$LOCALE_TARGET` |
| 切换账号后对方看到"新设备" | 正常：快照隔离意味着每个账号有独立设备指纹，这正是设计目标 | 无需处理 |
| 切换后某些文件没过去／不该过去 | 跨身份保留默认关闭，只复制 `~/.claude-switcher/keep-in-workspace.txt` 中列出的相对路径；绝对路径、含 `..`、符号链接会被跳过 | 对照该文件与 `~/Library/Logs/claude-switch.log` 的 WARN；只保留通用配置，不要把登录态/缓存列进去 |

## 安全红线（Agent 必须遵守）

1. **绝不在出口国家与目标不一致时启动 Claude**——任何时候先验 cloudflare trace 的 `loc` 与脚本头部 `COUNTRY_TARGET` 一致；换了国家节点先跑 `claude-switch.sh set-region` 再启动
2. 切换账号前必须先完全退出 Claude 进程，再交换数据目录
3. 不要在日志、文档、Issue 里暴露用户的住宅/代理 IP 与任何凭据
4. 不要改动 `~/.claude-switcher/accounts/` 下的存档结构
5. **维护纪律**：`core/`、`daemons/`、`installer/` 下任何文件改动后，提交前必须运行 `scripts/gen-sums.sh` 重新生成根目录 `SHA256SUMS` 并同提交——自动更新靠它校验工件完整性，清单与代码不一致会导致所有用户更新失败
6. **守护进程脚本只在 root 目录**：`/Library/Application Support/claude-switcher/` 下的保镖/看门狗属 root:wheel，任何功能都不要改回写 `~/.local/bin/` 下的同名脚本（用户可写=提权面）；需要变更时引导用户重跑安装器

## 问题修复决策规则（Agent 必须遵守）

接到反馈时，**先判断这是「用户个例」还是「所有用户都会遇到的普遍问题」，再决定改不改产品**：

1. **用户个例**：只与对方的节点、分流规则、系统设置、操作顺序、第三方软件冲突有关，默认配置下无法复现 → 只给排查步骤与用户侧修复方案（改配置、换节点、重装、更新），不轻易改产品代码。
2. **普遍问题**：默认安装/升级路径、平台兼容性、安装器健壮性、数据安全、竞态、官方客户端行为变化等，任何用户都可能遇到 → 应当修复；修复要向后兼容，附回归测试，并说明影响面与回滚方式。
3. **先复现再定性**：能在隔离环境复现或找到证据（日志、API 返回、上游 issue）才算普遍问题；无法复现先按个例处理并记录，除非有明确证据表明影响所有用户。
4. **修复前先说清根因与范围**：向维护者说明「问题是什么、影响谁、为什么这样修、怎么验证」；破坏性/高风险改动仍需维护者确认后再执行。
5. **不为修个例牺牲安全不变量**：不能为了让某个环境通过而放宽出口一致性、Kill-Switch、root 权限边界或供应链校验。
6. **发布前检查**：测试全过、文档与 SHA256SUMS 同步、回滚路径明确；无法真机验证的平台必须如实标注。

## Windows 版（windows/ 目录, Beta）

Windows 用户请使用 `windows/` 下的 PowerShell 版本。关键差异与注意事项：

- **文件编码**：所有 `.ps1` 文件必须保持 **UTF-8 with BOM**（Windows PowerShell 5.1 无 BOM 会把中文读成乱码）。编辑后若中文变乱码，重新加 BOM。
- **时区 ID 体系不同**：Windows 用 `Eastern Standard Time` 这类 ID，核心脚本的 `ConvertTo-WindowsTimeZone` 负责把 IANA 时区（America/New_York）映射过去，`install.ps1` 保留同映射的副本。
- **地区自适应**：安装器按国家写入 `$COUNTRY_TARGET` / `$TZ_TARGET` / `$LOCALE_TARGET`；换节点后运行 `set-region` 重新探测出口（ipinfo → ipapi → ifconfig → Cloudflare trace），更新三个目标、通过一次 UAC 设置时区、用用户级 `Set-Culture` 设置地区格式；出口 CN 拒绝。`地区` 检查比较 `CurrentCulture.Name` 与 `$LOCALE_TARGET`，不再写死 `en-US`。
- **权限模型**：`install.ps1` 需要管理员运行（注册计划任务/锁时区/关 IPv6）；日常使用中「一键修复」通过 `Start-Process -Verb RunAs` 触发 UAC 弹窗。
- **保镖实现**：用计划任务（AtLogOn 触发）启动隐藏 PowerShell 常驻进程，10 秒巡检，与 Mac 版行为一致。
- **robocopy 退出码**：0-7 都是成功，8+ 才是失败——判断切换成败时不要按常规退出码判断。
- **切换写入顺序**：先复制到 `accounts\<槽位>.new`，复制成功后才改名提交，旧快照暂存为 `.previous`。同盘时，载入暂存与换位备份放在 `%USERPROFILE%\.claude-switcher\staging\Claude.new` / `Claude.old`，避免 `%APPDATA%` 同时出现多个 Claude 数据目录；重定向到不同盘时回退 `%APPDATA%\Claude.new` / `Claude.old` 以避免跨卷改名。数据与 `current.txt` 先一起提交，再清理旧目录。预先存在的不明残留一律拒绝覆盖、绝不自动删除；仅 `staging\cleanup.json` 能证明路径与当前账号归属的 `Claude.old` 可在下次切换前重试清理。隔离回归：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-switch-integration.ps1`（临时目录 + 打桩进程，不需要真机账号）。
- **账号数据目录**：传统 EXE 版为 `%APPDATA%\Claude`；旧目录不存在时自动发现 MSIX/Appx 的 `%LOCALAPPDATA%\Claude-Data\<PackageFamilyName>`（不是 macOS 的 `~/Library/Application Support/Claude`）。WPF 与 `status` 均支持 A–D、快照大小和日期；切换前必须重新完成审计。`keep-in-workspace.txt` 的语义与 macOS 相同，但 Windows 还需拒绝重解析点。
- **代理客户端**：支持 `clash-verge` / `flclash` / `sing-box` / `clashx` / `surge` / `wireguard` / `other` / `auto`。`set-client` 同时更新核心脚本与 `proxy-mode.txt`，保镖每轮重新读取该文件；不要套用 macOS 的 root 守护同步方式。
- **工具与快照**：`fingerprint`、`cli-info`、`open-safe`、`diagnose-proxy` 均已提供 Windows 实现。`snapshot-export` / `snapshot-import` 使用流式 `.csnap`（PBKDF2-HMAC-SHA256 200,000 轮、AES-256-CBC、HMAC-SHA256），不与 macOS DMG 兼容；密码仅经 stdin，先认证再解压，目标槽位非空或包路径越界必须拒绝。隔离回归另有 `tests\windows-snapshot-integration.ps1`。
- **检查设置与日志**：与 macOS 使用相同的 6 项非关键检查白名单和 `allowOptionalFailures` 边界；配置在 `%USERPROFILE%\.claude-switcher\checks.json`，脱敏日志在 `%USERPROFILE%\.claude-switcher\logs\client.log`，512 KiB 轮转。WPF 设置窗口和 `export-diagnostics` 可导出脱敏诊断 zip，不得包含账号、IP、凭据、Clash 配置或原始检查详情。独立代理诊断不得创建账号状态或写客户端日志。
- **已知限制**：新 WPF、FlClash、隔离浏览器、代理诊断、加密快照、安装与更新流程尚未做 Windows 真机验收，静态/XAML 测试不能冒充真机测试；Clash Verge 的 TUN 开关被更新重置后在 Windows 端需手动重开。
- **自动更新**：启动时静默检查 GitHub 最新 Release，有新版显示提示条；一键更新会下载 zip、校验 SHA256、备份并替换用户目录脚本、重启保镖任务和界面，失败自动回滚，不需要管理员。发布 zip 根必须带 `VERSION`（`release.yml` 已写入），安装后落到 `%USERPROFILE%\.claude-switcher\version.txt`。
- **Clash 规则**：一键修复先识别 Clash 模式（Mihomo API `/configs`，失败回退 `clash-verge.yaml`/`config.yaml`/`verge.yaml` 的 `mode:`）。全局/直连模式不写规则，仅清理旧 Merge；规则模式只写 `profiles\Script.js` 托管块，重启后用内核 `/rules` 验证前 16 条，失败回滚。安装器不再写 `Merge.yaml`，旧 `prepend-rules`/`---` 会被清理并备份。控制接口地址从 `clash-verge.yaml` → `config.yaml` → `verge.yaml` 依次查找（不支持 unix socket）；「规则置顶」告警括号里会带原因（未配置/拒绝连接/鉴权失败/超时），只读排查用 `rules-status`。
- SmartScreen 首次运行拦截属正常现象（未签名脚本），引导用户「更多信息 → 仍要运行」。

## Linux 版（linux/ 目录, Beta）

Linux 用户使用 `linux/` 下的 bash 版本。**开始之前必须先理解最大的前提差异**：

- **Claude 官方没有 Linux 桌面版**——使用形态是「网页版(浏览器) + Claude Code CLI」。因此：
  - 账号切换切换的是**浏览器配置目录**（`~/.config/google-chrome` 或 `~/.config/chromium`），即切换 Web 登录态；切换前必须完全退出浏览器
  - 保镖只终止 `claude` CLI 进程，**不要让它去杀浏览器**（网页端保护交给 TUN + 置顶规则）
- **多客户端**：`PROXY_MODE` 支持 clash-verge / mihomo / sing-box / v2raya / nekobox / hiddify / wireguard / other / auto；非 Clash 客户端不做配置改写，只做 fake-ip 行为检测并提示用户自行加 DOMAIN-SUFFIX 规则；`wireguard` / `other` 为通用虚拟网卡启发式判定
- **地区自适应**：`COUNTRY_TARGET` / `TZ_TARGET` / `LOCALE_TARGET` 由安装器按出口自动写入；`CN` 出口拒绝安装；换国家节点后手动改这三个值（Linux 版暂无 `set-region` 命令）
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
- Web 版：`docs/` 下的 index.html/app.js/style.css（纯静态环境检测页，GitHub Pages 从 docs/ 发布）

## 维护者本机纪律（Agent 必须遵守）

**除非维护者在当次对话中明确要求，否则不得更新/部署维护者本机的已安装版本。** 具体包括：

- 不得覆盖 `~/.local/bin/claude-switch.sh`、`~/.local/bin/local.claude-*.plist`
- 不得重新编译或替换桌面 App（`~/Desktop/Claude切换器.app`）
- 不得改动 `/Library/Application Support/claude-switcher/`、`/Library/LaunchDaemons/local.claude-*`、`~/Library/LaunchAgents/local.claude-*`
- 不得触发本机 `update`、不得执行安装器/卸载器

日常开发默认流程：**只修改仓库文件 → 验证（本地只跑不影响安装态的测试/静态检查）→ 提交推送**。维护者已持续授权：每次修复完成并通过适用验证后，可直接提交并推送 `main`，无需逐次确认；推送前仍需 `git fetch origin main` 核对远端，不得覆盖他人工作，也不得提交故意保留的未跟踪交接文档。Issue 回复后可直接关闭，无需逐次确认；已修复的标记为完成，信息不足或不打算继续处理的应选择相应关闭原因，不得伪装成已修复。需要真机验证时，先询问维护者是否允许在本机部署。打 tag、发布 Release、执行安装器/更新器或修改真实账号与代理配置，仍须逐次明确授权。
