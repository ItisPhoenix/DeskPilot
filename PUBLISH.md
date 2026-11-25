# Release process

DeskPilot v1.0.1 Beta is a public, manually published GitHub pre-release for Windows x64. Automatic `push`, `pull_request`, and tag triggers are disabled in the retained workflow files; they remain available for future `workflow_dispatch` use. No GitHub Actions success is claimed.

## Distribution policy

- Publish the source repository publicly only after confirmed release-blocking security issues are resolved and the Beta limitations are documented.
- Use a GitHub pre-release tagged `v1.0.1` and publish manually with GitHub CLI.
- Publish exactly these distribution artifacts:
  - `DeskPilot-v1.0.1-windows-x64.zip`
  - `Install-DeskPilot-v1.0.1.ps1`
  - `SHA256SUMS.txt`
- The manual Beta is checksummed but **unattested** because no GitHub Actions artifact attestation was generated.
- Do not bundle the OpenAI tunnel-client, Node.js runtime, or Microsoft WebView2 Runtime in the DeskPilot archive. The installer provisions them separately.
- Preserve `LICENSE`, `NOTICE`, and upstream attribution in the source and release archive.

## Release gates

A release is not ready until every applicable gate has actual evidence recorded in `docs/release-validation.md`:

1. Version metadata, source version, launcher metadata, and the `vX.Y.Z` tag agree.
2. Focused tests for changed code pass, and existing successful suite evidence is reused without being represented as a fresh run.
3. The archive contains the required runtime files, production-only dependencies, scripts, documentation, licenses, and notices, with no credentials or local state.
4. `SHA256SUMS.txt` contains the final SHA-256 digests for the archive and installer, and both are independently checked.
5. Confirmed release-blocking security issues are fixed and verified. Unverified real-world checks are explicitly disclosed for a Beta.
6. The unsigned-binary warning, unattested manual-release status, supported Windows target, service-availability date, and known limitations are present in the release notes.
7. The repository and release visibility match the approved publication mode, and anonymous access is verified after publication.

Never describe an unperformed clean-machine, live-account, or physical test as passed.

## Prepare the candidate

Use Node.js **v24.22.3** for the release build, matching the pinned installer runtime. From a clean checkout on Windows x64:

```powershell
npm run sync-version
npm ci
npm run build
npm audit --audit-level=high
cargo fmt --manifest-path launcher/Cargo.toml --all -- --check
cargo check --locked --manifest-path launcher/Cargo.toml --bin deskpilot
cargo clippy --locked --manifest-path launcher/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path launcher/Cargo.toml
cargo build --release --locked --manifest-path launcher/Cargo.toml --bin deskpilot
.\launcher\target\release\deskpilot.exe --self-test
```

Run the Rust dependency audit from the launcher workspace. Review all warnings, skipped checks, and platform limitations. A command that was not run must be reported as not run.

Interactive desktop checks can capture the real screen and send real mouse/keyboard input. Run them only in an isolated, consented Windows session. They are not a substitute for automated checks, and automated checks are not a substitute for an interactive acceptance run.

## Assemble the Windows artifacts

The archive layout is:

```text
DeskPilot.exe
server/
  managed-launcher.mjs
  dist/
  node_modules/
  package.json
LICENSE
NOTICE
UPSTREAM.md
README.md
PRIVACY.md
SECURITY.md
CONTRIBUTING.md
CHANGELOG.md
PUBLISH.md
RELEASE_NOTES.md
docs/
Install-DeskPilot-v1.0.1.ps1
Uninstall-DeskPilot.ps1
```

`server/node_modules` must contain production dependencies only. The archive must not contain credentials, tunnel profiles, local state, test reports, development dependencies, or an OpenAI admin key.

Every ZIP entry name must use forward slashes and a path relative to the archive root, with no leading `./`, no drive/root prefix, and no `.` or `..` segments. The installer's `Expand-SafeZip` rejects backslashes by design; do not weaken that check to accept a badly packaged archive. `scripts/package-release.ps1` builds the ZIP with `System.IO.Compression.ZipArchive` and validates every central-directory entry name before publication; do not use `Compress-Archive` for the release ZIP on Windows.

Create `DeskPilot-v1.0.1-windows-x64.zip`, copy the installer to `Install-DeskPilot-v1.0.1.ps1`, and generate `SHA256SUMS.txt` from those exact two files. Recompute both digests after any repackaging or installer edit. Do not reuse an earlier checksum.

Tracked release files must come from `git archive` for the release commit. Byte-compare the packaged installer with the committed installer extracted from that archive, not a CRLF-normalized working-tree copy.

## Checksums, attestations, and signatures

The manual Beta has no GitHub artifact attestation. Checksums can show that an artifact matches an expected digest, but they do not establish a code-signing publisher identity or independent build provenance. Users should verify both distribution files against `SHA256SUMS.txt` from the official release.

A later attested release must verify:

- The attestation subject names and SHA-256 digests match the downloaded archive and installer.
- The attestation identifies the expected `ItisPhoenix/DeskPilot` repository and workflow.
- The attested commit and ref match the approved release source.

Checksums and attestations are not Authenticode signatures. If digest, provenance, subject, or repository verification fails, stop the release.

## Installer dependency policy

`Install-DeskPilot-v1.0.1.ps1` downloads dependencies separately from their official publishers:

- `DeskPilot-v1.0.1-windows-x64.zip` and `SHA256SUMS.txt` from the official public v1.0.1 Beta release.
- Full `tunnel-client-v0.0.21-windows-amd64.zip` and `SHA256SUMS.txt` from `openai/tunnel-client` v0.0.21.
- Node.js **v24.22.3** Windows x64 archive from `nodejs.org`, with pinned SHA-256 and OpenJS Foundation Authenticode verification.
- Microsoft WebView2 bootstrapper from Microsoft's official fwlink when the Runtime is missing. The installer requires a valid Microsoft Corporation Authenticode signature, checks hash stability before execution, installs silently, verifies the registry result, and aborts before the app swap on failure.

The installer must not accept a runtime-only tunnel-client archive, request an OpenAI admin key, write the runtime key into YAML, enable a desktop permission category by default, enable sign-in startup by default, start the tunnel automatically, or launch DeskPilot by default. Launch remains explicit opt-in with `-LaunchDeskPilot`.

The managed `mcp.commands[].command` must use forward-slash paths for the packaged Node executable and launcher script. `tunnel-client` v0.0.21 shell-tokenizes that value and strips backslashes on Windows, which silently prevents the MCP child from starting. The launcher accepts either separator form only after exact path normalization.

The installer must enforce the protected dashboard profile: upstream `127.0.0.1:18080`, `allow_remote: false`, `open_browser: false`, and a freshly generated 144-bit random `/deskpilot-*` base path on every install or repair. It must remove Cloudflare process selectors, CA bundles, and proxy overrides from existing profiles. The launcher independently refuses a profile that does not match, scrubs security-sensitive inherited environment variables, and passes enforcing runtime flags.

## Unsigned Authenticode residual risk

DeskPilot v1.0.1 Beta does not apply an Authenticode signature to `DeskPilot.exe`. Windows may show SmartScreen or unknown-publisher warnings. The manual Beta is checksummed but unattested. Do not advise users to disable SmartScreen, execution policy, or other operating-system protections to bypass a failed verification.

## Manual publication

1. Commit the final source, tests, and documentation, then push `main`.
2. Package from that exact commit and verify extracted layout, source equality, executable version, and checksums.
3. Create and push an annotated `v1.0.1` tag pointing to the release commit.
4. Make the repository public only after the security gate is clear.
5. Create or update the GitHub release as a draft, then publish it manually as a prerelease with `gh release edit v1.0.1 --prerelease --draft=false`.
6. Upload the three artifacts and verify GitHub's downloaded copies against the local candidates.
7. Verify anonymous access to the repository, README, release notes, and downloads without authentication.
