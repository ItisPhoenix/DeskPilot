# Upstream attribution

DeskPilot is based on [Desktop Commander](https://github.com/wonderwhy-er/DesktopCommanderMCP), originally created by Eduard Ruzga and maintained by its contributors.

The upstream source is distributed under the MIT License:

```text
Copyright (c) 2024-2025 Eduard Ruzga and Desktop Commander Contributors
```

DeskPilot retains the upstream MIT license and required attribution notices. The upstream project remains the source of the general MCP server functionality and many inherited utilities and tests. The full license text is in [LICENSE](LICENSE), and release notices are in [NOTICE](NOTICE).

The cleaned DeskPilot source baseline is upstream commit `9a101b17e44577f0baefa4c7120f087881c5cc56` (`v0.3.4`). The target repository imports a sanitized source snapshot rather than the full upstream Git history because removed legacy files in that history contain personal Windows path examples and synthetic credential fixtures. Upstream history remains available at the linked upstream repository; no upstream authorship or license notice is removed from the shipped source.

## DeskPilot-specific work

DeskPilot v1.0.1 adds or changes:

- A native Windows launcher, system-tray experience, and approved DeskPilot dashboard/wordmark/DP monogram.
- Private desktop-control MCP tools for visible windows, primary-screen capture, mouse, and keyboard.
- Strict explicit foreground leases for input, with no automatic refocus or input retry and a documented residual `SendInput` race.
- Five local permission categories with deny-by-default behavior and fail-closed handling of missing or invalid policy.
- A file-workspace requirement that denies every Files-category call when no workspace is configured, with protected DeskPilot runtime paths and no remote configuration changes.
- Disabled server-side URL reads for MCP callers.
- A supervised official OpenAI tunnel-client process using the full Windows amd64 client.
- Restricted runtime-key handling with optional Windows DPAPI storage and credential-variable removal before the MCP server starts.
- Per-user installation, manual tunnel start/stop, and opt-in sign-in startup.
- Windows-focused source builds, exact versioned release artifacts, manual public Beta releases, checksums, and optional public-repository artifact attestation support. Manual releases remain unattested unless a separate attested workflow is run and verified.
- Metadata-only in-memory managed tool history by default, with detailed history and argument logging behind explicit environment-variable opt-ins.
- Managed runtime settings that disable inherited upstream telemetry, remote feature-flag fetching, and feedback prompts.
- Local state, privacy, security, troubleshooting, uninstall, and release documentation for the Windows host model.

## Inherited source and compatibility tests

DeskPilot retains upstream source files and tests where they remain useful for compatibility or validation. Their presence does not mean every inherited feature is exposed or enabled in the managed DeskPilot runtime. The supported v1.0.1 product is the Windows host, native launcher, managed MCP server, and official tunnel path described in [README.md](README.md).

## Independence and trademarks

The DeskPilot project name, dashboard, wordmark, DP monogram, launcher, and DeskPilot-specific modifications are maintained independently. DeskPilot does not claim ownership of the upstream project or its trademarks.

DeskPilot is not an official OpenAI product and is not affiliated with or endorsed by OpenAI, Microsoft, Eduard Ruzga, or the upstream Desktop Commander maintainers.
