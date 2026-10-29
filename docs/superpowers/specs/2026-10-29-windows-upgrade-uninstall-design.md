# Windows 原生安装器升级与卸载设计

## 目标

让 Windows 原生安装包支持同一路径的安全升级、修复安装和卸载。升级与卸载默认保留用户配置、账号快照和 Claude 数据；只有用户明确选择时才删除用户数据。

## 约束

- 用户操作锁必须覆盖从安装器准备阶段到升级或卸载完成的整个文件变更阶段。
- 计划任务只能通过受保护 Admin helper 操作，并且必须通过现有 SID、会话和任务 XML 归属校验。
- 升级失败必须恢复旧程序文件和旧保镖任务；无法确认恢复结果时保留恢复材料并阻止核心继续执行。
- 卸载默认只删除 Program Files 程序、快捷方式、卸载注册项和本产品拥有的计划任务。
- 用户数据删除必须显式确认，并在目标用户上下文中执行；不使用 Inno 的 `[UninstallDelete]` 递归删除用户目录。
- 不处理旧版 `ClaudeBodyguard` 任务的猜测性删除；无法安全确认时阻止卸载并给出迁移指引。

## 方案

Inno Setup 负责安装器编排和受保护程序文件的备份/替换；新增维护 broker 负责以普通用户身份持有 `operation.lock` 和 operation lease。broker 在升级或卸载前校验恢复残留、关闭应用、协调受保护任务移除，并在安装器发出成功或回滚信号后释放锁。Admin helper 仍是计划任务的唯一操作入口。

升级流程为：预检固定安装目录、ACL、版本和恢复材料；启动 broker 并持锁；移除当前用户拥有的保镖任务；备份 Program Files 载荷；Inno 替换载荷；用新载荷重新注册任务并只更新用户模板和版本文件；验证成功后删除备份。任何阶段失败都恢复旧载荷和任务，恢复不确定时保留恢复材料并阻止后续核心事务。

卸载流程为：显示数据保留选项；启动 broker 并持锁；关闭应用并移除本产品拥有的计划任务；备份程序载荷；删除程序和快捷方式；成功后释放锁。默认保留 `%USERPROFILE%\\.claude-switcher` 与 `%APPDATA%\\Claude`。用户选择删除数据时，broker 在卸载成功后对经过 reparse、边界和用户身份校验的目录执行清理。

## 组件边界

- `windows/ClaudeSwitcher.iss`：允许已有安装进入升级/修复路径，编排 broker、备份、替换、回滚和卸载步骤。
- `windows/helpers/InstallerMaintenance.ps1`：普通用户维护 broker、预检、租约续期、升级 finalize 和可选数据清理。
- `windows/install.ps1`：增加只更新模板和 `version.txt` 的升级 finalize 入口，不重新探测出口、不覆盖 `config.json`。
- `windows/helpers/UserSetup.ps1`：复用并扩展现有锁与租约接口，保持核心事务兼容。
- `windows/ClaudeSwitcher.Admin`：复用严格的任务注册/移除契约；如维护阶段需要新增命令，只增加受限的维护操作，不放宽任务归属校验。
- `scripts/package-windows.ps1` 与测试：把维护脚本纳入受保护 Setup stage，并验证 fallback ZIP 不扩大私密文件范围。

## 测试与验收

隔离测试覆盖持锁期间核心返回 busy、租约续期失败 fail closed、升级 finalize 保留配置和账号目录、任务移除/重新注册、升级回滚、默认卸载保留数据、显式删除数据、reparse/越界路径拒绝和 Inno 模板静态约束。Windows 10 19045 与 Windows 11 x64 VM 还需验证新装、同版本修复、旧版升级、升级中断回滚、默认卸载、显式删除、运行中应用和跨用户提升场景。

## 实施细化

维护状态和命令都通过按安装器 PID 验证的命名管道传递，不在 Inno 的受保护临时目录写入用户态状态。提升后的客户端以 identification 级别连接，避免服务端模拟其提升令牌。发送 commit 后不因丢失确认而回滚，保留恢复材料供核实。可选数据清理期间持有 machine maintenance mutex，核心和用户配置入口均检查该 mutex，清理失败保留恢复日志。

Inno 卸载器采用两阶段进程，第二阶段独占 unins000.dat。因此普通用户 broker 先在操作锁内调用受保护载荷备份，再启动卸载器；随后仅允许原始卸载进程的子进程、且镜像名为 _unins.tmp、镜像哈希等于原卸载 EXE 的进程接管管道身份。注销前验证预先备份，不尝试读取正在独占的实时 unins000.dat。升级 finalize 是 broker 内部函数，需要同一进程持有的操作锁、活动租约和模板快照，不提供绕过这些约束的公共命令行入口。
