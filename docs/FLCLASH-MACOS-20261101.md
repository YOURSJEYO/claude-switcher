# macOS FlClash 兼容修复说明（2026-11-01）

本补丁基于官方 main 提交 `b9399b339af51537dc89980b73ceacbee9b3cf1d`。截至核对时最新 Release 为 v1.7.1；main 已包含 FlClash 适配、应用内检查设置、脱敏诊断日志以及 macOS Claude Code 账号联动。此文是补丁说明，不是新 Release 公告。

## 问题与修复

在 macOS FlClash 点击“一键修复”时，脚本可能提示 `FAIL:无法读取当前 Profile，已保留原配置`。原实现只读取配置目录下的 `shared_preferences.json`，而现场 macOS Flutter 客户端将 `currentProfileId` 保存在 CFPreferences 的 `com.follow.clash` / `flutter.config` JSON 中。

修复优先保留现有 JSON 读取路径；仅当 JSON 文件不存在且配置目录是当前用户标准 macOS FlClash 目录时，通过 `defaults read com.follow.clash flutter.config` 读取 Profile。读取有五秒超时，不输出偏好设置内容，失败仍中止。Profile ID 必须是正整数，后续仍核对数据库中 Profile 存在、数据库版本与规则表结构。

另修复 `enhanced-mode: "fake-ip"` 与单引号写法被误判为未开启 fake-IP 的问题，保留原有不带引号写法。

## WebRTC 与验收边界

本代码补丁不关闭检查，不把 STUN 无响应视为安全，也不改变代理配置的 UDP 策略。STUN 被 REJECT 时，无响应只能表示出口未确认。若选用 UDP 代理策略，应确保三个常用 STUN/TURN 端口 3478、5349、19302 的代理规则先于拒绝或直连规则，并通过实际探针核对结果与代理出口一致。

现场另行调整代理规则后，STUN 返回值与当时美国代理出口一致，应用 14 项检查通过。这是该设备和节点当时的验收，不代表所有节点可用或全面防泄漏保证。该代理规则调整及任何节点凭据均不包含在此补丁中。HTTP 401/403 仅证明收到服务响应，不代表账号或页面功能可用。

远程订阅同步可能覆盖直接改写的 YAML。还应核对修复后运行配置是否真的加载扩展规则，不能只凭数据库写入成功判断已生效。

## 验证

- `python3 -m unittest discover -s tests -p 'test_flclash*.py' -v`
- `bash -n core/claude-switch.sh`
- `bash scripts/gen-sums.sh`，再执行 `shasum -a 256 -c SHA256SUMS`

回归覆盖 macOS 偏好设置读取、读取失败/超时、非法 Profile ID、带引号 fake-IP，以及既有 SQLite 事务、幂等和回滚测试。测试使用临时目录和 mock，不读取真实偏好或账号。

安装或更新前备份核心脚本与 FlClash 配置。更新核心脚本时保留 PROXY_MODE、PROXY_GROUP、COUNTRY_TARGET、TZ_TARGET、LOCALE_TARGET 五项设置。此修复无需重编译 SwiftUI 界面。
