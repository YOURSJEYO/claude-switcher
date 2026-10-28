# macOS 菜单栏隔离验证

要求：macOS 13+、Swift 编译器、可用的图形登录会话。模型测试不需要真实 Claude、代理或管理员权限：

```bash
python3 -m unittest discover -s tests -v
```

31 个菜单栏场景覆盖多账号状态解析、A–D 切换与首次使用提示、旧版状态回退、本地账号刷新、切换前重新审计、警告放行、失败/缺行/重复行/空值/超时/非零退出阻断、忙碌互斥、退出保护、隐藏回调与单窗口生命周期。非 macOS 系统跳过这部分，继续运行现有的核心脚本测试。

## UI 演示程序

`MenuBarFixture.swift` 与生产应用共用 `SwitcherMenu`、`AppDelegate` 和 `ContentView`，仅把核心脚本注入为明确指定的假脚本。未提供脚本路径时拒绝启动；不会回退到 `~/.local/bin/claude-switch.sh`。

演示程序额外提供「菜单内容预览」和「演示外观」菜单，便于无法定位 macOS `AXExtrasMenuBar` 的 UI 工具验证同一份生产菜单内容，以及只改变演示应用自身的深浅色外观。启动时会输出原生状态栏按钮数量、模板图像属性和辅助功能名称，供检查图标驻留与可访问性。辅助功能属性检查不等于完整的 VoiceOver 语音验收。

在仓库根目录操作，所有输出放在被忽略的 `_trash/`：

```bash
mkdir -p _trash/menu-bar-demo
swiftc -O -parse-as-library -D CLAUDE_SWITCHER_TESTS \
  -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path _trash/menu-bar-demo/module-cache \
  app/main.swift tests/MenuBarFixture.swift \
  -o _trash/menu-bar-demo/MenuBarFixture \
  -framework SwiftUI -framework AppKit

cat > _trash/menu-bar-demo/fake-core.sh <<'SH'
#!/bin/bash
case "$1" in
  checkdetail)
    for key in 代理内核 TUN网卡 出口IP IP一致 时区 地区 IPv6 DNS WebRTC 保镖 规则置顶 客户端语言 ASN属性 生态可达性; do
      if [ "$key" = ASN属性 ]; then echo "$key=warn:演示机房"; else echo "$key=ok:演示数据"; fi
    done ;;
  status) echo 'current=A hasA=1 hasB=1 hasC=1 hasD=0 accounts=A,B,C accA=1.2G@2026-10-20 accB=900M@2026-10-19 accC=2.0G@2026-10-18' ;;
  switch) echo "OK:演示切换至 $2" ;;
  fix) echo 'FIX:演示修复' ;;
  fingerprint) echo 'GPU=ok:演示设备' ;;
  *) exit 2 ;;
esac
SH

_trash/menu-bar-demo/MenuBarFixture "$PWD/_trash/menu-bar-demo/fake-core.sh"
# 深色外观（只改变演示应用自身）：
# _trash/menu-bar-demo/MenuBarFixture "$PWD/_trash/menu-bar-demo/fake-core.sh" --dark
```

手动验收：

1. 首次启动显示窗口，顶部有盾牌图标，Dock 没有该应用图标。
2. 关闭窗口后图标仍在；「打开主窗口」复用同一窗口，最小化后也能恢复。
3. 菜单和主窗口账号、警告状态一致；「重新检查」打开窗口并重新检测。
4. 模拟切换成功后约 2.2 秒隐藏窗口，菜单仍可恢复窗口；失败时保持错误信息。
5. 修复/切换期间重复操作被禁用，菜单和系统的退出请求均被阻止；完成后可以退出。
6. 菜单项支持方向键、Return、⌘O、⌘Q；图标有辅助功能标签，检查结果用文字表示而不是只用颜色。
7. 在浅色、深色下检查菜单图标和文字；可在 VoiceOver 中确认图标、菜单项和禁用状态可读取。
8. 选择「退出 Claude 切换器」后图标消失；确认本机已安装的应用和系统服务没有被修改。

截图只使用这个演示程序。不要运行真实账号切换或把住宅/代理 IP、凭据放进截图。

以下为隔离演示的主窗口截图，不是顶部状态栏下拉菜单截图。截图拍摄于双账号版本，A–D 四宫格卡片以当前构建为准：

| 浅色系统控件 | 深色系统控件 |
| --- | --- |
| ![浅色演示窗口](../docs/images/macos-menu-bar-demo.jpg) | ![深色演示窗口](../docs/images/macos-menu-bar-demo-dark.jpg) |
