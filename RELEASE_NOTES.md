# DeskPilot v1.0.1 Beta

> **v1.0.0 is withdrawn.** It had confirmed setup and build-metadata privacy defects and was missing its archive asset. The v1.0.0 release notice and tag are retained with a withdrawal warning. v1.0.1 is the corrected manual patch release.

DeskPilot is a Windows-first, source-available host for private desktop control through an OpenAI Secure MCP Tunnel. This Beta focuses on guided installation, default-deny permissions, local credential protection, a protected local dashboard, and a reviewable source tree.

## Highlights

- Guided Windows installer with pinned dependency versions, checksum verification, signed Microsoft WebView2 setup, transactional rollback, and a hardened uninstaller.
- Native launcher with system tray, explicit tunnel start/stop, emergency stop, opt-in Windows startup, and kill-on-close process containment.
- DPAPI-protected runtime-key storage and a managed environment that does not forward tunnel/OpenAI credentials to the MCP server.
- Five permission categories disabled by default: Terminal, Files, Screen, Mouse, and Keyboard.
- Files access requires an explicit workspace; DeskPilot policy, configuration, and installation paths are protected.
- Strict foreground leases for mouse and keyboard input. Input never silently refocuses or retries uncertain delivery.
- A loopback-only dashboard proxy with an exact `Host` allowlist, a 144-bit random base path, supervised upstream-ownership checks, and cross-site unsafe-action rejection, mitigating DNS-rebinding reads and direct-port bypass against tunnel-client v0.0.21.
- Local dashboard restricted to loopback; server-side URL fetching and unsolicited browser downloads are disabled.
- Upstream MIT attribution and third-party notices preserved in `NOTICE` and `UPSTREAM.md`.
- **v1.0.1 fixes:** the installer and uninstaller now accept an OneDrive-redirected Desktop without trusting arbitrary links, re-apply and verify the shortcut's AppUserModelID on the final desktop path inside the transaction, and the native launcher is rebuilt with private build paths remapped out of the binary. The archive asset is published alongside the installer and checksums.
- **Archive packaging correction:** the ZIP now uses forward-slash relative entry names so the installer's safe extractor can read it. This replaces the earlier v1.0.1 archive, which was built with `Compress-Archive` and could not be extracted. Installer path protections were not changed; the fix is in the packaging script only.

## Asset integrity

The exact SHA-256 digests for `DeskPilot-v1.0.1-windows-x64.zip` and `Install-DeskPilot-v1.0.1.ps1` are published in `SHA256SUMS.txt` in this release and in the release notes below. Verify both files against that manifest before running the installer.

## Upgrading from v1.0.0

1. Download `Install-DeskPilot-v1.0.1.ps1` and `SHA256SUMS.txt` from this release and verify both hashes.
2. If the withdrawn v1.0.0 build was installed, uninstall it first with `Uninstall-DeskPilot.ps1` (add `-RemoveUserData` only if you want to discard the local policy, tunnel profile, and DPAPI key).
3. Run the v1.0.1 installer. It repairs the installation in place, preserves the existing permission mask, and rotates the dashboard base path.
4. No ChatGPT-side change is required if the existing tunnel ID is reused: keep the same custom MCP connection and plugin. If you recreate the connection, keep the same restricted runtime key with Tunnels Read + Use.

## Installation

Download `Install-DeskPilot-v1.0.1.ps1` and `SHA256SUMS.txt` from this release, review them, and verify both distribution files before running the installer in Windows PowerShell. The installer obtains Node.js, the official OpenAI tunnel client, and Microsoft WebView2 Evergreen from verified official sources.

Full instructions, account eligibility, costs, limits, troubleshooting, and uninstall steps are in `README.md`.

## Verification

This Beta was validated and published manually, not through GitHub Actions. Automated suites, mock dashboard-proxy tests, dependency checks, installer/uninstaller checks, and archive smoke tests passed. Exact evidence is recorded in `docs/release-validation.md` and `CHANGELOG.md`.

The following were **not verified** for this Beta and are not represented as passed:

- Installation on a separate clean Windows machine or VM.
- Real ChatGPT discovery and tool calls with an eligible workspace and live tunnel.
- Physical emergency-hotkey, tray, Start/Stop, single-instance, close/reopen, and opt-in startup checks.

## Security limitations

- DeskPilot is **not an OS-level sandbox**. Terminal permission can run arbitrary commands as the signed-in user.
- Global Windows input injection is guarded by foreground, PID, process-incarnation, point, and lease checks, but it is not atomic HWND-targeted delivery.
- The tunnel client's local dashboard has no documented built-in login in v0.0.21. DeskPilot's proxy enforces loopback Host values and blocks cross-site unsafe actions, but the dashboard remains an unauthenticated local operator surface.
- DeskPilot artifacts are SHA-256 checksummed but are not Authenticode-signed. This manual Beta has no GitHub artifact attestation.
- Custom TLS trust, outbound proxies, and Cloudflare process selectors are scrubbed from the managed launch. Corporate TLS-inspecting proxies are not supported in this Beta.
- Custom tunnel eligibility and pricing depend on OpenAI/workspace policy. Pro tunnel support is not explicitly confirmed; Free/Plus support is not documented.
