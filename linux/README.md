# Claude 切换器 · Linux 版 (Beta)

> ⚠️ **本版本为 Beta**。核心逻辑移植自 macOS 稳定版,但 Linux 发行版差异大,遇到问题请到 [Issues](https://github.com/YOURSJEYO/claude-switcher/issues) 反馈。

## 先说最重要的设计差异(为什么是这些取舍)

1. **Claude 官方没有 Linux 桌面版**——Linux 上的使用形态是「网页版(浏览器) + Claude Code CLI」。因此:
   - **账号切换**切换的是**浏览器登录态**(对 `~/.config/google-chrome` 或 `~/.config/chromium` 做快照交换),切换前会完全退出浏览器
   - **保镖**只终止 `claude` CLI 进程,**不会关你的浏览器**(网页版没有独立进程可归因,关浏览器体验太糟;网页端的保护由 TUN + 置顶规则兜底)
2. **没有图形界面**——Linux 桌面环境太多样,本版提供**终端交互菜单**(`claude-switch menu`)+ 完整命令行接口
3. **常驻服务用 systemd 用户单元**——免 root、登录自启、崩溃自动拉起

## 系统要求

> **注意**：Linux 版已支持多代理客户端与地区自适应（安装时按出口国家自动锁定 国家/时区/地区格式 三件套）。自动更新（`update` 命令 + 12 小时自动检查）目前仍仅 macOS 版提供，后续版本同步。

- 任一现代发行版(Ubuntu/Debian/Fedora/Arch 等,systemd)
- 以下任一代理客户端(TUN/虚拟网卡可用):
  - [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev)(体验最佳,置顶规则可自动写入)
  - mihomo / sing-box / V2RayA / NekoBox / Hiddify(置顶规则需手动,安装器会打印清单)
  - WireGuard(wg-quick 服务,启发式判定)
  - 其他客户端安装时选 `other`/`auto`
- python3、bash、curl
- 建议安装 `dnsutils`(Debian/Ubuntu)或 `bind-utils`(Fedora)以获得 dig;没有也能跑(自动回退 nslookup/getent)

## 安装

```bash
# 先开好代理(TUN + 目标国家节点),安装器会校验出口国家不能是 CN
bash install.sh
```

- 安装器自动识别代理客户端与代理组名,并按出口 IP 锁定 国家/时区/地区格式
- 地区识别支持多源探测(ipinfo → ipapi → ifconfig → Cloudflare trace)与失败时的手动选择;全部失败且设置了 `FORCE=1` 时按 US / America/New_York 继续
- 时区锁定和 IPv6 关闭需要一次 sudo 密码
- IPv6 关闭会持久化到 `/etc/sysctl.d/90-claude-switcher.conf`;恢复:删掉该文件后 `sudo sysctl -p`

## 使用

```bash
claude-switch menu          # 交互菜单(推荐)
claude-switch checkdetail   # 14 项逐项检查
claude-switch fix           # 一键修复
claude-switch switch A      # 切到账号A(切换浏览器登录态)
```

## 多代理客户端说明

安装器按以下顺序自动探测,都没有时进入手选菜单(默认 `auto`):

| 客户端 | PROXY_MODE | 在线判定 | 置顶规则 |
|---|---|---|---|
| Clash Verge | `clash-verge` | verge-mihomo/mihomo 进程 | 自动写入 Merge.yaml(智能合并,不动你的已有配置) |
| mihomo | `mihomo` | mihomo 进程 | 手动添加(安装器打印清单) |
| sing-box | `sing-box` | sing-box 进程 | 手动添加 |
| V2RayA | `v2raya` | v2raya 进程 | 手动添加 |
| NekoBox | `nekobox` | nekobox/nekoray 进程 | 手动添加 |
| Hiddify | `hiddify` | hiddify 进程 | 手动添加 |
| WireGuard | `wireguard` | 活动的 `wg-quick@*` 服务 | 手动添加(行为检测不适用,见下) |
| 其他/自动 | `other` / `auto` | 虚拟网卡启发式 / 任一命中 | 手动添加 |

## Beta 已知限制

- 设备指纹体检（`fingerprint`）与 Web 检测页为 macOS/浏览器能力，Linux 版暂未内置，可用 Web 版检查 Canvas/WebGL。
- **wireguard / other 为启发式判定**:WireGuard 没有 fake-ip,DNS 与规则置顶的行为检测(解析到 198.18.x.x)不适用,以虚拟网卡与出口国家校验为准
- **非 Clash Verge 客户端的置顶规则需手动维护**:安装器会打印 DOMAIN-SUFFIX 清单,`fix` 只检测不代写
- **未做多发行版 CI 覆盖**:脚本只依赖 bash + systemd + 常见命令,但各发行版(尤其 Fedora/Arch/openSUSE 等非 Debian 系)未经真机回归,遇到问题请到 [Issues](https://github.com/YOURSJEYO/claude-switcher/issues) 反馈

## 与 macOS/Windows 版的差异

| 项目 | Linux 版 |
|---|---|
| 账号切换对象 | 浏览器配置目录(Chrome/Chromium),不是独立 App |
| 保镖保护对象 | `claude` CLI 进程(不关浏览器) |
| 常驻方式 | systemd 用户服务(免 root) |
| 界面 | 终端菜单 + CLI |
| 时区/IPv6 | timedatectl / sysctl(需 sudo) |

## 卸载

```bash
systemctl --user disable --now claude-bodyguard.service
rm -f ~/.config/systemd/user/claude-bodyguard.service
rm -rf ~/.claude-switcher ~/.local/bin/claude-switch
sudo rm -f /etc/sysctl.d/90-claude-switcher.conf
```
