# Changelog

All notable changes to DeskPilot are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and DeskPilot follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1 Beta] - 2026-11-25

Corrected manual patch release replacing the withdrawn v1.0.0 Beta. v1.0.0 remains tagged and published with a withdrawal notice.

### Fixed

- OneDrive-redirected Desktop compatibility: the installer and uninstaller now resolve the Desktop known folder and trust only that folder's reparse ancestors, while still rejecting links on the shortcut itself or anywhere below Desktop. The uninstaller validates the shortcut parent against the resolved Desktop instead of a hard-coded folder name.
- The AppUserModelID is re-applied and verified on the final desktop shortcut inside the installation transaction, so a OneDrive sync that strips the property rolls the install back instead of leaving a mis-tagged icon.
- The published v1.0.1 release contains all three artifacts, including the Windows x64 archive that was absent from v1.0.0.
- Native launcher rebuild with private build paths remapped out of `DeskPilot.exe`; all release assets, including decompressed archives and binaries, were scanned for personal information and credentials.
- Version metadata is synchronized across package, lockfile, launcher manifest, Rust lockfile, and Win32 version resource, including the NUL terminators in the version strings.
- The Windows x64 ZIP is now built with forward-slash relative entry names. The previous v1.0.1 archive used `Compress-Archive` and could not be extracted by the installer's safe extractor; installer path protections were left unchanged.
- `tunnel-client doctor` v0.0.21 tokenizes an absolute Windows MCP path with a shell lexer that strips backslashes, so `mcp_command_executable` always failed on Windows. The installer now verifies the exact staged `node.exe` directly for that one check; every other doctor failure remains fatal.
- Replaced the basic progress bars with a branded in-place terminal display: DeskPilot wordmark with lime accents, overall bar and percentage, per-stage completion markers, live extracted file count, elapsed/remaining time, and a success or failure summary. It redraws in place without scrolling and falls back to `Write-Progress` when output is redirected.
- Fixed the actual runtime tunnel failure: `tunnel-client` v0.0.21 tokenizes `mcp.command` with a shell lexer that strips backslashes, so the absolute Windows `node.exe` path became invalid and the MCP child never started. The installer now writes parser-safe forward-slash paths, and the launcher accepts either separator form after exact normalization, rejecting any other path difference.
- Runtime failures now report the tunnel-client exit code and a sanitized stderr summary (tunnel IDs, API keys, and user paths are redacted) instead of a generic message.

### Verification

Installer security suite passed 232 checks and uninstaller security suite passed 63 checks, including full transaction rollback/commit coverage and OneDrive shortcut cases. Version, privacy, archive-layout, and checksum gates are recorded in [docs/release-validation.md](docs/release-validation.md). This patch was published manually; no GitHub Actions pass is claimed.

## [1.0.0 Beta] - 2026-11-25

Initial public source-first Windows pre-release. Withdrawn: setup and build-metadata privacy defects plus a missing archive asset.

### Added

- Native Rust launcher with a system-tray interface and approved DeskPilot dashboard, wordmark, and DP monogram.
- Five deny-by-default permission categories: Terminal, Files, Screen, Mouse, and Keyboard.
- File-workspace enforcement that denies all Files-category calls when no workspace is configured.
- Visible-window listing, primary-screen capture, explicit window focus, mouse input, and keyboard input tools.
- Strict foreground leases requiring `focus_window` for the exact window handle and PID before input.
- Input behavior that never refocuses or retries automatically, with documented residual Windows `SendInput` race and uncertain-outcome handling.
- Manual start/stop for a supervised official OpenAI `tunnel-client` process.
- Restricted runtime-key handling with optional Windows DPAPI storage and no key in the tunnel YAML profile.
- Per-user Windows installer and uninstaller with exact `DeskPilot-v1.0.0-windows-x64.zip`, `Install-DeskPilot-v1.0.0.ps1`, and `SHA256SUMS.txt` artifacts.
- Automatic WebView2 provisioning from Microsoft's official fwlink with Microsoft Corporation Authenticode verification, hash-stability checking, silent setup, registry verification, and abort-before-app-swap failure handling.
- Portable Node.js **v24.22.3** and full official `tunnel-client-v0.0.21-windows-amd64.zip` provisioning with checksum verification.
- Local launcher activity and metadata-only in-memory tool history by default. Detailed history requires `DESKPILOT_TOOL_HISTORY=1`; argument logging requires `DESKPILOT_TOOL_CALL_LOG=1`.
- Architecture, installation, configuration, troubleshooting, security, privacy, publishing, upstream-attribution, and contribution documentation.

### Changed

- Distribution is a public source repository and manual v1.0.0 Beta GitHub pre-release with exact versioned artifacts and checksums. The manual Beta is unattested because no GitHub Actions artifact attestation was generated.
- The supported connection path is ChatGPT web through the full official `tunnel-client-v0.0.21-windows-amd64.zip` asset and an outbound HTTPS Secure MCP Tunnel.
- Runtime configuration is stored under `%LOCALAPPDATA%\DeskPilot`. Managed tool history is metadata-only in memory by default, and detailed history/argument logs require explicit opt-in.
- Sign-in startup is opt-in and never starts the tunnel automatically.
- Inherited upstream telemetry, remote feature-flag fetching, and feedback prompts are disabled in the managed runtime.
- Upstream MIT attribution, copyright, and third-party notices are retained.

### Security

- Missing, unreadable, or malformed permission policy fails closed.
- MCP filesystem tools cannot access DeskPilot's configuration/install trees or permission-policy file.
- Server-side URL reads are disabled, and remote MCP callers cannot change server configuration.
- The runtime API key is limited to Tunnels Read + Use and is not forwarded to the MCP server environment.
- Added a DeskPilot-owned loopback dashboard proxy with an exact `Host` allowlist and cross-site unsafe-action rejection, mitigating DNS-rebinding reads against tunnel-client v0.0.21's unguarded read endpoints.
- The upstream dashboard is restricted to `127.0.0.1:18080`; the proxy listens on `127.0.0.1:8080`, and remote UI remains unsupported.
- Documented that DeskPilot is not an OS-level sandbox and that terminal access can bypass file-workspace and command-blocklist controls.
- Documented that v1.0.0 Beta binaries are unsigned and retain Authenticode publisher-identity and tampering risk. The manual Beta has checksums but no GitHub artifact attestation or independent build provenance.

### Known limitations

- Full custom MCP tunnel use is documented for Business and Enterprise/Edu on ChatGPT web; Pro tunnel eligibility is not explicitly confirmed, Free/Plus availability is not documented, and mobile is unsupported.
- Workspace roles, RBAC, Lockdown, and tunnel associations apply; role propagation can take up to 30 minutes.
- Reviewed official sources do not establish tunnel-specific pricing; normal ChatGPT/API charges are separate.
- Foreground checks cannot make Windows input atomic or target-bound.
- The local dashboard has no documented built-in login/API-token authentication. DeskPilot's proxy validates local Host values, but local processes remain outside the security boundary.
- `doctor --profile-file <yaml> --explain` is local preflight, not proof of ChatGPT authorization.
- Clean-VM installation, real ChatGPT connectivity, and physical desktop controls were not verified for this Beta.
- The manual Beta lacks GitHub artifact attestation and therefore lacks independent build provenance despite checksum verification.

### Verification status

Validation was performed locally and manually, not through GitHub Actions. The main suite passed 202/202 tests with 13 reported environment skips; repro passed 16/16; integration passed 3/3. Rust passed 39 tests, including live mock dashboard-proxy rebinding rejection, random-route enforcement, upstream-ownership gating, SSE streaming, and environment-override blocking; the installer security suite passed 203 checks. Clean dependency installation, TypeScript and pinned Node 24.22.3 builds, Rust formatting/lint/release build/self-test, uninstaller security checks, managed-runtime checks, isolated desktop input, secret scans, dependency audits, and archive layout smoke checks passed. Exact evidence and unverified clean-VM/live-ChatGPT/physical items are recorded in [docs/release-validation.md](docs/release-validation.md).
