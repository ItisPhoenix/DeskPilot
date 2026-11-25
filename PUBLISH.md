# Release process

DeskPilot v1.0.0 uses a private, source-first repository and a draft GitHub Release for Windows x64 artifacts. This document defines the release gate. A workflow definition or an earlier run is not evidence that the current candidate passed.

## Distribution policy

- Keep the source repository and release private for v1.0.0.
- Prepare the candidate as a draft GitHub Release for review. The installer consumes the approved stable, non-draft `v1.0.0` assets after explicit promotion within the private repository.
- Publish exactly these distribution artifacts:
  - `DeskPilot-v1.0.0-windows-x64.zip`
  - `Install-DeskPilot-v1.0.0.ps1`
  - `SHA256SUMS.txt`
- The private personal-account draft is checksummed but **unattested**. GitHub Artifact Attestations require a public repository or GitHub Enterprise Cloud. The current workflow runs its `attest-public` job only when repository visibility is public.
- Do not bundle the OpenAI tunnel-client, Node.js runtime, or Microsoft WebView2 Runtime in the DeskPilot archive. The installer provisions them separately.
- Preserve `LICENSE`, `NOTICE`, and upstream attribution in the source and release archive.
- Make the draft release available only to approved testers through the maintainer-controlled private channel.

## Release gates

A release is not ready for promotion until all of the following are complete and the actual evidence is recorded with the draft release:

1. Version metadata, source version, launcher metadata, and the `vX.Y.Z` tag agree.
2. A clean Windows x64 environment completes dependency installation, build, tests, dependency audits, Rust formatting, launcher checks, and the native self-test.
3. The archive is inspected for the required runtime files, production-only dependencies, scripts, documentation, licenses, and notices.
4. `SHA256SUMS.txt` contains the final SHA-256 digests for `DeskPilot-v1.0.0-windows-x64.zip` and `Install-DeskPilot-v1.0.0.ps1`, and both are independently checked.
5. Attestation status is recorded accurately. The private personal-account draft must be marked unattested. If the repository is public, the workflow-generated archive and installer attestations are verified against the intended repository, workflow, commit, and digest.
6. A clean Windows installation completes checksum verification, automatic WebView2/runtime setup, local preflight, manual tunnel start, and an end-to-end ChatGPT discovery/tool-call check with all permissions initially disabled.
7. The unsigned-binary warning, private-draft attestation limitation, and residual risk are present in the release notes.
8. A maintainer explicitly approves promotion from draft. Do not treat a green workflow as approval to distribute.

Record commands, exit codes, runner environment, commit SHA, artifact digests, checksum verification, attestation status, and manual observations. Never copy a previous release's results or describe a check as passed without running it for this candidate.

## Prepare the candidate

Use Node.js **v24.22.3** for the release build, matching the pinned installer runtime. From a clean checkout on Windows x64:

```powershell
npm run sync-version
npm ci
npm run build
npm run test:ci
npm audit --audit-level=high
cargo fmt --manifest-path launcher/Cargo.toml --all -- --check
cargo check --locked --manifest-path launcher/Cargo.toml --bin deskpilot
cargo build --release --locked --manifest-path launcher/Cargo.toml --bin deskpilot
.\launcher\target\release\deskpilot.exe --self-test
```

Run the Rust dependency audit from the launcher workspace as configured by the release workflow. Review all warnings, skipped checks, and platform limitations. A command that was not run must be reported as not run.

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
Install-DeskPilot-v1.0.0.ps1
Uninstall-DeskPilot.ps1
```

`server/node_modules` must contain production dependencies only. The archive must not contain credentials, tunnel profiles, local state, test reports, development dependencies, or an OpenAI admin key.

Create `DeskPilot-v1.0.0-windows-x64.zip`, copy the installer to `Install-DeskPilot-v1.0.0.ps1`, and generate `SHA256SUMS.txt` from those exact two files. Recompute both digests after any repackaging or installer edit. Do not reuse an earlier checksum.

The private personal-account draft has no GitHub artifact attestation. Its checksum manifest and release assets come from the same release account, so a compromised account could replace both. Distributors must provide the expected digests through a separate maintainer-approved channel when independent verification is required.

## Attestations and verification

GitHub Artifact Attestations require a public repository or GitHub Enterprise Cloud. The current release workflow enables attestation only for public repository visibility and attests the archive and installer, not `SHA256SUMS.txt`.

For the private personal-account v1.0.0 draft:

- Record the release as **checksummed, unattested**.
- Verify both distribution files against `SHA256SUMS.txt`.
- Do not claim independent build provenance or a verified GitHub attestation.
- Treat checksum verification as integrity checking only when the expected digest came through a trusted separate channel.

If a later release is made public, verify:

- The attestation subject names and SHA-256 digests match the downloaded archive and installer.
- The attestation identifies the expected `ItisPhoenix/DeskPilot` repository and release workflow.
- The attested commit and ref match the approved release source.

Checksums and attestations are not Authenticode signatures. If provenance, digest, subject, or repository verification fails, stop the release.

## Installer dependency policy

`Install-DeskPilot-v1.0.0.ps1` downloads dependencies separately from their official publishers:

- `DeskPilot-v1.0.0-windows-x64.zip` and `SHA256SUMS.txt` from the approved private release.
- Full `tunnel-client-v0.0.21-windows-amd64.zip` and `SHA256SUMS.txt` from `openai/tunnel-client` v0.0.21.
- Node.js **v24.22.3** Windows x64 archive from `nodejs.org`, with pinned SHA-256 and OpenJS Foundation Authenticode verification.
- Microsoft WebView2 bootstrapper from Microsoft's official fwlink when the Runtime is missing. The installer requires a valid Microsoft Corporation Authenticode signature, checks hash stability before execution, installs silently, verifies the registry result, and aborts before the app swap on failure.

The installer must not accept a runtime-only tunnel-client archive, request an OpenAI admin key, write the runtime key into YAML, enable a desktop permission category by default, enable sign-in startup by default, start the tunnel automatically, or launch DeskPilot by default. Launch remains explicit opt-in with `-LaunchDeskPilot`.

Private-release access must be tested with an approved tester account. An unauthenticated download path that works only for a public repository is not sufficient for a private release.

## Unsigned Authenticode residual risk

DeskPilot v1.0.0 does not apply an Authenticode signature to `DeskPilot.exe`. Windows may show SmartScreen or unknown-publisher warnings.

The private personal-account draft is checksummed but unattested. Checksums can show that an artifact matches an expected digest, but they do not establish a code-signing publisher identity or independent build provenance. Users must obtain the expected digests through the maintainer-approved private channel and verify both distribution files before running the installer.

A compromised repository, release account, CI workflow, or private distribution channel can still substitute artifacts and checksums. Public-repository artifact attestations, when available and verified, reduce provenance risk; they do not eliminate it or replace code signing. Do not advise users to disable SmartScreen, execution policy, or other operating-system protections to bypass a failed verification.

## Create and promote the draft

1. Create a draft GitHub Release tagged `v1.0.0` in the private repository.
2. Use `CHANGELOG.md` as the source for release notes. Do not add test or acceptance claims that are not backed by this candidate's evidence.
3. Attach `DeskPilot-v1.0.0-windows-x64.zip`, `Install-DeskPilot-v1.0.0.ps1`, and `SHA256SUMS.txt`.
4. Record the release as checksummed and unattested for the private personal-account repository. Do not generate or claim a GitHub artifact attestation for this draft.
5. Include the unsigned-binary warning, attestation limitation, supported Windows target, service-availability date, and known limitations.
6. Have a second maintainer inspect the final assets, checksum evidence, and verification record.
7. Promote or distribute only after explicit approval. Keep the repository and release private unless a separate public-release decision is approved and the public attestation path is verified.
