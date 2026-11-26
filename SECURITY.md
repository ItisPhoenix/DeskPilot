# Security policy

## Supported version

Security fixes target the latest DeskPilot release and the current default branch. DeskPilot v1.0.1 Beta is a public, source-first Windows pre-release.

## Report a vulnerability

Use GitHub's private vulnerability reporting on the repository. If it is unavailable, open a minimal public issue asking for a private contact channel; do not include exploit details, credentials, personal data, or sensitive logs.

Include:

- A concise description and impact.
- The affected DeskPilot version, tunnel-client version, and Windows version.
- Reproduction steps using a test account, a disposable workspace, and non-sensitive files.
- Any suggested mitigation.

Do not include real API keys, tunnel IDs, DPAPI files, screenshots containing private information, or unredacted opted-in tool-history and argument-log files.

## Security model

DeskPilot can execute commands, read and write files, capture the screen, and control the mouse and keyboard as the signed-in Windows user. **It is not an OS-level sandbox, privilege-separation boundary, or proof that a model request reflects user intent.**

The controls below reduce accidental exposure. They do not contain a malicious client, prompt injection, or a compromised account.

### Local permissions

All five categories are disabled on first launch:

| Category | Main capabilities |
|---|---|
| Terminal | Process creation, interaction, output, listing, and termination with the user's rights. |
| Files | Local file and document operations within configured workspace directories. |
| Screen | Primary-display capture and visible-window listing. |
| Mouse | Explicit window focus, pointer movement, clicks, and scrolling. |
| Keyboard | Literal typing and named keys/shortcuts into an explicitly focused target. |

A missing, unreadable, or malformed `permissions.txt` fails closed. Enabling Files does not grant access when no workspace is configured: every Files-category call is denied until `allowedDirectories` contains at least one explicit directory.

The desktop app's two Filesystem Permission modes (**Restricted Access**, the default, and **Full Filesystem Access**, a local opt-in) bound only Files-category tools. Restricted mode allows only `allowedDirectories`; an empty list denies all Files-category calls. Full mode allows ordinary files anywhere the Windows account can reach, except DeskPilot's configuration, policy, and installation paths. Neither mode limits Terminal, Screen, Mouse, Keyboard, or arbitrary commands run as the user; those have separate permission toggles.

Permissions are checked by the MCP server for each call. They are local policy, not authentication of the person or model making the request. Stop the tunnel before changing permissions if you need to prevent an in-flight call from using the previous policy.

### File and terminal boundaries

- `allowedDirectories` restricts Files-category tools. Terminal commands can access files outside those directories.
- DeskPilot's configuration/install trees and permission-policy file are denied to MCP filesystem tools, even if a workspace path contains them.
- Server-side URL reads are disabled. Download material into an approved workspace before using Files tools.
- Remote MCP callers cannot change server configuration or widen the file workspace.
- The command blocklist is advisory. Alternate interpreters, shell constructs, absolute paths, and other programs can bypass it.
- Configure file workspaces locally. Do not allow an untrusted prompt to expand them.
- DeskPilot does not claim that symlink checks, path normalization, or process supervision create OS-level isolation.

### Strict foreground lease

Mouse and keyboard input require a prior successful `focus_window` call for the exact window handle and PID. Focus requires Mouse permission. Input tools:

- Never call `SetForegroundWindow`.
- Never retry delivery automatically.
- Reject a target that is no longer foreground.
- Invalidate the lease after failed focus/input, a changed target, or server restart.
- Reject input while physical modifier keys or mouse buttons are held.

A residual race remains between the final foreground check and Windows `SendInput`. Focus can change after the check, so input may reach another window. Partial delivery and timeouts have uncertain outcomes. Inspect affected applications before any manual retry.

### Credentials and tunnel access

Use a restricted runtime API key with **Tunnels Read + Use**. An OpenAI admin key is not needed to run the tunnel client and must not be pasted into DeskPilot.

The launcher passes `CONTROL_PLANE_API_KEY` only to `tunnel-client`. The managed MCP launcher removes control-plane, OpenAI, admin, and tunnel-profile credential variables before starting the server. The YAML profile contains an environment reference, not the key.

DPAPI protects a remembered key at rest for the current Windows account. It does not protect against same-user malware, a compromised account, or an administrator. Removing the local key does not revoke it at OpenAI.

Platform tunnel permissions and ChatGPT custom MCP access are separate. Workspace roles, RBAC, Lockdown, app creation/publishing rules, and tunnel associations apply. A new role assignment can take up to 30 minutes to propagate. `tunnel-client doctor --profile-file <yaml> --explain` is local preflight, not proof of ChatGPT authorization.

### Local dashboard

The tunnel-client admin dashboard is reached through DeskPilot's loopback proxy at an installation-specific `http://127.0.0.1:8080/<random>/ui` URL; the upstream listener is restricted to `127.0.0.1:18080` behind the same 144-bit random base path. The proxy enforces an exact loopback `Host` allowlist, rejects routes outside that base path, and rejects cross-site unsafe browser actions. It verifies supervised upstream ownership before forwarding and stops on ownership loss. This mitigates direct-browser bypass of the proxy and the upstream v0.0.21 read endpoints' lack of independent `Host` validation. The installer enforces `allow_remote: false` and rewrites upgraded profiles.

The dashboard still has no documented built-in login or API-token authentication. Treat it as an unauthenticated local operator surface. Never enable remote UI, bind either dashboard port to a non-loopback address, reverse-proxy it, or forward port 8080 or 18080.

### Process lifecycle

The native launcher assigns the tunnel-client process to a Windows Job Object configured to terminate the process tree when the job closes. Exiting DeskPilot stops the supervised tunnel process. This is lifecycle control, not a security sandbox.

`Ctrl+Alt+Shift+F12`, **Emergency stop**, and **Exit DeskPilot** stop the local tunnel. They do not undo actions already completed.

## Data handling

The managed runtime disables inherited upstream telemetry, remote feature-flag fetching, and feedback prompts. OpenAI service and ChatGPT workspace logging are separate and still apply.

Managed tool history is metadata-only in memory by default: timestamp, tool name, duration, and outcome. Arguments and output are omitted, existing detailed history is not loaded, and `tool-history.jsonl` is not written. `deskpilot-tool-call.log` is also disabled by default. Desktop operations omit typed text, coordinates, and screenshots.

Detailed history requires `DESKPILOT_TOOL_HISTORY=1`; argument logging requires `DESKPILOT_TOOL_CALL_LOG=1`. These are explicit owner opt-ins for the managed server environment. Opted-in files can contain sensitive arguments and output, and the argument log is unredacted. Local `activity.log` records launcher lifecycle events rather than tool payloads. Protect the Windows account and redact diagnostics before sharing them.

See [PRIVACY.md](PRIVACY.md) for local paths, network behavior, retention, and deletion.

## Supply chain and unsigned binaries

The manual release publishes `SHA256SUMS.txt` for `DeskPilot-v1.0.1-windows-x64.zip` and `Install-DeskPilot-v1.0.1.ps1`; users should verify both before installation. The installer verifies the DeskPilot archive against that manifest, verifies the full official `tunnel-client-v0.0.21-windows-amd64.zip` against its publisher checksum, and verifies pinned Node.js **v24.22.3** against its official checksum. It requires a valid OpenJS Foundation Authenticode signature for Node.js.

When WebView2 is missing, the installer downloads the bootstrapper from Microsoft's official fwlink, requires a valid Microsoft Corporation Authenticode signature, checks hash stability before execution, installs silently, and verifies the Runtime in the registry. Failure aborts before the DeskPilot application swap.

DeskPilot v1.0.1 Beta executables are **not signed with Authenticode**. The manual release is checksummed but **unattested** because it was published without GitHub Actions. Checksums can detect changes only when the expected digest comes from a trusted channel; they do not identify a signed publisher, provide independent build provenance, or remove SmartScreen warnings. A compromised repository or release account can still substitute both artifacts and checksums. Follow [PUBLISH.md](PUBLISH.md); do not disable operating-system security warnings to bypass verification.

## Known limitations

- Terminal tools can perform arbitrary actions with the signed-in user's privileges.
- File workspaces and command blocking do not constrain terminal commands.
- Prompt injection, malicious files, and compromised ChatGPT or Windows accounts remain in scope for the user's threat model.
- Foreground checks cannot make Windows input atomic or target-bound.
- The local dashboard has no documented built-in authentication and must remain loopback-only.
- DPAPI does not protect secrets from an attacker already running as the user.
- The tunnel carries tool data through OpenAI and does not hide it from the connected services.
- Unsigned DeskPilot binaries leave residual publisher-identity and tampering risk.
- The manual Beta release has checksums but no GitHub artifact attestation, so it lacks independent build provenance.
- Clean-VM installation, live ChatGPT connectivity, and physical desktop controls were not verified for this Beta.

For workloads requiring hard isolation, use a separately managed virtual machine or dedicated workstation. DeskPilot does not create or claim that isolation.

## License and responsibility

DeskPilot is distributed under the MIT License. It is provided "as is," without warranty. Users are responsible for securing their accounts, devices, workspaces, tool permissions, and review of requested actions. Upstream attribution and third-party notices are retained in [NOTICE](NOTICE) and [UPSTREAM.md](UPSTREAM.md).
