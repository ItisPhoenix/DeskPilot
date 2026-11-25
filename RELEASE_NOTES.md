# DeskPilot v1.0.0

DeskPilot is a Windows-first, source-available host for private desktop control through an OpenAI Secure MCP Tunnel. This release focuses on guided installation, default-deny permissions, local credential protection, and a reviewable source tree.

## Highlights

- Guided Windows installer with pinned dependency versions, checksum verification, signed Microsoft WebView2 setup, transactional rollback, and a hardened uninstaller.
- Native launcher with system tray, explicit tunnel start/stop, emergency stop, opt-in Windows startup, and kill-on-close process containment.
- DPAPI-protected runtime-key storage and a managed environment that does not forward tunnel/OpenAI credentials to the MCP server.
- Five permission categories disabled by default: Terminal, Files, Screen, Mouse, and Keyboard.
- Files access requires an explicit workspace; DeskPilot policy, configuration, and installation paths are protected.
- Strict foreground leases for mouse and keyboard input. Input never silently refocuses or retries uncertain delivery.
- Local dashboard restricted to loopback; server-side URL fetching and unsolicited browser downloads are disabled.
- Upstream MIT attribution and third-party notices preserved in `NOTICE` and `UPSTREAM.md`.

## Installation

Download `Install-DeskPilot-v1.0.0.ps1`, review it, and run it in Windows PowerShell. The installer obtains Node.js, the official OpenAI tunnel client, and Microsoft WebView2 Evergreen from verified official sources.

Full instructions, account eligibility, costs, limits, troubleshooting, and uninstall steps are in `README.md`.

## Security limitations

- DeskPilot is **not an OS-level sandbox**. Terminal permission can run arbitrary commands as the signed-in user.
- Global Windows input injection is guarded by foreground, PID, process-incarnation, point, and lease checks, but it is not atomic HWND-targeted delivery.
- The tunnel client's local dashboard has no documented built-in login in v0.0.21. Keep it loopback-only; do not enable remote UI.
- Host-header/DNS-rebinding defenses inside the external tunnel client are not confirmed by its official documentation.
- DeskPilot artifacts are SHA-256 checksummed but are not Authenticode-signed by DeskPilot. GitHub-native attestation is unavailable in this private personal repository; the release workflow enables it only after the repository is public or on GitHub Enterprise Cloud.
- Custom tunnel eligibility and pricing depend on OpenAI/workspace policy. Pro tunnel support is not explicitly confirmed; Free/Plus support is not documented.

## Verification

See `CHANGELOG.md`, `SECURITY.md`, and the GitHub Actions run attached to this draft for the exact validation evidence and remaining limitations. This draft is not a public release.
