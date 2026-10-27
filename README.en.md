<div align="center">

# ClaudeSwitcher

**A fail-closed local environment manager for multiple Claude accounts**

[中文](README.md) · [Releases](https://github.com/YOURSJEYO/claude-switcher/releases/latest) · [Issues](https://github.com/YOURSJEYO/claude-switcher/issues)

<img src="assets/icon-2048.png" width="120">

</div>

---

## What it is

ClaudeSwitcher keeps several Claude accounts on one Mac without letting their
local state mix. Each account has its own device fingerprint, sign-in
credentials, and application data; switching swaps those directories atomically
instead of signing out and back in.

Before Claude starts, the app runs a 14-point audit of the machine's network and
regional environment. If a blocking check fails, the app is not launched. A
resident bodyguard stops the protected application when the tunnel drops,
closing the window in which traffic could leave outside the proxy.

## Features

- **14-point preflight audit** — proxy core, TUN interface, exit country, IP stability, time zone, locale, IPv6, DNS leakage, WebRTC candidates, bodyguard status, pinned routing, browser language, ASN type, and Claude reachability.
- **Snapshot switching** — archives and restores whole account directories; APFS copy-on-write cloning avoids duplicating unchanged data.
- **Fail-closed bodyguard** — checks the proxy kernel and virtual interface every ten seconds and terminates protected processes when the tunnel is lost.
- **Drift watchdog** — records a baseline for time zone and proxy settings and rolls back silent changes made by other software.
- **Multiple proxy clients** — detects Clash Verge, Shadowrocket, sing-box, ClashX, and Surge, with an automatic mode; non-Clash clients keep their own configuration.
- **Region adaptation** — captures the exit country, time zone, and locale at install time and re-locks all three after moving to a different node.
- **Pinned routing** — places Claude domains and supporting services above third-party rule sets.
- **WebRTC leak probe** — a standard-library STUN client that compares global and local vantage points to distinguish a proxied path from a direct one.
- **Automatic updates** — a user-level launchd agent checks every 12 hours, verifies artifact hashes, and rolls back if the post-update self-check fails.
- **Diagnostics** — a standalone proxy check reports transport results for the Claude web and API endpoints without reading account data.
- **Native menu bar UI** — a single-file SwiftUI app with no Xcode project and no third-party dependencies.
- **Web check page** — a static browser-side check for exit IP, time zone, language, WebRTC, IPv6, and common fingerprint signals.
- **Windows x64 native app (development beta)** — a self-contained .NET 10 WPF app backed by the PowerShell core, plus a scripts-only compatibility ZIP. Native setup source, helper, Inno template, and Windows packaging CI definitions exist, but no Setup EXE has been compiled successfully on this host and no Windows release is ready.
- **Linux port (beta)** — a bash implementation with the same audit and switching model.

## Install

### Download (recommended)

Open the [latest release](https://github.com/YOURSJEYO/claude-switcher/releases/latest):

| Asset | Use |
|---|---|
| `ClaudeSwitcher-<version>-installer-kit.zip` | Full first-time install. Unzip and double-click `installer/安装.command`; it installs the core script, daemons, and desktop app. |
| `ClaudeSwitcher-<version>-macos-arm64.dmg` / `.zip` | The macOS app bundle only, for machines where the core scripts are already installed. |
| `ClaudeSwitcher-<version>-windows-setup.exe` | **Planned** native Windows x64 Inno Setup installer (development beta, unsigned, .NET 10 self-contained App/Admin). The source now includes `windows/ClaudeSwitcher.iss`, `windows/helpers/`, and a controlled install flow, but this host has no ISCC and no Setup EXE has been compiled successfully. See `windows/README.md`. |
| `ClaudeSwitcher-<version>-windows.zip` | **Planned** PowerShell scripts compatibility package, not a portable native executable or native installer. It is a compatibility UI/CLI package only: it does not contain the protected Admin helper executable and does not install the protected helper; it provides no full install or system-repair parity. Protected system changes require native setup or a separately documented, auditable administrator procedure; never run user-writable scripts elevated. No successful Setup EXE compile or Windows 10/11 VM acceptance is claimed, so the ZIP is not a complete installation path. |
| `ClaudeSwitcher-<version>-linux.tar.gz` | Linux scripts (beta). See `linux/README.md`. |

macOS builds are ad-hoc signed and not notarized. If Gatekeeper blocks the first
launch, open the app from the context menu or allow it under **System Settings →
Privacy & Security**. The planned Windows packages are unsigned, so SmartScreen
may warn once they are producible; verify the download source and
`SHA256SUMS-release.txt` before running them. Each release includes
`SHA256SUMS-release.txt`.

**Windows acceptance boundary:** hosted CI only builds, tests, and exercises the
packaging contracts; it is not Windows 10/11 installation acceptance, and no
successful hosted run is claimed here. The release workflow is designed to
publish native Windows assets only after a protected environment verifies a
signed VM acceptance report bound to the exact commit, version, and Setup EXE
SHA256. This host has no ISCC, so no Setup EXE has been compiled successfully;
installer execution, UAC, upgrade/uninstall, and VM acceptance are outstanding,
and no Windows release is ready.

Requirements: macOS 13 or later, a proxy client with TUN support, the Claude
desktop app, and Python 3.

### From source

```bash
git clone https://github.com/YOURSJEYO/claude-switcher.git
cd claude-switcher
# Then double-click installer/安装.command
```

The installer detects the proxy client, proxy group, and regional target, then
builds the desktop app locally. To build and package manually:

```bash
bash scripts/package-macos.sh 1.0.0
```

Artifacts are written to `build/`.

## Usage

1. Open **Claude切换器** and wait for the 14 checks.
2. If everything is green, choose an account and launch Claude. If a blocking
   check is red, use the one-click repair action.
3. Sign in once for each additional account; later switches keep sessions
   independent.
4. After changing to a node in another country, run
   `~/.local/bin/claude-switch.sh set-region`.

The full command set, menu bar behavior, and troubleshooting notes are in the
[Chinese README](README.md) and [AGENTS.md](AGENTS.md).

## Disclaimer

This project is intended for managing the local environment and sign-in state of
multiple Claude accounts in supported regions, for people who are traveling,
living abroad, or otherwise legitimately located in a supported region. Please
follow Anthropic's Terms of Service. Do not use it for account resale, account
sharing, registering accounts on behalf of others, or circumventing regional
restrictions.

Local environment checks only inspect and configure this machine. They do not
change server-side records and do not guarantee that an account will not be
restricted. The software is provided as-is under the MIT license; you are
responsible for how you use it.

## Links

- [中文说明](README.md)
- [Releases](https://github.com/YOURSJEYO/claude-switcher/releases)
- [Issues](https://github.com/YOURSJEYO/claude-switcher/issues)
- [Security policy](SECURITY.md)
- [Agent handoff guide](AGENTS.md)
- [Web environment check](https://yoursjeyo.github.io/claude-switcher/)
- [Windows development beta](windows/README.md) · [Linux beta](linux/README.md)

## License

MIT © ClaudeSwitcher Contributors
