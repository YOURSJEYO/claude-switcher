# macOS Claude Code 账号联动与防护设计

## 目标

桌面版切换 A–D 后，通过切换器启动的终端 Claude Code 使用同一账号；每个账号保留独立的终端设置、登录态和对话历史。代理失效时，保镖同时终止桌面版与 CLI 进程。

## 非目标

- 不同步桌面版与 CLI 的同一段对话，不做实时合并。
- 不读取、导出或改写 macOS 钥匙串内容。
- 不支持环境变量 API key、OAuth token、云厂商或自定义 profile 覆盖账号选择；这些情况拒绝启动，避免绕过账号隔离。
- 不改变直接运行原始 `claude` 命令时的配置查找规则。需要账号联动时使用 `claude-switch.sh cli`；文档可提供显式 alias，但安装器不静默修改 shell 配置。

## 官方机制

Anthropic 文档明确支持用不同 `CLAUDE_CONFIG_DIR` 登录多个账号。每个目录拥有独立设置、会话历史和 claude.ai/API key；macOS 钥匙串条目也按配置目录区分：

- https://docs.anthropic.com/en/docs/claude-code/iam#log-in-with-multiple-accounts
- https://docs.anthropic.com/en/docs/claude-code/iam#credential-management

因此不采用复制 `~/.claude`、导出钥匙串或交换凭据文件的方案。

## 账号映射

- A：`$HOME/.claude`，保留既有终端登录态和历史。
- B/C/D：`$HOME/.claude-switcher/cli-accounts/<B|C|D>`，首次使用各自登录一次，之后直接复用。

新增 `cli-current` 只输出当前槽位和映射目录。新增 `cli [args...]`：

1. 要求桌面切换器已有有效 A–D 当前账号，未初始化时拒绝猜测。
2. 拒绝认证环境变量覆盖及与目标不一致的已有 `CLAUDE_CONFIG_DIR`。
3. 先通过 `mkdir` 获取 CLI 启动/桌面切换共用原子锁，再运行现有 `check` 并捕获输出，任何硬性失败都阻止启动；成功后到启动前重读当前账号，变化则拒绝，避免审计期间串号。
4. 从原始 PATH 解析真实 CLI 绝对路径，避免 alias 递归；B–D 目录以 0700 创建，既有账号目录或父目录为符号链接时拒绝。
5. 用映射后的 `CLAUDE_CONFIG_DIR` 启动真实 `claude`，子进程创建后立即释放锁并等待退出，保留尾部审计日志，不使用会跳过日志的 `exec`。桌面切换持有同一把锁直到进程结束，关闭复核后的启动竞态。

## 切换与急停

- 桌面账号实际变更前，持有共用原子锁，通过 `ps` 识别安装用户的 native `claude` / `claude.exe` 及 npm/bun 的 `@anthropic-ai/claude-code` 入口进程，发送 TERM；未退出则停止切换，不强杀、不继续改数据。
- root 保镖使用 `__HOME__` 推导安装用户 UID，只处理该用户进程，不能按名字杀全系统进程。
- 同一账号重复启动桌面版不要求退出 CLI。
- 保镖发现代理离线时，同时终止桌面版与上述 CLI 进程，保持现有巡检模型和进程边界。
- 不直接读取或修改真实凭据；全部开发验证使用临时 HOME、假进程和假 CLI。

## 兼容与限制

- 既有 A 的默认目录不变；B–D 首次登录是官方预期行为，登录过期仍可能需要重新认证。
- 用户需确认首次登录的 CLI 账号与桌面一致；可用官方 `claude auth status` 自查，切换器不读取凭据自动断言。
- 直接绕过 `claude-switch.sh cli` 启动原始命令，无法保证与桌面账号一致；保镖仍提供代理离线急停。
- 加密桌面快照不包含独立 CLI 配置目录；迁移到新机器后 CLI 可能需要重新登录。
- 本次只修改仓库，不执行安装器、更新器、真实账号切换或本机服务变更。

## 验证

- A 使用既有目录，B–D 使用独立目录且权限为 0700，非法当前账号拒绝。
- 认证环境变量覆盖、配置目录冲突、审计失败及审计后账号变化时，假 CLI 不得执行。
- 参数原样透传，退出码透传且审计日志仍写入，输出不记录凭据。
- CLI 未退出时切换停止且桌面数据/指针不变；正常切换先终止 CLI。
- 保镖仅在代理离线时终止安装用户的 native 与 npm/bun CLI，在线或其他用户进程不误杀。
- 完整 Python 回归、Shell 语法、Swift 严格编译、SHA256SUMS 和主分支双平台 CI。
- 以上均为隔离回归与静态验证结论（临时 HOME、假进程、假 CLI）；B–D 首次真实登录、审计拒绝的真实触发与保镖 CLI 急停未做真机验收，需维护者后续真机确认。
