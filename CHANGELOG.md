# Changelog

All notable changes to DeskPilot are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and DeskPilot follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-25

Initial source-first Windows release.

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

- Distribution is a private source repository and draft Windows x64 GitHub Release with exact versioned artifacts and checksums. The private personal-account draft is unattested because GitHub Artifact Attestations require a public repository or GitHub Enterprise Cloud; the workflow enables attestation only for public visibility.
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
- The tunnel-client admin dashboard remains loopback-only; remote UI is unsupported.
- Documented that DeskPilot is not an OS-level sandbox and that terminal access can bypass file-workspace and command-blocklist controls.
- Documented that v1.0.0 binaries are unsigned and retain Authenticode publisher-identity and tampering risk. The private personal-account draft has checksums but no GitHub artifact attestation or independent build provenance.

### Known limitations

- Full custom MCP tunnel use is documented for Business and Enterprise/Edu on ChatGPT web; Pro tunnel eligibility is not explicitly confirmed, Free/Plus availability is not documented, and mobile is unsupported.
- Workspace roles, RBAC, Lockdown, and tunnel associations apply; role propagation can take up to 30 minutes.
- Reviewed official sources do not establish tunnel-specific pricing; normal ChatGPT/API charges are separate.
- Foreground checks cannot make Windows input atomic or target-bound.
- The local dashboard has no documented built-in login/API-token authentication; Host-header and DNS-rebinding protections were not confirmed.
- `doctor --profile-file <yaml> --explain` is local preflight, not proof of ChatGPT authorization.
- The private personal-account draft cannot use GitHub Artifact Attestations and therefore lacks independent build provenance despite checksum verification.

### Verification status

Validation was performed locally and manually, not through GitHub Actions. The main suite passed 202/202 tests with 13 reported environment skips; repro passed 16/16; integration passed 3/3. Clean dependency installation, TypeScript and pinned Node 24.22.3 builds, Rust formatting/lint/tests/release build/self-test, installer/uninstaller security suites, managed-runtime checks, isolated desktop input, secret scans, dependency audits, and archive layout smoke checks passed. Exact evidence and unverified clean-machine/live-tunnel items are recorded in [docs/release-validation.md](docs/release-validation.md). The candidate remains a private draft pending owner review.
