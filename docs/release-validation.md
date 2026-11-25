# DeskPilot v1.0.0 local release validation

Validation date: **2026-11-25**

## Release method

The owner authorized a manual v1.0.0 release. Automatic `push`, `pull_request`, and tag triggers are disabled in the retained GitHub Actions workflows; they remain available for future `workflow_dispatch` use. The checks below were run locally on Windows. **No GitHub Actions pass is claimed.**

The release tag identifies the exact source commit used for packaging. Tracked release files are copied from `git archive` for that commit. Generated `dist`, production `node_modules`, and `DeskPilot.exe` come from the matching audited source and lockfiles; the installer is byte-compared with the committed installer.

## Environment

- Windows 11 Pro 10.0.26300 x64
- Windows PowerShell 5.1.26100.9818
- Full-suite runtime: Node.js 24.22.1, npm 11.19.1
- Installer-pinned runtime check: Node.js 24.22.3, npm 11.19.1
- Rust 1.100.0

## Dependency and build checks

| Command | Result |
|---|---|
| `npm ci` | Passed; 599 packages installed; 0 vulnerabilities |
| Production-only `npm ci --omit=dev` | Passed; 492 packages; 0 vulnerabilities |
| `npm audit --audit-level=high` | Passed; 0 vulnerabilities |
| `npm run build` | Passed |
| Node 24.22.3 `npm run build` | Passed |
| Node 24.22.3 managed-launcher acceptance script | Passed |
| `cargo fmt --check` | Passed |
| `cargo check --locked` | Passed |
| `cargo clippy --locked --all-targets -- -D warnings` | Passed |
| `cargo test --locked` | 25 passed, 0 failed |
| `cargo build --release --locked` | Passed |
| Native `--self-test` | `DPAPI_AND_JOB_PASS` |
| `cargo audit --file launcher/Cargo.lock` | 0 known vulnerabilities; 2 warnings |

Rust audit warnings:

- `proc-macro-error 1.0.4` is unmaintained; no fixed upgrade is available.
- `glib 0.18.5` has an unsoundness advisory fixed in >=0.20.0. Current `wry 0.57.3` constraints require the 0.18 GTK stack, so the dependency was not upgraded in v1.0.0.

## Functional and regression checks

| Command | Result |
|---|---|
| `node test/run-all-tests.js --no-build` | 202 passed, 0 failed, 13 environment skips |
| `node test/repro/run-repro.js` | 16 passed, 0 failed |
| `node test/integration/run-all-integration-tests.js` | 3 passed, 0 failed |
| Installer security suite | 198 checks passed |
| Uninstaller security suite | 57 checks passed |
| Managed launcher policy/credential script | Passed |
| Isolated live desktop input fixture | 13 checks passed |
| Production release-layout startup smoke | `RELEASE_LAYOUT_PASS` |
| Extracted-archive release-layout startup smoke | `RELEASE_LAYOUT_PASS` |
| Workflow YAML parse and `actionlint` | Passed |
| Documentation links/fences/stale-reference checks | Passed |
| Current-tree secret/privacy scan | Passed |
| Sanitized snapshot-history secret/privacy scan | Passed |

The 13 main-suite skips are reported by the test runner and are not counted as passes. They cover unavailable `pwsh`, a OneDrive-redirected PowerShell profile, Windows-inapplicable POSIX/process-group cases, a second Windows volume requiring admin rights, and file-symlink creation requiring Developer Mode or elevation.

## Desktop and lifecycle evidence

The live fixture verified real mouse movement, clicks, Unicode typing, shortcuts, scrolling, focus-loss rejection without retry, explicit refocus, and native wrong-PID rejection against an isolated Windows form. The original installation under `D:\DesktopCommander` was not stopped or modified.

Rust tests and the native self-test verify startup opt-in behavior, no automatic tunnel start, supervised port ownership, Job Object descendant termination, policy/runtime validation, tray recovery decisions, and fresh self-test evidence.

## Official dependency verification

- Node.js v24.22.3 Windows x64 ZIP SHA-256 matched the official `SHASUMS256.txt`.
- `node.exe` had a valid OpenJS Foundation Authenticode signature.
- `tunnel-client-v0.0.21-windows-amd64.zip` SHA-256 matched the official publisher manifest.
- The Microsoft WebView2 bootstrapper had a valid Microsoft Corporation Authenticode signature.
- DeskPilot's executable reports product version `1.0.0` and file version `1.0.0.0`; it is intentionally unsigned.

## Artifact validation

The manual packaging process:

1. Creates `git archive` output from the release commit.
2. Copies tracked release documentation, licenses, notices, scripts, and screenshots from that archive.
3. Adds the matching generated server build, production dependencies, and native executable.
4. Byte-compares the versioned installer with the committed installer.
5. Rejects credentials, profiles, local state, remote-device output, feedback output, and development dependencies.
6. Creates `DeskPilot-v1.0.0-windows-x64.zip` and `Install-DeskPilot-v1.0.0.ps1`.
7. Generates `SHA256SUMS.txt` from those exact files.
8. Extracts the ZIP and runs the release-layout startup/default-deny smoke test.
9. Downloads the uploaded GitHub assets and verifies their sizes and SHA-256 values against the local candidates.

The authoritative artifact sizes and hashes are recorded in `SHA256SUMS.txt` and the GitHub draft-release metadata. They are not duplicated inside the archive, avoiding a circular digest.

## Not verified locally

- Installation on a separate clean Windows machine or VM.
- End-to-end ChatGPT discovery/tool calls with an owner-controlled eligible workspace and real tunnel.
- Physical emergency-hotkey input and interactive tray clicks while the original DeskPilot installation remains running.
- GitHub Actions execution; workflow triggers are intentionally manual-only for this draft.
- External tunnel-client Host-header/DNS-rebinding behavior and cloud backend authorization.

These limitations do not get represented as passed checks.

## Readiness

The candidate is ready for **private draft review** with the documented limitations. It is not approved for public release or promotion from draft. DeskPilot is not an OS-level sandbox; Terminal permission can bypass file-workspace and command-blocklist controls. The private draft is checksummed but unattested, and DeskPilot binaries are not Authenticode-signed.
