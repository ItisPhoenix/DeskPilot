# Contributing

DeskPilot v1.0.0 is a private, source-first Windows project. Contributions must preserve the deny-by-default permission model, the strict foreground-lease rules, upstream attribution, and the approved DeskPilot dashboard/wordmark/DP monogram.

## Before you start

- Use a Windows 10/11 x64 development machine with an interactive desktop.
- Install Node.js 22.12 or later for development; use pinned Node.js **v24.22.3** for release work.
- Install Rust stable with the MSVC toolchain and the Windows SDK resource compiler (`rc.exe`).
- Install Microsoft WebView2 Runtime for source builds. The release installer provisions it automatically from Microsoft's official fwlink when missing.
- Work on a branch in a clean checkout. Do not commit directly to the default branch.
- Keep credentials, tunnel profiles, local state, screenshots, and tool logs out of commits and pull requests.

Read [README.md](README.md), [SECURITY.md](SECURITY.md), and [PRIVACY.md](PRIVACY.md) before changing permissions, desktop input, credentials, networking, or local data handling.

## Development setup

From the repository root:

```powershell
npm ci
npm run build
cargo build --release --manifest-path launcher/Cargo.toml --bin deskpilot
```

The MCP server output is under `dist\`. The native launcher is `launcher\target\release\deskpilot.exe`.

To inspect the control-window design without starting a tunnel or changing desktop controls:

```powershell
.\launcher\target\release\deskpilot.exe --preview
```

A source-built launcher needs the managed server, production dependencies, Node.js, the full official tunnel client, and a valid local profile before it can run as an installation. Use [README.md#build-from-source](README.md#build-from-source) and [PUBLISH.md](PUBLISH.md) for staging and release requirements.

## Security invariants

Do not weaken these behaviors without an explicit design and security review:

- Terminal, Files, Screen, Mouse, and Keyboard all default to disabled.
- Missing, unreadable, or malformed permission policy fails closed.
- Files-category calls are all denied when no explicit `allowedDirectories` workspace exists.
- DeskPilot's configuration/install trees and permission-policy file remain unavailable to MCP filesystem tools.
- Server-side URL reads stay disabled, and remote MCP callers cannot change server configuration.
- Terminal access is documented as outside the file-workspace boundary.
- `focus_window` requires Mouse permission and the exact window handle and PID.
- Mouse and keyboard tools never call `SetForegroundWindow` and never retry input automatically.
- Failed or uncertain input invalidates the foreground lease and requires explicit inspection and refocus before a manual retry.
- The residual race between the foreground check and `SendInput` remains documented.
- The runtime API key is restricted to Tunnels Read + Use and is removed before the MCP server starts.
- The YAML profile never contains a literal API key.
- Sign-in startup is opt-in and never starts the tunnel.
- The tunnel-client dashboard stays on loopback; remote UI is not supported.
- Managed upstream telemetry, remote feature flags, and feedback prompts stay disabled.
- Managed tool history stays metadata-only in memory by default; detailed history requires `DESKPILOT_TOOL_HISTORY=1`, and argument logging requires `DESKPILOT_TOOL_CALL_LOG=1`.
- The installer never launches DeskPilot by default; `-LaunchDeskPilot` remains explicit opt-in.
- DeskPilot is never described as an OS-level sandbox.

Changes to authentication, permissions, file boundaries, input delivery, credential handling, tunnel configuration, or the dashboard require regression tests and a security-focused review.

## Validation

Run the checks relevant to the change and record the actual result. A command in this document is not evidence that it passed.

| Command | Purpose |
|---|---|
| `npm run test:ci` | Build and run the project's CI test set. |
| `npm run test:changed` | Run tests selected for the current changes. |
| `npm run test:integration` | Run integration tests. |
| `npm run build` | Compile TypeScript and build UI runtime assets. |
| `cargo fmt --manifest-path launcher/Cargo.toml --all -- --check` | Check Rust formatting. |
| `cargo check --manifest-path launcher/Cargo.toml --bin deskpilot` | Check the native launcher. |
| `cargo build --release --manifest-path launcher/Cargo.toml --bin deskpilot` | Build the release launcher. |
| `.\launcher\target\release\deskpilot.exe --self-test` | Exercise DPAPI and Job Object behavior. |
| `npm audit --audit-level=high` | Audit npm dependencies. |
| `cargo audit` | Audit Rust dependencies from the launcher workspace. |

The test runners write reports under `test-results\`. Review skipped checks and platform limitations. Do not describe a skipped or unrun check as passing.

### Interactive desktop tests

Some scripts capture the real screen and send real mouse/keyboard input to a fixture window. Run them only in an isolated, consented Windows session where stray input cannot affect other work. Never point them at another person's application or a production desktop.

Interactive acceptance does not replace automated tests, and automated tests do not replace a clean installation and live ChatGPT tunnel check.

## Documentation

- Keep user-facing language plain, specific, and consistent with the implementation.
- Update README, privacy, security, publishing, upstream, notice, and changelog docs when behavior changes.
- Date official OpenAI service facts and link the official source. Mark unconfirmed eligibility, pricing, or security properties as unconfirmed.
- Do not invent screenshots, test results, release evidence, or service guarantees.
- Add image links only when the referenced file exists and has been reviewed.
- Preserve the approved dashboard, wordmark, DP monogram, upstream MIT copyright, and third-party notices.
- Do not claim an OS-level sandbox, authenticated dashboard, automatic tunnel startup, or authorization proof from `doctor`.

## Pull requests

A pull request should include:

- The problem and intended behavior.
- Files changed and the reason for each change.
- Security and privacy impact.
- Exact validation commands and observed results, including skips and failures.
- Screenshots only when they are real, reviewed, and free of private data.
- Documentation updates for user-visible or operational changes.

Keep unrelated cleanup out of the change. Do not include generated build output, local credentials, tunnel profiles, logs, test reports, or downloaded runtimes.

## Security reports

Report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md#report-a-vulnerability). Do not put exploit details, credentials, tunnel IDs, private screenshots, or unredacted logs in a public issue or pull request.

## Releases

Only maintainers prepare releases. Follow [PUBLISH.md](PUBLISH.md) for version checks, clean Windows validation, exact versioned artifacts, checksums, private draft handling, public-only artifact attestations, and the unsigned Authenticode residual-risk warning. The private personal-account draft is checksummed but unattested. Do not promote a draft or claim release verification without candidate-specific evidence.

## Attribution

Contributions to DeskPilot are made under the project's MIT license. Upstream Desktop Commander attribution and third-party notices must remain intact. DeskPilot is an independent derivative and is not endorsed by OpenAI, Microsoft, or the upstream maintainers.
