# Privacy

DeskPilot keeps its configuration, credential file, launcher activity, and any explicitly enabled diagnostic logs on the Windows device. Managed tool history is metadata-only in memory by default. It uses the official OpenAI tunnel client to connect a local MCP server to ChatGPT. This document describes the managed DeskPilot v1.0.0 runtime, not every feature retained from upstream source.

## Data stored locally

DeskPilot uses `%LOCALAPPDATA%\DeskPilot` for runtime state:

| Path | Data and sensitivity |
|---|---|
| `runtime-key.dpapi` | Optional runtime API key encrypted with Windows DPAPI for the current account. |
| `tunnel-client.yaml` | Tunnel ID, control-plane URL, loopback listener, and local stdio command. The key is an environment reference, not a literal value. |
| `permissions.txt` | Five-category permission mask. A new installation starts with all categories disabled. |
| `activity.log` | Launcher status and lifecycle events. Secret values and credential contents are not recorded. |
| `tool-history.jsonl` | Detailed history is not loaded or written by default. `DESKPILOT_TOOL_HISTORY=1` opts into arguments and bounded result previews, which may contain command text, file paths, file content, or output. |
| `deskpilot-tool-call.log` | Argument logging is disabled by default. `DESKPILOT_TOOL_CALL_LOG=1` opts into tool names and unredacted JSON arguments; the file rotates at 10 MiB and rotated files are not automatically deleted. |
| `config.json` | MCP server settings, including the `allowedDirectories` file workspace. |
| `config.json.corrupt.*` | Optional backups made when a corrupt configuration is recovered. |
| `launch-on-sign-in.txt` | Whether the user explicitly enabled sign-in startup. |
| `runtime/` | Portable Node.js v24.22.3 runtime and publisher license files. |
| `bin/` | Official tunnel-client v0.0.21 files and publisher license/notice files. |

Managed sessions retain only recent metadata in memory by default: timestamp, tool name, duration, and outcome. Arguments and output are omitted, existing detailed history is not loaded, and no `tool-history.jsonl` file is written. Desktop operations also omit typed text, coordinates, and screenshot data.

Detailed persistence requires the Windows owner to set `DESKPILOT_TOOL_HISTORY=1` in the managed server environment. Argument logging separately requires `DESKPILOT_TOOL_CALL_LOG=1`. Detailed history is bounded but is not a secure audit store; large outputs are replaced with omission markers. Opted-in logs can contain sensitive arguments and output.

Protect the Windows account and review local files before sharing diagnostics. Do not publish `runtime-key.dpapi`, tunnel profiles, opted-in argument logs, detailed history, screenshots, or configuration files without redaction.

## Network communication

### Tunnel and tool traffic

When the user explicitly starts the tunnel, the official `tunnel-client` communicates with OpenAI over outbound HTTPS. The default control-plane destination is `api.openai.com:443` under `/v1/tunnels/*`. The tunnel requires no inbound firewall port.

MCP tool arguments and results pass through the configured tunnel to the connected OpenAI service and ChatGPT workspace. Depending on the tool, this can include command text, file paths, file content, process output, window titles, screenshots, mouse coordinates, or typed text. DeskPilot does not make this traffic private from OpenAI or the connected workspace.

Secure MCP Tunnel transport traffic is distinct from normal app-level product logging. OpenAI documents that normal ChatGPT app invocation and authentication lifecycle logging still applies when a custom app is reached through a tunnel. Service retention and handling are governed by the applicable OpenAI and workspace policies, not by DeskPilot's local settings.

### Installation and runtime downloads

The installer may contact:

- GitHub for `DeskPilot-v1.0.0-windows-x64.zip`, release metadata, and `SHA256SUMS.txt`.
- GitHub for the official `openai/tunnel-client` v0.0.21 full Windows amd64 archive and its checksums.
- `nodejs.org` for the pinned Node.js **v24.22.3** Windows x64 archive.
- Microsoft's official WebView2 fwlink for the bootstrapper when the Runtime is missing.
- OpenAI Platform pages when opening tunnel settings.

For WebView2, the installer verifies a valid Microsoft Corporation Authenticode signature, checks that the hash is unchanged before execution, installs silently, and verifies the Runtime in the registry. A setup failure aborts before the DeskPilot application swap.

The release workflow generates `SHA256SUMS.txt` for `DeskPilot-v1.0.0-windows-x64.zip` and `Install-DeskPilot-v1.0.0.ps1`; users should verify both before installation. The installer verifies the DeskPilot archive against that manifest, verifies the tunnel-client archive against its publisher checksum, and verifies the pinned Node.js checksum. It requires a valid OpenJS Foundation Authenticode signature for Node.js. DeskPilot and tunnel-client remain unsigned, so their checksums do not establish a code-signing publisher identity. These checks do not establish an OpenAI or Microsoft account entitlement.

### Other network-capable features

The tunnel's outbound-only design does not mean every DeskPilot feature is network-isolated:

- Server-side URL reads are disabled for MCP callers. Material must be downloaded into an approved workspace before Files tools can read it.
- Terminal tools can run programs that access the network.
- PDF generation uses an existing system Chrome installation. DeskPilot does not provision a browser.

Workspace and permission controls still apply, but they are not a general network firewall.

## Telemetry, remote flags, and feedback

The managed launcher sets runtime controls that:

- Disable inherited upstream telemetry through `DESKTOP_COMMANDER_DISABLE_TELEMETRY=1` and a disabled telemetry configuration default.
- Disable remote feature-flag fetching through `DESKPILOT_DISABLE_REMOTE_FLAGS=1`.
- Do not expose the inherited feedback tool in the managed release. Remote feature flags stay disabled, so the inherited survey prompts remain inactive.
- Avoid running the inherited installation analytics tracker as part of DeskPilot's Windows installation.

Upstream source and tests retained for compatibility do not mean those behaviors are enabled in the managed runtime. These controls do not disable OpenAI service logging, ChatGPT workspace logging, installer downloads, or network activity from user-requested terminal commands.

## Credentials

Use a restricted runtime API key with **Tunnels Read** and **Tunnels Use**. Do not use an OpenAI admin key. The principal behind the key must also have the required tunnel permissions for the target tunnel.

If **Remember** is selected, the native launcher encrypts the key with Windows DPAPI for the current Windows account. The launcher passes it to `tunnel-client` through `CONTROL_PLANE_API_KEY`. `managed-launcher.mjs` removes that variable, `OPENAI_API_KEY`, `OPENAI_ADMIN_KEY`, and tunnel-profile environment variables before starting the MCP server.

DPAPI is at-rest protection, not a defense against same-user malware, a compromised Windows account, or an administrator. The key can still be exposed while present in a process environment. **Forget** deletes the local DPAPI file but does not revoke the key at OpenAI.

## Local dashboard

The official tunnel-client admin dashboard binds to `127.0.0.1:8080` by default. The reviewed documentation describes limited `Origin`/`Referer` checks, but no documented built-in login or API-token authentication. Host-header validation and DNS-rebinding protection were not confirmed.

Do not enable remote UI, change the listener to a non-loopback address, reverse-proxy it, or forward port 8080. Treat the dashboard as an unauthenticated local operator surface.

## Retention and deletion

Local data remains until the user removes it or runs the uninstaller with `-RemoveUserData`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-DeskPilot.ps1 -RemoveUserData
```

That removes `%LOCALAPPDATA%\DeskPilot`, including the DPAPI key, tunnel profile, launcher activity, any opted-in argument log or detailed history, configuration, and downloaded runtimes. Installer update backups under `%LOCALAPPDATA%\Programs\DeskPilot.backup-*` are separate and require review and manual removal.

Uninstalling does not delete the ChatGPT custom MCP connection, revoke the runtime API key, delete the OpenAI tunnel, or remove records held by OpenAI or the ChatGPT workspace. Perform those remote actions separately when they are no longer needed.
