[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$installerPath = Join-Path $PSScriptRoot '../Install-DeskPilot.ps1'
$source = Get-Content -LiteralPath $installerPath -Raw
$script:checks = 0
$script:failures = New-Object System.Collections.ArrayList

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-Throws([scriptblock]$Action, [string]$MessagePattern) {
    $message = ''
    try { & $Action } catch { $message = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message } }
    Assert ($message -notmatch 'not recognized') "Required helper is missing: $message"
    Assert ($message -match $MessagePattern) "Expected error matching '$MessagePattern'; got '$message'."
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS $Name"
    } catch {
        $null = $script:failures.Add(($Name + ': ' + $_.Exception.Message))
        Write-Host "FAIL $Name`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Load only real function definitions. The installer entry point must never run in tests.
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) ("Installer parse errors: " + (($parseErrors | ForEach-Object Message) -join '; '))
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) {
    . ([scriptblock]::Create($function.Extent.Text))
}

function New-FixtureRoot([string]$Prefix) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    return $root
}

function New-ZipFixture([string]$Path, [object[]]$Entries) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($spec in $Entries) {
                $entry = $archive.CreateEntry($spec.Name)
                if ($null -ne $spec.Attributes) { $entry.ExternalAttributes = [int]$spec.Attributes }
                if ($null -ne $spec.Content) {
                    $writer = New-Object IO.StreamWriter($entry.Open(), [Text.Encoding]::UTF8)
                    try { $writer.Write([string]$spec.Content) } finally { $writer.Dispose() }
                } else {
                    $entryStream = $entry.Open()
                    $entryStream.Dispose()
                }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

$temp = New-FixtureRoot 'deskpilot-installer-test-'
$tunnelIdPrefix = 'tunnel_'
$tunnelIdBody = '0123456789abcdef0123456789abcdef'
$validTunnelId = $tunnelIdPrefix + $tunnelIdBody
$namespacedTunnelId = $tunnelIdPrefix + 'ab12_' + $tunnelIdBody
try {
    $script:webViewFixture = Join-Path $temp 'webview2.fixture'
    Set-Content -LiteralPath $script:webViewFixture -Value 'hermetic WebView2 bootstrapper fixture'

    function Write-Step { param([string]$Message) }

    function Reset-WebView2Fixture {
        $script:webViewInstalled = $false
        $script:webViewDownloadUri = ''
        $script:webViewDownloadFailure = $false
        $script:webViewSignature = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } }
        $script:webViewSignatureCalls = 0
        $script:webViewStartCalls = 0
        $script:webViewStartArgs = $null
        $script:webViewWait = $false
        $script:webViewPassThru = $false
        $script:webViewStartFailure = $false
        $script:webViewExitCode = 0
        $script:webViewInstallChecks = 0
    }

    function Test-WebView2Installed {
        $script:webViewInstallChecks++
        return $script:webViewInstalled
    }

    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
        $script:webViewDownloadUri = $Uri
        Copy-Item -LiteralPath $script:webViewFixture -Destination $OutFile
        if ($script:webViewDownloadFailure) { throw 'fixture WebView2 download failure' }
    }

    function Get-AuthenticodeSignature {
        param($LiteralPath)
        $script:webViewSignatureCalls++
        return $script:webViewSignature
    }

    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
        $script:webViewStartCalls++
        $script:webViewStartArgs = @($ArgumentList)
        $script:webViewWait = [bool]$Wait
        $script:webViewPassThru = [bool]$PassThru
        if ($script:webViewStartFailure) { throw 'fixture WebView2 start failure' }
        $script:webViewInstalled = $true
        return [pscustomobject]@{ ExitCode = $script:webViewExitCode }
    }

    Test-Case 'tunnel IDs use the exact service grammar' {
        foreach ($id in @($validTunnelId, $namespacedTunnelId)) {
            Assert (Test-TunnelId $id) "Valid tunnel ID rejected: $id"
        }
        $invalidTunnelIds = @(
            '',
            $validTunnelId.Substring(0, $validTunnelId.Length - 1),
            ($validTunnelId + '0'),
            ($tunnelIdPrefix + 'ABC_' + $tunnelIdBody),
            ($tunnelIdPrefix + 'abc-' + $tunnelIdBody),
            (' ' + $validTunnelId),
            ($validTunnelId + '/')
        )
        foreach ($id in $invalidTunnelIds) {
            Assert (-not (Test-TunnelId $id)) "Invalid tunnel ID accepted: $id"
        }
    }

    Test-Case 'release and Node artifacts are pinned exactly' {
        $artifacts = @(Get-PinnedArtifacts)
        $desk = $artifacts | Where-Object Key -eq 'DeskPilot' | Select-Object -First 1
        $tunnel = $artifacts | Where-Object Key -eq 'TunnelClient' | Select-Object -First 1
        $node = $artifacts | Where-Object Key -eq 'Node' | Select-Object -First 1
        Assert ($desk.Version -eq 'v1.0.1' -and $desk.Name -eq 'DeskPilot-v1.0.1-windows-x64.zip') 'DeskPilot must use the v1.0.1 Windows x64 archive.'
        Assert ($desk.Url -eq 'https://github.com/ItisPhoenix/DeskPilot/releases/download/v1.0.1/DeskPilot-v1.0.1-windows-x64.zip') 'DeskPilot download URL must be pinned.'
        Assert ($tunnel.Version -eq 'v0.0.21' -and $tunnel.Name -eq 'tunnel-client-v0.0.21-windows-amd64.zip') 'tunnel-client must use the full v0.0.21 Windows AMD64 archive, not a runtime-only flavor.'
        Assert ($tunnel.Sha256 -eq '2faf80ae62b58485fcef534cd3f78cd8b82e71cb04d14c2a5c73dbb4eb6c575a') 'tunnel-client checksum pin is wrong.'
        Assert ($node.Version -eq 'v24.22.3' -and $node.Name -eq 'node-v24.22.3-win-x64.zip') 'Node must use the selected Node 24 LTS Windows x64 archive.'
        Assert ($node.Sha256 -eq 'e612af99f626ab415ea225af6bce5c971feb448cb5cae250bb1c3fa50c5f7d9f') 'Node checksum must match official SHASUMS256.txt.'
        Assert ($node.Url -eq 'https://nodejs.org/dist/v24.22.3/node-v24.22.3-win-x64.zip') 'Node URL must be pinned.'
    }

    Test-Case 'only native x64 Windows is accepted' {
        Assert-X64Environment -ProcessorArchitecture 'AMD64' -NativeProcessorArchitecture ''
        Assert-X64Environment -ProcessorArchitecture 'x86' -NativeProcessorArchitecture 'AMD64'
        Assert-Throws { Assert-X64Environment -ProcessorArchitecture 'ARM64' -NativeProcessorArchitecture '' } 'x64'
        Assert-Throws { Assert-X64Environment -ProcessorArchitecture 'x86' -NativeProcessorArchitecture '' } 'x64'
        Assert-Throws { Assert-X64Environment -ProcessorArchitecture 'unknown' -NativeProcessorArchitecture 'AMD64' } 'x64'
        Assert-Throws { Assert-X64Environment -ProcessorArchitecture 'AMD64' -NativeProcessorArchitecture '' -Is64BitOperatingSystem $false } 'x64'
    }

    Test-Case 'WebView2 setup downloads the official bootstrapper and verifies Microsoft signature' {
        Reset-WebView2Fixture
        $bootstrapper = Join-Path $temp 'MicrosoftEdgeWebView2Setup.exe'
        $result = Ensure-WebView2 -BootstrapperPath $bootstrapper
        Assert ($script:webViewDownloadUri -ceq 'https://go.microsoft.com/fwlink/p/?LinkId=2124703') 'WebView2 did not use the official Microsoft HTTPS URL.'
        Assert ($script:webViewSignatureCalls -eq 1) 'WebView2 Authenticode was not checked exactly once.'
        Assert ($script:webViewStartCalls -eq 1) 'Verified WebView2 bootstrapper was not executed.'
        Assert (($script:webViewStartArgs -join ' ') -ceq '/silent /install') 'WebView2 was not installed silently.'
        Assert ($script:webViewWait -and $script:webViewPassThru) 'WebView2 execution was not awaited with exit-code inspection.'
        Assert ($result.Installed -and $result.ExitCode -eq 0 -and -not $result.RebootRequired) 'Successful WebView2 result was not reported.'
        Assert ($result.Sha256 -eq (Get-FileHash -LiteralPath $script:webViewFixture -Algorithm SHA256).Hash.ToLowerInvariant()) 'WebView2 staging hash was not recorded.'
        Assert (-not (Test-Path -LiteralPath $bootstrapper)) 'WebView2 bootstrapper was not cleaned up.'
    }

    Test-Case 'WebView2 setup reuses an installed runtime without downloading' {
        Reset-WebView2Fixture
        $script:webViewInstalled = $true
        $bootstrapper = Join-Path $temp 'unused-webview2.exe'
        $result = Ensure-WebView2 -BootstrapperPath $bootstrapper
        Assert ($result.Installed -and $script:webViewDownloadUri -eq '' -and $script:webViewStartCalls -eq 0) 'Installed WebView2 triggered a download or execution.'
    }

    Test-Case 'WebView2 setup rejects invalid unsigned or wrong-publisher signatures' {
        foreach ($signature in @(
            [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } },
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null },
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other Publisher' } }
        )) {
            Reset-WebView2Fixture
            $script:webViewSignature = $signature
            $bootstrapper = Join-Path $temp ('rejected-webview2-' + [Guid]::NewGuid().ToString('N') + '.exe')
            Assert-Throws { Ensure-WebView2 -BootstrapperPath $bootstrapper } 'Microsoft|Authenticode'
            Assert ($script:webViewStartCalls -eq 0) 'An unverified WebView2 bootstrapper was executed.'
            Assert (-not (Test-Path -LiteralPath $bootstrapper)) 'A rejected WebView2 bootstrapper was retained.'
        }
    }

    Test-Case 'WebView2 setup fails closed on download or execution errors' {
        Reset-WebView2Fixture
        $script:webViewDownloadFailure = $true
        $bootstrapper = Join-Path $temp 'failed-download-webview2.exe'
        Assert-Throws { Ensure-WebView2 -BootstrapperPath $bootstrapper } 'download|WebView2'
        Assert ($script:webViewStartCalls -eq 0 -and -not (Test-Path -LiteralPath $bootstrapper)) 'Failed WebView2 download executed or left a bootstrapper.'
        Reset-WebView2Fixture
        $script:webViewStartFailure = $true
        $bootstrapper = Join-Path $temp 'failed-start-webview2.exe'
        Assert-Throws { Ensure-WebView2 -BootstrapperPath $bootstrapper } 'start|install|WebView2'
        Assert (-not (Test-Path -LiteralPath $bootstrapper)) 'Failed WebView2 execution left a bootstrapper.'
    }

    Test-Case 'WebView2 setup requires both an accepted exit code and registry verification' {
        Reset-WebView2Fixture
        $script:webViewExitCode = 1603
        $bootstrapper = Join-Path $temp 'failed-exit-webview2.exe'
        Assert-Throws { Ensure-WebView2 -BootstrapperPath $bootstrapper } '1603|failed'
        Reset-WebView2Fixture
        $script:webViewExitCode = 0
        function Start-Process { param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru) return [pscustomobject]@{ ExitCode = 0 } }
        $bootstrapper = Join-Path $temp 'unverified-webview2.exe'
        Assert-Throws { Ensure-WebView2 -BootstrapperPath $bootstrapper } 'registry|verify|installed'
    }

    Test-Case 'WebView2 setup accepts reboot-required success only after registry verification' {
        foreach ($code in @(1641, 3010)) {
            Reset-WebView2Fixture
            $script:webViewExitCode = $code
            $bootstrapper = Join-Path $temp ('reboot-webview2-' + $code + '.exe')
            $result = Ensure-WebView2 -BootstrapperPath $bootstrapper
            Assert ($result.Installed -and $result.ExitCode -eq $code -and $result.RebootRequired) "Reboot-required WebView2 exit $code was not handled."
        }
    }

    Test-Case 'WebView2 setup rechecks the staged hash immediately before execution' {
        Reset-WebView2Fixture
        $script:webViewHashCalls = 0
        function Get-FileHash {
            param($LiteralPath, $Algorithm)
            $script:webViewHashCalls++
            if ($script:webViewHashCalls -eq 2) { return [pscustomobject]@{ Hash = ('0' * 64) } }
            return Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
        }
        $bootstrapper = Join-Path $temp 'changed-webview2.exe'
        Assert-Throws { Ensure-WebView2 -BootstrapperPath $bootstrapper } 'hash|changed'
        Assert ($script:webViewStartCalls -eq 0) 'A WebView2 bootstrapper changed after signature verification was executed.'
    }

    Test-Case 'tunnel-client accepts official tagged version stamps only' {
        Assert (Test-TunnelVersion @('0.0.21+0123456789ab (git sha: 0123456789ab)')) 'Official tagged version stamp rejected.'
        Assert (Test-TunnelVersion @('0.0.21 git sha: 0123456789ab')) 'Source-style version stamp rejected.'
        Assert (-not (Test-TunnelVersion @('0.0.210'))) 'A longer version was accepted.'
        Assert (-not (Test-TunnelVersion @('0.0.20+0123456789ab'))) 'The wrong tunnel-client version was accepted.'
    }

    Test-Case 'checksum lookup matches the complete asset name' {
        $hash = 'A' * 64
        $text = "$hash  node-v24.22.3-win-x64.zip`n$($hash.ToLowerInvariant())  other.zip"
        Assert ((Get-Checksum $text 'node-v24.22.3-win-x64.zip') -eq $hash.ToLowerInvariant()) 'Exact checksum entry was not found.'
        Assert-Throws { Get-Checksum $text 'win-x64.zip' } 'not found'
        Assert-Throws { Get-Checksum "$hash  asset.zip`n$('B' * 64)  asset.zip" 'asset.zip' } 'conflicting|duplicate'
    }

    Test-Case 'signature policy accepts only trusted signed binaries when required' {
        $valid = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Test Publisher, O=Example' } }
        $invalid = [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = $valid.SignerCertificate }
        $unsigned = [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        $wrong = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other Publisher' } }
        Assert (Test-AuthenticodeSignature -Signature $valid -PublisherPattern 'Example') 'Valid expected publisher rejected.'
        Assert (-not (Test-AuthenticodeSignature -Signature $invalid -PublisherPattern 'Example')) 'Invalid signature accepted.'
        Assert (-not (Test-AuthenticodeSignature -Signature $unsigned -PublisherPattern 'Example')) 'Unsigned binary accepted when signatures are required.'
        Assert (Test-AuthenticodeSignature -Signature $unsigned -PublisherPattern 'Example' -AllowUnsigned) 'Explicitly optional unsigned signature rejected.'
        Assert (-not (Test-AuthenticodeSignature -Signature $wrong -PublisherPattern 'Example' -AllowUnsigned)) 'Unexpected signer accepted.'
    }

    Test-Case 'runtime manifest records exact versions installed hashes and signer policy' {
        $node = Join-Path $temp 'manifest-node.exe'
        $tunnel = Join-Path $temp 'manifest-tunnel-client.exe'
        $manifest = Join-Path $temp 'runtime-manifest.json'
        Set-Content -LiteralPath $node -Value 'verified node fixture'
        Set-Content -LiteralPath $tunnel -Value 'verified tunnel fixture'
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            if ($LiteralPath -eq $node) { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=OpenJS Foundation, O=OpenJS Foundation, C=US' } } }
            return [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }
        New-RuntimeManifest -NodePath $node -TunnelClientPath $tunnel -DestinationPath $manifest
        $json = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        Assert ($json.node.version -ceq '24.22.3') 'Manifest Node version is wrong.'
        Assert ($json.node.sha256 -ceq (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()) 'Manifest Node hash is wrong.'
        Assert ($json.node.signerSubject -ceq 'OpenJS Foundation') 'Manifest Node signer is wrong.'
        Assert ($json.tunnelClient.version -ceq '0.0.21') 'Manifest tunnel-client version is wrong.'
        Assert ($json.tunnelClient.sha256 -ceq (Get-FileHash -LiteralPath $tunnel -Algorithm SHA256).Hash.ToLowerInvariant()) 'Manifest tunnel-client hash is wrong.'
        Assert (-not ($json.tunnelClient.PSObject.Properties.Name -contains 'signerSubject')) 'Unsigned tunnel-client signerSubject must be omitted.'
        Assert-RuntimeManifest -ManifestPath $manifest -NodePath $node -TunnelClientPath $tunnel
    }

    Test-Case 'runtime manifest preserves the actual valid tunnel-client signer subject' {
        $node = Join-Path $temp 'signed-node.exe'
        $tunnel = Join-Path $temp 'signed-tunnel-client.exe'
        $manifest = Join-Path $temp 'signed-runtime-manifest.json'
        Set-Content -LiteralPath $node -Value 'node'
        Set-Content -LiteralPath $tunnel -Value 'tunnel'
        $signer = 'CN=OpenAI, O=OpenAI, L=San Francisco, S=California, C=US'
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            if ($LiteralPath -eq $node) { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=OpenJS Foundation, O=OpenJS Foundation' } } }
            return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $signer } }
        }
        New-RuntimeManifest -NodePath $node -TunnelClientPath $tunnel -DestinationPath $manifest
        $json = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        Assert ($json.tunnelClient.signerSubject -ceq $signer) 'Signed tunnel-client signer subject was not preserved.'
    }

    Test-Case 'runtime manifest rejects invalid signatures before writing' {
        $node = Join-Path $temp 'bad-signature-node.exe'
        $tunnel = Join-Path $temp 'bad-signature-tunnel.exe'
        $manifest = Join-Path $temp 'bad-signature-manifest.json'
        Set-Content -LiteralPath $node -Value 'node'
        Set-Content -LiteralPath $tunnel -Value 'tunnel'
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            if ($LiteralPath -eq $node) { return [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=OpenJS Foundation' } } }
            return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other Publisher' } }
        }
        Assert-Throws { New-RuntimeManifest -NodePath $node -TunnelClientPath $tunnel -DestinationPath $manifest } 'Node|OpenJS|signature'
        Assert (-not (Test-Path -LiteralPath $manifest)) 'A manifest was written for an invalid Node signature.'
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            if ($LiteralPath -eq $node) { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=OpenJS Foundation' } } }
            return [pscustomobject]@{ Status = 'HashMismatch'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=OpenAI' } }
        }
        Assert-Throws { New-RuntimeManifest -NodePath $node -TunnelClientPath $tunnel -DestinationPath $manifest } 'tunnel|signature|Authenticode'
        Assert (-not (Test-Path -LiteralPath $manifest)) 'A manifest was written for an invalid tunnel-client signature.'
    }

    Test-Case 'runtime manifest validation rejects malformed JSON versions and hashes' {
        $node = Join-Path $temp 'validate-node.exe'
        $tunnel = Join-Path $temp 'validate-tunnel.exe'
        $manifest = Join-Path $temp 'validate-runtime-manifest.json'
        Set-Content -LiteralPath $node -Value 'node'
        Set-Content -LiteralPath $tunnel -Value 'tunnel'
        # Node must be signed even though the tunnel fixture is intentionally unsigned.
        function Get-AuthenticodeSignature {
            param($LiteralPath)
            if ($LiteralPath -eq $node) { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=OpenJS Foundation' } } }
            return [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }
        New-RuntimeManifest -NodePath $node -TunnelClientPath $tunnel -DestinationPath $manifest
        $valid = Get-Content -LiteralPath $manifest -Raw
        [IO.File]::WriteAllText($manifest, '{not-json', [Text.UTF8Encoding]::new($false))
        Assert-Throws { Assert-RuntimeManifest -ManifestPath $manifest -NodePath $node -TunnelClientPath $tunnel } 'JSON|manifest'
        $changed = $valid | ConvertFrom-Json
        $changed.node.version = '24.22.2'
        [IO.File]::WriteAllText($manifest, ($changed | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Assert-Throws { Assert-RuntimeManifest -ManifestPath $manifest -NodePath $node -TunnelClientPath $tunnel } 'version'
        $changed = $valid | ConvertFrom-Json
        $changed.tunnelClient.sha256 = '0' * 64
        [IO.File]::WriteAllText($manifest, ($changed | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Assert-Throws { Assert-RuntimeManifest -ManifestPath $manifest -NodePath $node -TunnelClientPath $tunnel } 'hash|SHA-256'
    }

    Test-Case 'runtime manifest participates in transaction rollback' {
        $root = Join-Path $temp ('manifest-transaction-' + [Guid]::NewGuid().ToString('N'))
        $install = Join-Path $root 'DeskPilot'
        $stage = Join-Path $root 'stage'
        $backup = Join-Path $root 'backup'
        New-Item -ItemType Directory -Path $install, $stage, $backup -Force | Out-Null
        $target = Join-Path $install 'runtime-manifest.json'
        $staged = Join-Path $stage 'runtime-manifest.json'
        Set-Content -LiteralPath $target -Value 'old manifest'
        Set-Content -LiteralPath $staged -Value 'new manifest'
        $operation = [pscustomobject]@{ Target = $target; Staged = $staged; Backup = (Join-Path $backup 'runtime-manifest.json') }
        Assert-Throws { Invoke-PathTransaction -Operations @($operation) -ValidateAfter 1 -Validation { throw 'fixture manifest rollback' } } 'fixture manifest rollback'
        Assert ((Get-Content -LiteralPath $target -Raw).Trim() -eq 'old manifest') 'Transaction rollback did not restore the old runtime manifest.'
    }

    Test-Case 'safe ZIP extraction accepts ordinary nested files' {
        $zip = Join-Path $temp 'safe.zip'
        $out = Join-Path $temp 'safe-out'
        New-ZipFixture $zip @(
            @{ Name = 'folder/' },
            @{ Name = 'folder/file.txt'; Content = 'safe' }
        )
        Expand-SafeZip -ArchivePath $zip -DestinationPath $out
        Assert ((Get-Content -LiteralPath (Join-Path $out 'folder/file.txt') -Raw) -eq 'safe') 'Safe ZIP content was not extracted.'
    }

    Test-Case 'ZIP standard root prefix is normalized without allowing aliases or traversal' {
        $zip = Join-Path $temp 'root-prefix.zip'; $out = Join-Path $temp 'root-prefix-out'
        New-ZipFixture $zip @(@{ Name='./' },@{ Name='./folder/' },@{ Name='./folder/file.txt'; Content='fixture' })
        Expand-SafeZip -ArchivePath $zip -DestinationPath $out
        Assert (Test-Path -LiteralPath (Join-Path $out 'folder/file.txt')) 'Standard root prefix rejected.'
        $zip = Join-Path $temp 'root-alias.zip'; $out = Join-Path $temp 'root-alias-out'
        New-ZipFixture $zip @(@{ Name='a.txt'; Content='one' },@{ Name='./a.txt'; Content='two' })
        Assert-Throws { Expand-SafeZip -ArchivePath $zip -DestinationPath $out } 'duplicate'
        $zip = Join-Path $temp 'root-traversal.zip'; $out = Join-Path $temp 'root-traversal-out'
        New-ZipFixture $zip @(@{ Name='./../bad.txt'; Content='fixture' })
        Assert-Throws { Expand-SafeZip -ArchivePath $zip -DestinationPath $out } 'unsafe|traversal'
        $zip = Join-Path $temp 'nested-collision.zip'; $out = Join-Path $temp 'nested-collision-out'
        New-ZipFixture $zip @(@{ Name='folder/file'; Content='one' },@{ Name='folder/file/child'; Content='two' })
        Assert-Throws { Expand-SafeZip -ArchivePath $zip -DestinationPath $out } 'collision'
    }
    Test-Case 'ZIP traversal and absolute paths are rejected before extraction' {
        foreach ($name in @('../escape.txt', 'folder/../../escape.txt', '/absolute.txt', '\absolute.txt', 'C:\escape.txt', 'C:escape.txt', '\\server\share\escape.txt', 'folder/file.txt:stream')) {
            $zip = Join-Path $temp ('unsafe-' + [Guid]::NewGuid().ToString('N') + '.zip')
            $out = Join-Path $temp ('unsafe-out-' + [Guid]::NewGuid().ToString('N'))
            New-ZipFixture $zip @(@{ Name = $name; Content = 'bad' })
            Assert-Throws { Expand-SafeZip -ArchivePath $zip -DestinationPath $out } 'unsafe|absolute|traversal|path'
            Assert (-not (Test-Path $out)) 'An invalid archive created its extraction directory.'
        }
    }

    Test-Case 'ZIP links and reparse-point entries are rejected' {
        foreach ($attributes in @((0xA1ED -shl 16), (0x400))) {
            $zip = Join-Path $temp ('link-' + [Guid]::NewGuid().ToString('N') + '.zip')
            $out = Join-Path $temp ('link-out-' + [Guid]::NewGuid().ToString('N'))
            New-ZipFixture $zip @(@{ Name = 'link'; Content = 'target'; Attributes = $attributes })
            Assert-Throws { Expand-SafeZip -ArchivePath $zip -DestinationPath $out } 'link|reparse'
            Assert (-not (Test-Path $out)) 'A link archive created its extraction directory.'
        }
    }

    Test-Case 'ZIP duplicates and excessive expansion are rejected' {
        $duplicate = Join-Path $temp 'duplicate.zip'
        $out = Join-Path $temp 'duplicate-out'
        New-ZipFixture $duplicate @(@{ Name = 'same.txt'; Content = 'one' }, @{ Name = 'same.txt'; Content = 'two' })
        Assert-Throws { Expand-SafeZip -ArchivePath $duplicate -DestinationPath $out } 'duplicate'
        $bomb = Join-Path $temp 'expansion.zip'
        $bombOut = Join-Path $temp 'expansion-out'
        New-ZipFixture $bomb @(@{ Name = 'large.txt'; Content = ('x' * 8192) })
        Assert-Throws { Expand-SafeZip -ArchivePath $bomb -DestinationPath $bombOut -MaxExpandedBytes 1024 -MaxExpansionRatio 10 } 'expansion|large|limit'
        Assert (-not (Test-Path $bombOut)) 'An excessive archive created its extraction directory.'
    }

    Test-Case 'ZIP file directory collisions are rejected regardless of entry order' {
        $zip = Join-Path $temp 'collision.zip'
        $out = Join-Path $temp ('fixture-out-' + [Guid]::NewGuid().ToString('N'))
        New-ZipFixture $zip @(@{ Name = 'node/child.txt'; Content = 'child' }, @{ Name = 'node'; Content = 'file' })
        Assert-Throws { Expand-SafeZip -ArchivePath $zip -DestinationPath $out } 'file/directory path collision'
        Assert (-not (Test-Path $out)) 'A colliding archive created its extraction directory.'
    }

    Test-Case 'profile updates preserve unrelated settings and channels' {
        $oldId = $validTunnelId
        $newId = $namespacedTunnelId
        $existing = @"
config_version: 1
ca_bundle: attacker.pem
"ca_bundle": "quoted-attacker.pem"
"\u0063a_bundle": "escaped-attacker.pem"
{http_proxy: http://flow-attacker.example:8080}
"cloudflared": {path: quoted-attacker.exe}
http_proxy: http://attacker.example:8080
control_plane:
  base_url: https://example.invalid
  url_path: /attacker
  residency: eu
  http_proxy: http://attacker.example:8080
  tunnel_id: $oldId
  api_key: env:MY_RUNTIME_KEY
cloudflared:
  managed: false
  path: attacker.exe
health:
  listen_addr: "127.0.0.1:9999"
  unix_socket: dashboard.sock
  url_file: health.url
admin_ui:
  open_browser: true
  public_origin: https://attacker.example
  base_path: "/deskpilot-abcdefghijklmnopqrstuvwx"
log:
  level: debug
  format: json
mcp:
  startup_wait_timeout: 45s
  commands:
    - channel: other
      command: other.exe
    - channel: main
      command: old.exe
"@
        $node = Join-Path $temp 'runtime/node.exe'
        $install = Join-Path $temp 'Programs/DeskPilot'
        $updated = Update-TunnelProfile -ExistingText $existing -TunnelId $newId -NodePath $node -InstallRoot $install
        Assert ($updated -match [regex]::Escape($newId)) 'New tunnel ID was not written.'
        Assert ($updated -notmatch [regex]::Escape($oldId)) 'Old tunnel ID remains.'
        Assert ($updated -match 'base_url: "https://api\.openai\.com"') 'The official control-plane URL was not enforced.'
        Assert ($updated -match 'api_key: "env:CONTROL_PLANE_API_KEY"') 'The managed runtime-key reference was not enforced.'
        Assert ($updated -notmatch 'url_path:|residency:|unix_socket:|url_file:|public_origin:|http_proxy:|ca_bundle:|cloudflared:|attacker\.exe|escaped-attacker') 'Unsafe endpoint, proxy, CA, or Cloudflare overrides were not removed.'
        Assert ($updated -match 'listen_addr: "127\.0\.0\.1:18080"') 'The protected upstream dashboard listener was not enforced.'
        Assert ($updated -match 'allow_remote: false' -and $updated -match 'open_browser: false') 'Remote dashboard access or browser auto-open was not disabled.'
        Assert ($updated -match 'base_path: "/deskpilot-[A-Za-z0-9_-]{24}"' -and $updated -notmatch 'deskpilot-abcdefghijklmnopqrstuvwx') 'The dashboard base path was not rotated to a fresh random value.'
        Assert ($updated -match 'level: debug' -and $updated -match 'startup_wait_timeout: 45s') 'Unrelated profile settings were lost.'
        Assert ($updated -match 'channel: other\r?\n\s+command: other\.exe') 'A non-main MCP channel was changed.'
        Assert ($updated -match 'managed-launcher\.mjs' -and $updated -match 'runtime\\\\node\.exe') 'Main MCP command was not updated.'
    }

    Test-Case 'fresh profiles disable browser auto-open and use a strict ID' {
        $profile = Update-TunnelProfile -ExistingText '' -TunnelId $validTunnelId -NodePath (Join-Path $temp 'node.exe') -InstallRoot (Join-Path $temp 'DeskPilot')
        Assert ($profile -match 'listen_addr: "127\.0\.0\.1:18080"') 'Fresh profile must use the protected upstream dashboard listener.'
        Assert ($profile -match 'allow_remote: false' -and $profile -match 'open_browser: false') 'Fresh profile must disable remote UI and browser auto-open.'
        Assert ($profile -match 'base_path: "/deskpilot-[A-Za-z0-9_-]{24}"') 'Fresh profile must use an unguessable dashboard base path.'
        Assert ($profile -match 'api_key: "?env:CONTROL_PLANE_API_KEY"?' -and $profile -notmatch '(?m)api_key:\s*"?(?:sk-|eyJ)') 'Fresh profile must not contain a literal API key.'
        Assert-Throws { Update-TunnelProfile -ExistingText '' -TunnelId 'bad' -NodePath 'node.exe' -InstallRoot 'C:\DeskPilot' } 'tunnel ID'
    }

    Test-Case 'a missing main channel is inserted inside the existing mcp block' {
        $existing = @"
config_version: 1
control_plane:
  tunnel_id: $validTunnelId
  api_key: env:CONTROL_PLANE_API_KEY
mcp:
  startup_wait_timeout: 45s
  commands:
    - channel: other
      command: other.exe
log:
  level: debug
"@
        $updated = Update-TunnelProfile -ExistingText $existing -TunnelId $validTunnelId -NodePath (Join-Path $temp 'node.exe') -InstallRoot (Join-Path $temp 'DeskPilot')
        $main = $updated.IndexOf('- channel: main')
        $log = $updated.IndexOf("log:`n")
        Assert ($main -ge 0 -and $main -lt $log) 'The main channel was appended outside the mcp block.'
        Assert ($updated -match 'channel: other\r?\n\s+command: other\.exe') 'The existing channel was changed.'
    }

    Test-Case 'existing quoted tunnel IDs retain inline comments during upgrades' {
        $existing = @"
control_plane:
  tunnel_id: "$validTunnelId" # keep this note
  api_key: env:CONTROL_PLANE_API_KEY
mcp:
  commands:
    - channel: main
      command: old.exe
"@
        Assert ((Get-ProfileTunnelId $existing) -eq $validTunnelId) 'Inline YAML comment was treated as part of the tunnel ID.'
    }

    Test-Case 'transaction rollback restores dependencies app profile and shortcut' {
        $root = Join-Path $temp ('transaction-' + [Guid]::NewGuid().ToString('N'))
        $stage = Join-Path $root 'stage'
        $backup = Join-Path $root 'backup'
        New-Item -ItemType Directory -Path $stage, $backup | Out-Null
        $operations = @()
        foreach ($name in @('bin', 'runtime', 'app', 'shortcut')) {
            $target = Join-Path $root $name
            $staged = Join-Path $stage $name
            New-Item -ItemType Directory -Path $target, $staged | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'state.txt') -Value "old-$name"
            Set-Content -LiteralPath (Join-Path $staged 'state.txt') -Value "new-$name"
            $operations += [pscustomobject]@{ Target = $target; Staged = $staged; Backup = (Join-Path $backup $name) }
        }
        Assert-Throws { Invoke-PathTransaction -Operations $operations -Validation { param($Completed) if ($Completed -eq 3) { throw 'fixture validation failure' } } -ValidateAfter 3 } 'fixture validation failure'
        foreach ($name in @('bin', 'runtime', 'app', 'shortcut')) {
            Assert ((Get-Content -LiteralPath (Join-Path $root "$name/state.txt") -Raw).Trim() -eq "old-$name") "Rollback did not restore $name."
        }
    }

    Test-Case 'transaction commits every managed path after validation' {
        $root = Join-Path $temp ('commit-' + [Guid]::NewGuid().ToString('N'))
        $stage = Join-Path $root 'stage'
        $backup = Join-Path $root 'backup'
        New-Item -ItemType Directory -Path $stage, $backup | Out-Null
        $operations = @()
        foreach ($name in @('bin', 'runtime', 'app', 'shortcut')) {
            $target = Join-Path $root $name
            $staged = Join-Path $stage $name
            New-Item -ItemType Directory -Path $staged | Out-Null
            Set-Content -LiteralPath (Join-Path $staged 'state.txt') -Value "new-$name"
            $operations += [pscustomobject]@{ Target = $target; Staged = $staged; Backup = (Join-Path $backup $name) }
        }
        Invoke-PathTransaction -Operations $operations -Validation { param($Completed) Assert ($Completed -eq 2) 'Validation ran at the wrong transaction boundary.' }
        foreach ($name in @('bin', 'runtime', 'app', 'shortcut')) {
            Assert ((Get-Content -LiteralPath (Join-Path $root "$name/state.txt") -Raw).Trim() -eq "new-$name") "Commit did not install $name."
        }
    }

    Test-Case 'transaction rollback removes a partially copied staged path' {
        $root = Join-Path $temp ('partial-' + [Guid]::NewGuid().ToString('N'))
        $stage = Join-Path $root 'stage'
        $backup = Join-Path $root 'backup'
        New-Item -ItemType Directory -Path $stage, $backup | Out-Null
        $target = Join-Path $root 'app'
        $staged = Join-Path $stage 'app'
        New-Item -ItemType Directory -Path $target, $staged | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'state.txt') -Value 'old'
        Set-Content -LiteralPath (Join-Path $staged 'state.txt') -Value 'new'
        $operation = [pscustomobject]@{ Target = $target; Staged = $staged; Backup = (Join-Path $backup 'app') }
        function Move-Item {
            param($LiteralPath, $Destination, $ErrorAction)
            if ($LiteralPath -eq $staged) {
                New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Destination 'partial.txt') -Value 'partial'
                throw 'fixture partial copy failure'
            }
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction $ErrorAction
        }
        Assert-Throws { Invoke-PathTransaction -Operations @($operation) } 'partial copy failure'
        Assert ((Get-Content -LiteralPath (Join-Path $target 'state.txt') -Raw).Trim() -eq 'old') 'Rollback did not restore the old app.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $target 'partial.txt'))) 'A partially copied new app remained after rollback.'
    }

    Test-Case 'doctor validation uses only doctor profile-file and explain' {
        $log = Join-Path $temp 'doctor-args.txt'
        $cmd = Join-Path $temp 'doctor.cmd'
        Set-Content -LiteralPath $cmd -Value "@echo off`r`necho %*>`"$log`"`r`nexit /b 0`r`n" -Encoding ascii
        $profile = Join-Path $temp 'profile.yaml'
        Set-Content -LiteralPath $profile -Value 'fixture'
        Invoke-TunnelDoctor -TunnelClient $cmd -ProfilePath $profile
        $args = (Get-Content -LiteralPath $log -Raw).Trim()
        Assert ($args -match '^doctor --profile-file "?' + [regex]::Escape($profile) + '"? --explain$') "Unexpected doctor arguments: $args"
        Set-Content -LiteralPath $cmd -Value "@echo off`r`nexit /b 2`r`n" -Encoding ascii
        Assert-Throws { Invoke-TunnelDoctor -TunnelClient $cmd -ProfilePath $profile } 'doctor|validation'
    }

    Test-Case 'doctor Windows path false negative is replaced by a direct staged node check' {
        $log = Join-Path $temp 'doctor-args.txt'
        $cmd = Join-Path $temp 'doctor-windows.cmd'
        Set-Content -LiteralPath $cmd -Value "@echo off`r`necho FAILED_CHECKS mcp_command_executable`r`nexit /b 2`r`n" -Encoding ascii
        $profile = Join-Path $temp 'doctor-windows-profile.yaml'
        Set-Content -LiteralPath $profile -Value 'fixture'
        $node = Join-Path $temp 'doctor-windows-node.exe'
        Set-Content -LiteralPath $node -Value 'fixture'
        Invoke-TunnelDoctor -TunnelClient $cmd -ProfilePath $profile -NodePath $node
        Assert-Throws { Invoke-TunnelDoctor -TunnelClient $cmd -ProfilePath $profile } 'doctor|validation'
        Assert-Throws { Invoke-TunnelDoctor -TunnelClient $cmd -ProfilePath $profile -NodePath (Join-Path $temp 'missing-node.exe') } 'doctor|validation'
        Set-Content -LiteralPath $cmd -Value "@echo off`r`necho FAILED_CHECKS mcp_command_executable,control_plane_api_key`r`nexit /b 2`r`n" -Encoding ascii
        Assert-Throws { Invoke-TunnelDoctor -TunnelClient $cmd -ProfilePath $profile -NodePath $node } 'doctor|validation'
        $args = (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue)
        Assert ($null -eq $args -or $args -notmatch 'run|start') 'Doctor must remain offline.'
        Assert ($source -match 'profile-file \$ProfilePath --explain') 'Doctor argument contract changed.'
    }

    Test-Case 'downloads are hash checked before callers can extract them' {
        $fixture = Join-Path $temp 'download.fixture'
        $destination = Join-Path $temp 'verified.download'
        Set-Content -LiteralPath $fixture -Value 'verified bytes'
        $hash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
        function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) Copy-Item -LiteralPath $fixture -Destination $OutFile }
        Download-Verified -Url 'https://example.invalid/asset.zip' -ExpectedHash $hash -Destination $destination
        Assert ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $hash) 'Verified download was changed.'
        Assert-Throws { Download-Verified -Url 'https://example.invalid/asset.zip' -ExpectedHash ('0' * 64) -Destination $destination } 'SHA-256'
        Assert (-not (Test-Path $destination)) 'A corrupt download was retained.'
    }

    Test-Case 'GitHub releases are fetched by immutable tag rather than latest' {
        $script:requestedUri = ''
        function Invoke-RestMethod { param($Uri, $Headers) $script:requestedUri = $Uri; return @{ tag_name = 'v1.0.0' } }
        $release = Get-GitHubRelease -Repository 'ItisPhoenix/DeskPilot' -Tag 'v1.0.0'
        Assert ($release.tag_name -eq 'v1.0.0') 'Fixture release was not returned.'
        Assert ($script:requestedUri -eq 'https://api.github.com/repos/ItisPhoenix/DeskPilot/releases/tags/v1.0.0') 'Release lookup was not pinned to the tag.'
    }

    Test-Case 'managed paths reject roots overlaps and reparse points' {
        $root = Join-Path $temp 'paths'
        $data = Join-Path $root 'DeskPilot'
        $install = Join-Path $root 'Programs/DeskPilot'
        New-Item -ItemType Directory -Path $data, $install -Force | Out-Null
        $null = Assert-ManagedPath -Path $data -Leaf 'DeskPilot'
        $null = Assert-ManagedPath -Path $install -Leaf 'DeskPilot'
        Assert-Throws { Assert-ManagedPath -Path $root -Leaf 'DeskPilot' } 'leaf|DeskPilot'
        Assert-Throws { Assert-ManagedPath -Path 'relative/DeskPilot' -Leaf 'DeskPilot' } 'absolute|rooted'
        Assert-Throws { Assert-ManagedPath -Path (Join-Path $data 'runtime') -Leaf 'DeskPilot' } 'leaf|DeskPilot'
        $junction = Join-Path $root 'linked-data'
        try {
            New-Item -ItemType Junction -Path $junction -Target $data -ErrorAction Stop | Out-Null
            Assert-Throws { Assert-ManagedPath -Path $junction -Leaf 'linked-data' } 'reparse|link'
        } catch [Management.Automation.ItemNotFoundException] {
            Write-Host 'SKIP junction fixture unavailable'
        }
    }

    Test-Case 'published pinned DeskPilot Beta is accepted but drafts and dependency prereleases are rejected' {
        function Invoke-RestMethod { param($Uri,$Headers,$ErrorAction) return @{tag_name=$script:fixtureTag;draft=$script:fixtureDraft;prerelease=$script:fixturePre} }
        $script:fixtureTag='v1.0.0'; $script:fixtureDraft=$false; $script:fixturePre=$true
        Assert ((Get-GitHubRelease 'ItisPhoenix/DeskPilot' 'v1.0.0').prerelease) 'Published DeskPilot Beta rejected.'
        Assert-Throws { Get-GitHubRelease 'openai/tunnel-client' 'v1.0.0' } 'required published release'
        $script:fixtureDraft=$true
        Assert-Throws { Get-GitHubRelease 'ItisPhoenix/DeskPilot' 'v1.0.0' } 'required published release'
        $script:fixtureDraft=$false; $script:fixtureTag='v9.9.9'
        Assert-Throws { Get-GitHubRelease 'ItisPhoenix/DeskPilot' 'v1.0.0' } 'required published release'
    }
    Test-Case 'real installer directory guards and literal tunnel copy work' {
        $guardRoot = New-FixtureRoot 'deskpilot-guard-'
        try {
            $guards = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match '^if \(.*Test-Path -LiteralPath \$(data|install).*is not a directory' }, $true))
            Assert ($guards.Count -eq 2) 'Expected both actual installer directory guards.'
            foreach ($guard in $guards) {
                $data = Join-Path $guardRoot 'missing'
                $install = $data
                . ([scriptblock]::Create($guard.Extent.Text))
                New-Item -ItemType Directory -Path $data | Out-Null
                . ([scriptblock]::Create($guard.Extent.Text))
                Remove-Item -LiteralPath $data
                Set-Content -LiteralPath $data -Value 'not directory'
                Assert-Throws { . ([scriptblock]::Create($guard.Extent.Text)) } 'root is not a directory'
                Remove-Item -LiteralPath $data
            }
            $sourceDir = Join-Path $guardRoot 'source[fixture]'
            $tunnelStage = Join-Path $guardRoot 'dest'
            New-Item -ItemType Directory -Path $sourceDir,$tunnelStage | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceDir 'tunnel-client.exe') -Value 'dummy'
            Set-Content -LiteralPath (Join-Path $sourceDir 'support.txt') -Value 'dummy'
            $tunnelExecutables = @(Get-Item -LiteralPath (Join-Path $sourceDir 'tunnel-client.exe'))
            $copy = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Extent.Text -match 'Get-ChildItem -LiteralPath \$tunnelExecutables\[0\].Directory.FullName' },$true))
            Assert ($copy.Count -eq 1) 'Expected real tunnel copy loop.'
            . ([scriptblock]::Create($copy[0].Extent.Text))
            Assert (Test-Path -LiteralPath (Join-Path $tunnelStage 'tunnel-client.exe')) 'Tunnel client not copied.'
            Assert (Test-Path -LiteralPath (Join-Path $tunnelStage 'support.txt')) 'Tunnel support file not copied.'
        } finally { Remove-Item -LiteralPath $guardRoot -Recurse -Force }
    }
    Test-Case 'OneDrive desktop shortcut stays scoped to the trusted known folder' {
        Assert ($source -match 'function Get-DeskPilotDesktop') 'Desktop known-folder resolver is missing.'
        Assert ($source -match 'TrustedBase') 'Shortcut reparse validation has no trusted known-folder base.'
        Assert ($source -match 'Set-ShortcutAppUserModelId -ShortcutPath \$shortcut') 'AUMID is not re-applied on the final desktop shortcut.'
        $root = New-FixtureRoot 'deskpilot-onedrive-installer-'
        $oneDrive = Join-Path $root 'OneDrive'
        $linkedChild = Join-Path $root 'oneDrive/Desktop/linked'
        try {
            $syncRoot = Join-Path $root 'sync-target'
            $desktop = Join-Path $oneDrive 'Desktop'
            $shortcut = Join-Path $desktop 'DeskPilot.lnk'
            New-Item -ItemType Directory -Path $syncRoot -Force | Out-Null
            try { New-Item -ItemType Junction -Path $oneDrive -Target $syncRoot -ErrorAction Stop | Out-Null }
            catch [Management.Automation.ItemNotFoundException] { Write-Host 'SKIP OneDrive junction fixture unavailable'; return }
            New-Item -ItemType Directory -Path $desktop -Force | Out-Null
            Set-Content -LiteralPath $shortcut -Value 'fixture'
            Assert-NoReparsePoint -Path $shortcut -TrustedBase $desktop
            Assert-Throws { Assert-NoReparsePoint -Path $shortcut } 'reparse|link'
            try {
                New-Item -ItemType Junction -Path $linkedChild -Target $syncRoot -ErrorAction Stop | Out-Null
                $nested = Join-Path $linkedChild 'DeskPilot.lnk'
                Set-Content -LiteralPath $nested -Value 'fixture'
                Assert-Throws { Assert-NoReparsePoint -Path $nested -TrustedBase $desktop } 'reparse|link'
            } catch [Management.Automation.ItemNotFoundException] { Write-Host 'SKIP nested junction fixture unavailable' }
        } finally {
            foreach ($junction in @($linkedChild, $oneDrive)) {
                if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) }
            }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'safe cleanup removes read-only managed files' {
        $readOnly = Join-Path $temp 'read-only.txt'
        Set-Content -LiteralPath $readOnly -Value 'fixture'
        Set-ItemProperty -LiteralPath $readOnly -Name IsReadOnly -Value $true
        Remove-SafePath $readOnly
        Assert (-not (Test-Path -LiteralPath $readOnly)) 'Read-only managed file was not removed.'
    }

    Test-Case 'missing LOCALAPPDATA fails validation before any install work' {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $installerPath + '"'
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables.Remove('LOCALAPPDATA')
        $process = [Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Assert ($process.ExitCode -ne 0 -and $output -match 'LOCALAPPDATA') "Missing LOCALAPPDATA was not rejected explicitly: $output"
    }

    Test-Case 'shortcut startup and tunnel execution remain opt-in and AUMID-aware' {
        Assert ($source -match 'DeskPilot\.PrivateDesktopControl\.1') 'Shortcut AUMID does not match the launcher APPID.'
        Assert ($source -match 'System\.AppUserModel\.ID') 'Shortcut AUMID property is not assigned.'
        Assert ($source -match '\[switch\]\$EnableStartup') 'Startup must be an explicit opt-in switch.'
        Assert ($source -notmatch 'releases/latest') 'Installer still uses a latest release endpoint.'
        Assert ($source -notmatch '(?m)^\s*Start-Process\s+-FilePath\s+\(Join-Path\s+\$InstallRoot\s+''DeskPilot\.exe''\)') 'Installer auto-launches DeskPilot without an opt-in.'
        Assert ($source -notmatch 'tunnel-client(?:\.exe)?"?\s+run\b') 'Installer must never start the tunnel.'
        Assert ($source -match 'same (?:GitHub )?release account|release-account') 'Script must document the same-release-account trust limitation.'
        Assert ($source -match 'v24\.22\.3/SHASUMS256\.txt') 'Node checksum source metadata must be documented.'
        Assert ($source -match 'https://go\.microsoft\.com/fwlink/p/\?LinkId=2124703') 'Official WebView2 bootstrapper URL is missing.'
        Assert ($source -match 'Ensure-WebView2\s+-BootstrapperPath') 'Installer entry point does not invoke WebView2 setup.'
        Assert ($source.IndexOf('Ensure-WebView2 -BootstrapperPath') -lt $source.IndexOf('Get-VerifiedReleaseArchive $desk')) 'WebView2 must be ready before DeskPilot release installation begins.'
        Assert ($source -match 'New-RuntimeManifest\s+-NodePath') 'Verified runtimes do not produce a runtime manifest.'
        Assert ($source -match 'Target\s*=\s*\(Join-Path\s+\$install\s+''runtime-manifest\.json''\)') 'Runtime manifest is not a transaction target.'
        Assert ($source.IndexOf('New-RuntimeManifest -NodePath') -lt $source.IndexOf('Invoke-PathTransaction -Operations')) 'Runtime manifest must be generated before commit.'
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count -gt 0) {
    Write-Host ('FAILED ' + $script:failures.Count + ' installer security checks:')
    foreach ($failure in $script:failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host "PASS DeskPilot installer security: $script:checks checks"
