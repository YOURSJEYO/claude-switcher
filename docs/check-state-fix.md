# 菜单栏与面板检查状态同步修复

后台检查此前只更新盾牌颜色，却设置了 `hasData` 和检查时间；面板因此跳过首次刷新，检查行一直保持 pending。

现在后台与手动检查共用 `refresh` / `applyCheckOutput`，同时更新全部 14 行、面板阶段与盾牌颜色。后台保留上次结果，完成后替换；检查进行中不会再启动重叠检查，也不会进行账号切换或修复。空输出、超时、字段缺失及非法状态显示失败，不使用历史缓存冒充本次结果。手动刷新按钮保留，60 秒内展开复用已有完整结果。

运行回归测试与构建（macOS，需 Swift 命令行工具；不修改系统网络设置）：

```bash
build_dir=$(mktemp -d)
awk '/\/\/ MARK: - 视图/{exit} {print}' app/main.swift > "$build_dir/Model.swift"
swiftc -parse-as-library "$build_dir/Model.swift" app/check-state-tests.swift \
  -o "$build_dir/check-state-tests" -framework SwiftUI -framework AppKit
"$build_dir/check-state-tests"
swiftc -O -parse-as-library app/main.swift -o "$build_dir/ClaudeSwitcher" \
  -framework SwiftUI -framework AppKit
```

回归测试使用临时模拟脚本，覆盖后台首次检查填充面板、60 秒缓存、并发防重、警告、失败、超时、缺项、重复行、空状态与恢复。

模板切换也由上述 Swift 测试覆盖：当前模板读取、后台不覆盖待应用选择、应用期间禁止重叠检查、成功后复检、取消时保留旧模板。运行 `python3 core/template-tests.py -v` 可验证三套模板映射、保存、出口不匹配、授权取消与旧安装兼容。该测试使用隔离配置和模拟系统命令，不更改真实系统设置。
