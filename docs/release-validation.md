# DeskPilot v1.0.1 Beta release validation

Validation date: **2026-11-25**

## Release method

The owner authorized a manual public v1.0.1 Beta pre-release after confirmed release-blocking security issues were resolved. Automatic `push`, `pull_request`, and tag triggers are disabled in the retained GitHub Actions workflows; they remain available for future `workflow_dispatch` use. The checks below were run locally on Windows. **No GitHub Actions pass is claimed.**

The release tag identifies the exact source commit used for packaging. Tracked release files are copied from `git archive` for that commit. Generated `dist`, production `node_modules`, and `DeskPilot.exe` come from the matching source and lockfiles; the installer is byte-compared with the committed installer extracted from that archive.

## Environment

- Windows 11 Pro 10.0.26300 x64
- Windows PowerShell 5.1.26100.9818
- Full-suite runtime: Node.js 24.22.1, npm 11.19.1
- Installer-pinned runtime check: Node.js 24.22.3, npm 11.19.1
- Rust 1.100.0

## Reused successful evidence

The following evidence was produced for the audited v1.0.0 candidate and reused for v1.0.1 where the affected code was unchanged:

| Command | Result |
|---|---|
| `npm ci` | Passed; 599 packages installed; 0 vulnerabilities |
| Production-only `npm ci --omit=dev` | Passed; 492 packages; 0 vulnerabilities |
| `npm audit --audit-level=high` | Passed; 0 vulnerabilities |
| `npm run build` | Passed |
| Node 24.22.3 `npm run build` | Passed |
| Node 24.22.3 managed-launcher acceptance script | Passed |
| `node test/run-all-tests.js --no-build` | 202 passed, 0 failed, 13 environment skips |
| `node test/repro/run-repro.js` | 16 passed, 0 failed |
| `node test/integration/run-all-integration-tests.js` | 3 passed, 0 failed |
| Uninstaller security suite | 57 checks passed |
| Managed launcher policy/credential script | Passed |
| Isolated live desktop input fixture | 13 checks passed |
| Current-tree and sanitized-history secret/privacy scans | Passed |
| Workflow YAML parse and `actionlint` | Passed |
| Official Node/tunnel checksums and Microsoft/OpenJS signatures | Passed |

## v1.0.1 patch evidence

The OneDrive shortcut, version-metadata, privacy-build, and packaging changes were rechecked on the v1.0.1 candidate:

| Command | Result |
|---|---|
| `powershell -File test/deskpilot-installer-security.test.ps1` | 232 checks passed, including full transaction rollback/commit and OneDrive trusted-ancestor cases |
| `powershell -File test/deskpilot-uninstaller-security.test.ps1` | 63 checks passed, including OneDrive Desktop acceptance and rejection of links below it |
| `npm run build` (Node 24.22.1) | Passed |
| `node test/run-all-tests.js --no-build` | 202 passed, 0 failed, 13 environment skips |
| `node test/repro/run-repro.js` | 16 passed, 0 failed |
| `node test/integration/run-all-integration-tests.js` | 3 passed, 0 failed |
| `npm run scan:secrets` | Passed; 465 worktree text blobs scanned |
| `npm audit --audit-level=high` | Passed; 0 vulnerabilities |
| `npm run test:managed` | Passed; deny-by-default, credential isolation, and MCP acceptance checks |
| `cargo fmt --all -- --check` | Passed |
| `cargo check --locked --bin deskpilot` | Passed (launcher v1.0.1) |
| `cargo clippy --locked --all-targets -- -D warnings` | Passed |
| `cargo test --locked` | 39 passed, 0 failed |
| `cargo audit --file launcher/Cargo.lock` | 0 vulnerabilities; the two documented `proc-macro-error`/`glib` warnings remain and are absent from the Windows MSVC target graph |
| `scripts/build-private-release.ps1` | `NATIVE_BUILD_PRIVACY_PASS`; no private build path strings in `DeskPilot.exe` |
| `deskpilot.exe --self-test` | Exit 0; `%LOCALAPPDATA%\DeskPilot\self-test-modern.txt` = `DPAPI_AND_JOB_PASS` |
| Executable version resource | `FileVersion=1.0.1.0`, `ProductVersion=1.0.1` |
| Version identifiers | `package.json`, `package-lock.json`, `src/version.ts`, `launcher/Cargo.toml`, `launcher/Cargo.lock`, `launcher/build.rs`, installer pin, and installer test pin all agree on 1.0.1 |
| Installed branding assets | `icon.png`, `deskpilot.ico`, `deskpilot-wordmark.svg`, `deskpilot-mark.svg` SHA-256 unchanged; no branding asset was modified or regenerated |

The 13 main-suite skips are reported by the test runner and are not counted as passes. They cover unavailable `pwsh`, a OneDrive-redirected PowerShell profile, Windows-inapplicable POSIX/process-group cases, a second Windows volume requiring admin rights, and file-symlink creation requiring Developer Mode or elevation.

## Dashboard DNS-rebinding mitigation

Review of the pinned upstream source at `openai/tunnel-client` commit `714f2d67844b660af25754f1d19b0360b346b13b` (`v0.0.21`) found:

- Loopback transport checks ignore forwarded headers and reject non-loopback peers.
- Unsafe browser actions have same-origin checks, including an explicit DNS-rebinding test.
- Read-only dashboard endpoints do not independently validate the HTTP `Host` header. A browser DNS-rebinding read path therefore remained plausible.
- No newer tunnel-client release was available at review time, and upstream `main` retained the same read-endpoint behavior.

DeskPilot now owns the public loopback listener at `127.0.0.1:8080` and forwards only to tunnel-client at `127.0.0.1:18080`. A cryptographically random 144-bit `/deskpilot-*` base path prevents predictable direct access to sensitive upstream routes. The proxy:

- Accepts only `127.0.0.1:8080` or `localhost:8080` Host values.
- Rejects every sensitive route outside the installation's random base path.
- Rejects missing, duplicate, malformed, or ambiguous request framing.
- Rejects cross-site unsafe browser actions and non-local action origins.
- Removes hop-by-hop headers, forces connection close, and streams responses without buffering, preserving SSE behavior.
- Refuses non-loopback proxy endpoints.
- Verifies supervised upstream ownership before and after connecting; it does not forward to a foreign listener.
- Limits active connections to 32, applies a total 15-second header deadline, and tracks/shuts down/joins client, upstream, and worker threads on stop.

The installer enforces the upstream listener, `allow_remote: false`, `open_browser: false`, a freshly generated random base path, the official OpenAI control-plane URL, and the managed runtime-key reference on every install or repair. It removes Cloudflare process selectors, CA bundles, and proxy overrides from existing profiles, including quoted, flow-style, and Unicode-escaped YAML keys; the launcher rejects any quoted-key or flow-mapping syntax in managed profiles. The launcher independently rejects a profile containing those settings in any syntax, scrubs security-sensitive inherited environment variables (including `CLOUDFLARED_*`, `CA_BUNDLE`, and proxy variables), passes enforcing runtime flags, verifies ownership of both ports, and stops the supervised upstream before joining proxy workers on ownership loss or shutdown.

Focused evidence for the changed code:

| Command | Result |
|---|---|
| `cargo fmt --all -- --check` | Passed |
| `cargo clippy --locked --all-targets -- -D warnings` | Passed |
| `cargo test --locked` | 39 passed, 0 failed |
| Live mock proxy tests | Non-local Host received HTTP 403 and never reached upstream; predictable routes were rejected; untrusted upstream received HTTP 502 with no forwarding; local Host received HTTP 200; SSE streamed incrementally |
| Installer security suite | 203 checks passed |

The installer sanitizes Cloudflare process selectors, CA bundles, and proxy overrides from existing profiles, and rotates the dashboard base path on every install or repair so an untrusted preserved token cannot remain.
| `cargo tree --locked --target x86_64-pc-windows-msvc` | `glib` and `proc-macro-error` absent from the Windows dependency graph |

The dashboard remains an unauthenticated local operator surface. The proxy mitigates browser DNS-rebinding reads; it does not authenticate local processes or replace an OS-level sandbox.

## Rust dependency review

`cargo audit --file launcher/Cargo.lock` reported 0 known vulnerabilities and 2 warnings:

- `proc-macro-error 1.0.4` is unmaintained; no fixed upgrade is available. It is a build-time dependency and is absent from the Windows MSVC target graph.
- `glib 0.18.5` has an unsoundness advisory fixed in >=0.20.0. Current `wry 0.57.3` constraints require the 0.18 GTK stack. It is absent from the Windows MSVC target graph.

These warnings remain disclosed; neither is represented as fixed.

## Build and artifact checks

The changed launcher is rebuilt from the final source commit. The unchanged TypeScript server build and verified production dependency tree are reused. The final candidate must pass:

- Rust release build and native `--self-test`.
- Executable product/file version checks.
- Exact-commit archive assembly and installer/source byte comparison.
- Required/forbidden archive-entry inspection.
- Extracted-archive `RELEASE_LAYOUT_PASS` startup/default-deny smoke.
- Independent SHA-256 verification.
- Downloaded GitHub asset verification against the local candidates.

The authoritative artifact sizes and hashes are recorded in `SHA256SUMS.txt` and the GitHub release metadata. They are not duplicated inside the archive, avoiding a circular digest.

## v1.0.1 artifact verification

| Check | Result |
|---|---|
| Tracked files extracted with `git archive` for the release commit | Passed; installer byte-compared with the committed blob (SHA-256 `2f79ce2f…c2e9c9`) |
| `node scripts/test-release-layout.mjs <stage>` | `RELEASE_LAYOUT_PASS` |
| Required/forbidden archive entries | Passed; no local config, policy, DPAPI key, tunnel profile, test report, dev dependency, or source/test tree |
| `SHA256SUMS.txt` independent verification | Passed for both distribution files |
| Decompressed asset and binary privacy scan | 19,767 files scanned across the extracted archive, including `DeskPilot.exe`, all DLL/`.node` binaries, and brand images; 0 personal paths, tunnel IDs, tokens, or real credentials |
| Third-party pattern review | 22 generic-pattern hits in upstream `node_modules` only (JSDoc examples, a README sample password, PEM-header string checks, and a public JWT test vector); reviewed as benign, no personal information or usable credential |
| Native binary path check | `NATIVE_BUILD_PRIVACY_PASS`; no `USERPROFILE`, `D:\DeskPilot`, `CARGO_HOME`, `RUSTUP_HOME`, or `TEMP` path strings |
| Branding assets | SHA-256 values unchanged; assets neither modified nor regenerated |

## Not verified for this Beta

- Installation on a separate clean Windows machine or VM. The available VMware VM required a password for VIX access, and no password-free Windows Sandbox was installed.
- End-to-end ChatGPT discovery/tool calls with an eligible workspace and real tunnel. No separate authorized runtime key or tunnel was supplied.
- Physical emergency-hotkey input, tray clicks, Start/Stop controls, single-instance behavior, window close/reopen/exit, and opt-in Windows startup.
- External tunnel-client cloud backend authorization and behavior beyond the reviewed pinned source.
- GitHub Actions execution; workflow triggers are intentionally manual-only.

These limitations are not represented as passed checks.

## Readiness

The candidate is suitable for a **public v1.0.1 Beta pre-release** with the documented limitations. It is not represented as a fully accepted stable release. DeskPilot is not an OS-level sandbox; Terminal permission can bypass file-workspace and command-blocklist controls. The manual Beta is checksummed but unattested, and DeskPilot binaries are not Authenticode-signed.
