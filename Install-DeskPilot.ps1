[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\DeskPilot'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'DeskPilot'),
    [string]$TempRoot = (Join-Path ([IO.Path]::GetTempPath()) ('DeskPilot-Install-' + [Guid]::NewGuid().ToString('N'))),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeskPilot.lnk'),
    [string]$TunnelId,
    [switch]$EnableStartup,
    [switch]$LaunchDeskPilot,
    [switch]$SkipOpenBrowser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Trust boundary: DeskPilot release metadata and its executable come from the same
# GitHub release account. SHA-256 detects corruption, not a compromised release
# account. Authenticode is enforced when a signature is present (and required for
# Node), but unsigned releases still depend on release-account integrity. This is
# a risk reduction measure, not a guarantee against a compromised publisher.
# Exception rollback is transactional; abrupt power loss can leave a hidden
# .deskpilot-transaction-* backup for manual recovery.

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-CanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A path is required.' }
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -match '\A[A-Za-z]:[^\\/]') { throw "An absolute fully qualified path is required: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\')
}

function Assert-NoReparsePoint([string]$Path) {
    $current = Get-CanonicalPath $Path
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Reparse points and links are not allowed: $current"
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-NoReparseTree([string]$Path) {
    $canonical = Get-CanonicalPath $Path
    Assert-NoReparsePoint $canonical
    if (-not (Test-Path -LiteralPath $canonical)) { return }
    $item = Get-Item -LiteralPath $canonical -Force
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -eq 0) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push($item.FullName)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($child in (Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points and links are not allowed: $($child.FullName)"
            }
            if (($child.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $stack.Push($child.FullName) }
        }
    }
}

function Remove-SafePath([string]$Path) {
    $canonical = Get-CanonicalPath $Path
    if ($canonical -eq [IO.Path]::GetPathRoot($canonical)) { throw "Refusing to remove a filesystem root: $canonical" }
    $item = Get-Item -LiteralPath $canonical -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        # Delete the link itself, never its target.
        if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            [IO.Directory]::Delete($item.FullName, $false)
        } else {
            [IO.File]::Delete($item.FullName)
        }
        return
    }
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        foreach ($child in (Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
            Remove-SafePath $child.FullName
        }
        [IO.Directory]::Delete($item.FullName, $false)
    } else {
        [IO.File]::Delete($item.FullName)
    }
}

function Assert-ManagedPath([string]$Path, [string]$Leaf) {
    $canonical = Get-CanonicalPath $Path
    if ($canonical -eq [IO.Path]::GetPathRoot($canonical)) { throw "A filesystem root cannot be used as a managed path: $canonical" }
    if ((Split-Path -Leaf $canonical) -ine $Leaf) { throw "The managed path leaf must be '$Leaf': $canonical" }
    Assert-NoReparsePoint $canonical
    return $canonical
}

function Test-PathsOverlap([string]$First, [string]$Second) {
    $a = Get-CanonicalPath $First
    $b = Get-CanonicalPath $Second
    return ($a -ieq $b -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Test-PathUnderRoot([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $candidate = Get-CanonicalPath $Path
        $canonicalRoot = Get-CanonicalPath $Root
    } catch { return $false }
    return ($candidate.StartsWith($canonicalRoot + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Assert-X64Environment([string]$ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE, [string]$NativeProcessorArchitecture = $env:PROCESSOR_ARCHITEW6432, [bool]$Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem) {
    if (-not $Is64BitOperatingSystem) { throw 'DeskPilot requires a native x64 (AMD64) Windows system.' }
    if ($NativeProcessorArchitecture -and $NativeProcessorArchitecture -ine 'AMD64') {
        throw 'DeskPilot requires a native x64 (AMD64) Windows system.'
    }
    if ($ProcessorArchitecture -ine 'AMD64' -and -not ($ProcessorArchitecture -ieq 'x86' -and $NativeProcessorArchitecture -ieq 'AMD64')) {
        throw 'DeskPilot requires a native x64 (AMD64) Windows system.'
    }
}

function Test-TunnelId([string]$Value) {
    return (-not [string]::IsNullOrEmpty($Value) -and $Value -cmatch '\Atunnel_(?:[a-z0-9]{4}_)?[a-z0-9]{32}\z')
}

function Test-TunnelVersion($Output) {
    $text = (@($Output) -join "`n")
    return ($text -match '(?m)^\s*0\.0\.21(?:\+|\s|\z)')
}

function Get-PinnedArtifacts {
    # Node v24.22.3 is the Node 24 LTS (Krypton) security release listed in
    # https://nodejs.org/dist/index.json. The ZIP hash is copied from
    # https://nodejs.org/dist/v24.22.3/SHASUMS256.txt, not discovered at install time.
    return @(
        [pscustomobject]@{
            Key = 'DeskPilot'; Repository = 'ItisPhoenix/DeskPilot'; Version = 'v1.0.0'
            Name = 'DeskPilot-v1.0.0-windows-x64.zip'
            Url = 'https://github.com/ItisPhoenix/DeskPilot/releases/download/v1.0.0/DeskPilot-v1.0.0-windows-x64.zip'
            Sha256 = $null
        },
        [pscustomobject]@{
            Key = 'TunnelClient'; Repository = 'openai/tunnel-client'; Version = 'v0.0.21'
            Name = 'tunnel-client-v0.0.21-windows-amd64.zip'
            Url = 'https://github.com/openai/tunnel-client/releases/download/v0.0.21/tunnel-client-v0.0.21-windows-amd64.zip'
            Sha256 = '2faf80ae62b58485fcef534cd3f78cd8b82e71cb04d14c2a5c73dbb4eb6c575a'
        },
        [pscustomobject]@{
            Key = 'Node'; Repository = 'nodejs/node'; Version = 'v24.22.3'
            Name = 'node-v24.22.3-win-x64.zip'
            Url = 'https://nodejs.org/dist/v24.22.3/node-v24.22.3-win-x64.zip'
            Sha256 = 'e612af99f626ab415ea225af6bce5c971feb448cb5cae250bb1c3fa50c5f7d9f'
        }
    )
}

function Get-GitHubRelease([string]$Repository, [string]$Tag) {
    if ($Repository -notmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or $Tag -notmatch '\Av[0-9]+\.[0-9]+\.[0-9]+\z') {
        throw 'Invalid pinned GitHub repository or release tag.'
    }
    $headers = @{ 'User-Agent' = 'DeskPilot-Installer'; 'Accept' = 'application/vnd.github+json' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag" -Headers $headers -ErrorAction Stop
    if ($release.tag_name -cne $Tag -or $release.draft -or $release.prerelease) {
        throw "GitHub did not return the required stable release $Tag."
    }
    return $release
}

function Get-Asset($Release, [string]$Name) {
    $assets = @($Release.assets | Where-Object { $_.name -ceq $Name })
    if ($assets.Count -ne 1) { throw "Release $($Release.tag_name) must contain exactly one asset named '$Name'." }
    return $assets[0]
}

function Get-AssetSha256($Asset) {
    if ($Asset.digest -notmatch '\Asha256:[0-9a-fA-F]{64}\z') { throw "Official metadata has no SHA-256 digest for '$($Asset.name)'." }
    return $Asset.digest.Substring(7).ToLowerInvariant()
}

function Get-Checksum([string]$Text, [string]$FileName) {
    $matches = @()
    foreach ($line in ($Text -split '\r?\n')) {
        $match = [regex]::Match($line.Trim(), '\A([0-9a-fA-F]{64})\s+\*?(.+?)\s*\z')
        if ($match.Success -and $match.Groups[2].Value -ceq $FileName) { $matches += $match.Groups[1].Value.ToLowerInvariant() }
    }
    if ($matches.Count -eq 0) { throw "Checksum entry for '$FileName' was not found." }
    if ($matches.Count -ne 1 -or @($matches | Select-Object -Unique).Count -ne 1) { throw "Checksum entries for '$FileName' are duplicate or conflicting." }
    return $matches[0]
}

function Download-Verified([string]$Url, [string]$ExpectedHash, [string]$Destination) {
    if ($Url -notmatch '\Ahttps://') { throw 'Only HTTPS downloads are allowed.' }
    if ($ExpectedHash -notmatch '\A[0-9a-fA-F]{64}\z') { throw 'A full SHA-256 hash is required.' }
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $Destination)) { throw "Download did not create '$Destination'." }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $ExpectedHash.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed for $(Split-Path $Destination -Leaf)."
    }
}

function Get-VerifiedReleaseArchive($Artifact, [string]$Destination) {
    $release = Get-GitHubRelease $Artifact.Repository $Artifact.Version
    $archiveAsset = Get-Asset $release $Artifact.Name
    if ($archiveAsset.browser_download_url -cne $Artifact.Url) { throw "Official metadata returned an unexpected URL for '$($Artifact.Name)'." }
    $sumsAsset = Get-Asset $release 'SHA256SUMS.txt'
    $sumsPath = Join-Path (Split-Path $Destination -Parent) ($Artifact.Key + '-SHA256SUMS.txt')
    Download-Verified $sumsAsset.browser_download_url (Get-AssetSha256 $sumsAsset) $sumsPath
    $sums = [IO.File]::ReadAllText($sumsPath)
    $checksumHash = Get-Checksum $sums $Artifact.Name
    $metadataHash = Get-AssetSha256 $archiveAsset
    if ($checksumHash -cne $metadataHash) { throw "Checksum manifest and release metadata disagree for '$($Artifact.Name)'." }
    if ($Artifact.Sha256 -and $checksumHash -cne $Artifact.Sha256) { throw "The pinned checksum for '$($Artifact.Name)' does not match the official release." }
    Download-Verified $Artifact.Url $checksumHash $Destination
}

function Test-AuthenticodeSignature($Signature, [string]$PublisherPattern, [switch]$AllowUnsigned) {
    if ($null -eq $Signature) { return $false }
    $status = [string]$Signature.Status
    if ($status -ceq 'NotSigned') { return [bool]$AllowUnsigned }
    if ($status -cne 'Valid') { return $false }
    $subject = [string]$Signature.SignerCertificate.Subject
    return ($subject -match $PublisherPattern)
}

function Assert-OfficialBinarySignature([string]$Path, [string]$PublisherPattern, [switch]$AllowUnsigned) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if (-not (Test-AuthenticodeSignature -Signature $signature -PublisherPattern $PublisherPattern -AllowUnsigned:$AllowUnsigned)) {
        throw "Authenticode verification failed for '$(Split-Path $Path -Leaf)' (status: $($signature.Status), signer: $($signature.SignerCertificate.Subject))."
    }
}

function Assert-RuntimeManifest([string]$ManifestPath, [string]$NodePath, [string]$TunnelClientPath) {
    $text = [IO.File]::ReadAllText((Get-CanonicalPath $ManifestPath))
    try { $manifest = $text | ConvertFrom-Json } catch { throw "Runtime manifest is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $manifest) { throw 'Runtime manifest JSON is empty.' }
    $rootProperties = @($manifest.PSObject.Properties.Name)
    if ($rootProperties.Count -ne 2 -or -not ($rootProperties -ccontains 'node') -or -not ($rootProperties -ccontains 'tunnelClient')) { throw 'Runtime manifest root schema is invalid.' }
    $nodeProperties = @($manifest.node.PSObject.Properties.Name)
    if ($nodeProperties.Count -ne 3 -or -not ($nodeProperties -ccontains 'version') -or -not ($nodeProperties -ccontains 'sha256') -or -not ($nodeProperties -ccontains 'signerSubject')) { throw 'Runtime manifest Node schema is invalid.' }
    $tunnelProperties = @($manifest.tunnelClient.PSObject.Properties.Name)
    if ($tunnelProperties.Count -lt 2 -or $tunnelProperties.Count -gt 3 -or -not ($tunnelProperties -ccontains 'version') -or -not ($tunnelProperties -ccontains 'sha256')) { throw 'Runtime manifest tunnelClient schema is invalid.' }
    if ($manifest.node.version -cne '24.22.3' -or $manifest.tunnelClient.version -cne '0.0.21') { throw 'Runtime manifest contains an unexpected runtime version.' }
    if ($manifest.node.signerSubject -cne 'OpenJS Foundation') { throw 'Runtime manifest Node signerSubject is invalid.' }
    if ($tunnelProperties -ccontains 'signerSubject' -and [string]::IsNullOrWhiteSpace([string]$manifest.tunnelClient.signerSubject)) { throw 'Runtime manifest tunnelClient signerSubject is empty.' }
    $nodeHash = (Get-FileHash -LiteralPath $NodePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $tunnelHash = (Get-FileHash -LiteralPath $TunnelClientPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.node.sha256 -cne $nodeHash) { throw 'Runtime manifest Node SHA-256 does not match node.exe.' }
    if ($manifest.tunnelClient.sha256 -cne $tunnelHash) { throw 'Runtime manifest tunnelClient SHA-256 does not match tunnel-client.exe.' }
}

function New-RuntimeManifest([string]$NodePath, [string]$TunnelClientPath, [string]$DestinationPath) {
    $node = Get-CanonicalPath $NodePath
    $tunnel = Get-CanonicalPath $TunnelClientPath
    $destination = Get-CanonicalPath $DestinationPath
    $nodeSignature = Get-AuthenticodeSignature -LiteralPath $node
    if ([string]$nodeSignature.Status -cne 'Valid' -or [string]$nodeSignature.SignerCertificate.Subject -inotmatch 'OpenJS Foundation') {
        throw 'Node Authenticode signature is not valid for OpenJS Foundation.'
    }
    $tunnelSignature = Get-AuthenticodeSignature -LiteralPath $tunnel
    $tunnelSigner = $null
    if ([string]$tunnelSignature.Status -ceq 'Valid') {
        if ([string]$tunnelSignature.SignerCertificate.Subject -inotmatch 'OpenAI') { throw 'Signed tunnel-client Authenticode publisher is not OpenAI.' }
        $tunnelSigner = [string]$tunnelSignature.SignerCertificate.Subject
    } elseif ([string]$tunnelSignature.Status -cne 'NotSigned') {
        throw "tunnel-client Authenticode signature is invalid (status: $($tunnelSignature.Status))."
    }
    $nodeEntry = [ordered]@{
        version = '24.22.3'
        sha256 = (Get-FileHash -LiteralPath $node -Algorithm SHA256).Hash.ToLowerInvariant()
        signerSubject = 'OpenJS Foundation'
    }
    $tunnelEntry = [ordered]@{
        version = '0.0.21'
        sha256 = (Get-FileHash -LiteralPath $tunnel -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($null -ne $tunnelSigner) { $tunnelEntry['signerSubject'] = $tunnelSigner }
    $manifest = [ordered]@{ node = $nodeEntry; tunnelClient = $tunnelEntry }
    try {
        [IO.File]::WriteAllText($destination, (($manifest | ConvertTo-Json -Depth 4) + "`n"), [Text.UTF8Encoding]::new($false))
        Assert-RuntimeManifest -ManifestPath $destination -NodePath $node -TunnelClientPath $tunnel
    } catch {
        if (Test-Path -LiteralPath $destination) { Remove-SafePath $destination }
        throw
    }
}

function Test-ZipEntryHasReparseTag($Entry) {
    $extra = [byte[]]$Entry.Extra
    # NTFS, Microsoft reparse, and Unix link metadata are not needed by these
    # Windows release ZIPs. Reject known reparse tags wherever they appear.
    $tags = @(
        [byte[]](0x03, 0x00, 0x00, 0xA0), # IO_REPARSE_TAG_MOUNT_POINT
        [byte[]](0x12, 0x00, 0x00, 0xA0), # IO_REPARSE_TAG_SYMLINK
        [byte[]](0x0D, 0x00, 0x00, 0x20)  # IO_REPARSE_TAG_NAME_SURROGATE
    )
    for ($i = 0; $i -le $extra.Length - 4; $i++) {
        foreach ($tag in $tags) {
            if ($extra[$i] -eq $tag[0] -and $extra[$i + 1] -eq $tag[1] -and $extra[$i + 2] -eq $tag[2] -and $extra[$i + 3] -eq $tag[3]) { return $true }
        }
    }
    return $false
}

function Expand-SafeZip(
    [string]$ArchivePath,
    [string]$DestinationPath,
    [long]$MaxExpandedBytes = 2GB,
    [int]$MaxEntries = 100000,
    [int]$MaxExpansionRatio = 200
) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $destination = Get-CanonicalPath $DestinationPath
    if ($destination -eq [IO.Path]::GetPathRoot($destination)) { throw 'ZIP extraction cannot target a filesystem root.' }
    if (Test-Path -LiteralPath $destination) { throw "ZIP extraction destination already exists: $destination" }
    Assert-NoReparsePoint $destination
    $stream = [IO.File]::OpenRead($ArchivePath)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $plans = @()
            $planMap = @{}
            $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $totalExpanded = [long]0
            $totalCompressed = [long]0
            if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt $MaxEntries) { throw 'ZIP entry count exceeds the allowed limit or the archive is empty.' }
            foreach ($entry in $archive.Entries) {
                $name = [string]$entry.FullName
                if ([string]::IsNullOrEmpty($name) -or $name.IndexOf([char]0) -ge 0 -or $name.IndexOf('`') -ge 0 -or $name.Contains('\') -or $name.IndexOf(':') -ge 0) {
                    throw "Unsafe ZIP entry path: $name"
                }
                $isDirectory = $name.EndsWith('/')
                $relative = $name.TrimEnd('/')
                $segments = @($relative -split '/')
                if ($segments.Count -eq 0 -or ($segments | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -ceq '.' -or $_ -ceq '..' })) {
                    throw "Unsafe ZIP traversal path: $name"
                }
                foreach ($segment in $segments) {
                    if ($segment -match '[\x00-\x1f<>"|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -imatch '\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                        throw "Unsafe ZIP path segment: $segment"
                    }
                }
                if ([IO.Path]::IsPathRooted($name)) { throw "Absolute ZIP entry paths are not allowed: $name" }
                if (-not $names.Add($relative)) { throw "Duplicate ZIP entry path: $relative" }

                $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xFFFF)
                $unixType = ($unixMode -band 0xF000)
                $dosAttributes = ($entry.ExternalAttributes -band 0xFFFF)
                if (($dosAttributes -band 0x400) -ne 0 -or (Test-ZipEntryHasReparseTag $entry)) { throw "ZIP reparse points and links are not allowed: $name" }
                if ($unixType -ne 0 -and $unixType -ne 0x8000 -and $unixType -ne 0x4000) { throw "ZIP links and special files are not allowed: $name" }
                if (($unixType -eq 0x4000) -and -not $isDirectory) { throw "ZIP directory entry is malformed: $name" }
                if ($isDirectory -and [long]$entry.Length -ne 0) { throw "ZIP directory entry contains data: $name" }

                $windowsRelative = $relative -replace '/', '\'
                $target = [IO.Path]::GetFullPath([IO.Path]::Combine($destination, $windowsRelative))
                if (-not (Test-PathUnderRoot $target $destination)) { throw "Unsafe ZIP entry escapes its destination: $name" }
                $totalExpanded += [long]$entry.Length
                $totalCompressed += [long]$entry.CompressedLength
                if ($totalExpanded -gt $MaxExpandedBytes) { throw 'ZIP expanded size exceeds the allowed expansion limit.' }
                $plan = [pscustomobject]@{ Entry = $entry; Relative = $relative; Target = $target; IsDirectory = ($isDirectory -or $unixType -eq 0x4000) }
                $plans += $plan
                $planMap[$relative] = $plan
            }
            # Check parent types after all entries are known so a file that
            # appears after one of its children is still rejected pre-extraction.
            foreach ($plan in $plans) {
                $parentPath = [IO.Path]::GetDirectoryName($plan.Target)
                while ($parentPath -and $parentPath -ne $destination) {
                    $parentRelative = $parentPath.Substring($destination.Length).TrimStart('\')
                    $parentPlan = $planMap[$parentRelative]
                    if ($null -ne $parentPlan -and -not $parentPlan.IsDirectory) { throw "ZIP file/directory path collision: $($plan.Relative)" }
                    $parentPath = [IO.Path]::GetDirectoryName($parentPath)
                }
            }
            if ($totalCompressed -le 0 -or ($totalExpanded / [double]$totalCompressed) -gt $MaxExpansionRatio) { throw 'ZIP expansion ratio exceeds the allowed limit.' }

            # No output exists until every central-directory entry has passed.
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            try {
                foreach ($plan in $plans) {
                    Assert-NoReparsePoint $plan.Target
                    if ($plan.IsDirectory) {
                        New-Item -ItemType Directory -Path $plan.Target -Force | Out-Null
                        continue
                    }
                    $parent = [IO.Path]::GetDirectoryName($plan.Target)
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    Assert-NoReparsePoint $parent
                    $inputStream = $plan.Entry.Open()
                    $outputStream = [IO.File]::Open($plan.Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    try {
                        $inputStream.CopyTo($outputStream, 81920)
                    } finally {
                        $outputStream.Dispose()
                        $inputStream.Dispose()
                    }
                    if ((Get-Item -LiteralPath $plan.Target).Length -ne [long]$plan.Entry.Length) { throw "ZIP entry size changed while extracting: $($plan.Relative)" }
                }
                Assert-NoReparseTree $destination
            } catch {
                Remove-SafePath $destination
                throw
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Set-YamlScalar([string]$Line, [string]$JsonValue) {
    $match = [regex]::Match($Line, '\A(\s*[A-Za-z0-9_.-]+\s*:\s*)(.*)\z')
    if (-not $match.Success) { throw 'Unable to update the YAML scalar.' }
    return $match.Groups[1].Value + $JsonValue
}

function Get-YamlKeyName([string]$Line) {
    $trimmed = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { return '' }
    $match = [regex]::Match($trimmed, '\A(?:"([^"]+)"|''([^'']+)''|([A-Za-z0-9_.-]+))\s*:')
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    if ($match.Groups[2].Success) { return $match.Groups[2].Value }
    return $match.Groups[3].Value
}

function Find-YamlChildLine([string[]]$Lines, [string]$ParentKey, [string]$ChildKey) {
    $parent = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Get-YamlKeyName $Lines[$i]) -ceq $ParentKey) { $parent = $i; break }
    }
    if ($parent -lt 0) { throw "The existing profile is missing '$ParentKey'." }
    for ($i = $parent + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\S' -and $Lines[$i] -notmatch '^\s*#') { break }
        if ((Get-YamlKeyName $Lines[$i]) -ceq $ChildKey) { return $i }
    }
    throw "The existing profile is missing '$ParentKey.$ChildKey'."
}

function Set-YamlChildValue([System.Collections.Generic.List[string]]$Lines, [string]$ParentKey, [string]$ChildKey, [string]$JsonValue) {
    $parent = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Get-YamlKeyName $Lines[$i]) -ceq $ParentKey) { $parent = $i; break }
    }
    if ($parent -lt 0) {
        $Lines.Add($ParentKey + ':')
        $parent = $Lines.Count - 1
    }
    $end = $Lines.Count
    for ($i = $parent + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\S' -and $Lines[$i] -notmatch '^\s*#') { $end = $i; break }
    }
    $childIndent = 2
    for ($i = $parent + 1; $i -lt $end; $i++) {
        if ($Lines[$i] -match '^(\s+)\S' -and $Lines[$i] -notmatch '^\s*#') {
            $childIndent = $Matches[1].Length
            break
        }
    }
    for ($i = $parent + 1; $i -lt $end; $i++) {
        if ((Get-YamlKeyName $Lines[$i]) -ceq $ChildKey) {
            $Lines[$i] = Set-YamlScalar $Lines[$i] $JsonValue
            return
        }
    }
    $Lines.Insert($end, (' ' * $childIndent) + $ChildKey + ': ' + $JsonValue)
}

function New-DashboardBasePath {
    $bytes = New-Object byte[] 18
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return '/deskpilot-' + $token
}

function Remove-YamlChildValue([System.Collections.Generic.List[string]]$Lines, [string]$ParentKey, [string]$ChildKey) {
    $parent = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ((Get-YamlKeyName $Lines[$i]) -ceq $ParentKey) { $parent = $i; break }
    }
    if ($parent -lt 0) { return }
    $end = $Lines.Count
    for ($i = $parent + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\S' -and $Lines[$i] -notmatch '^\s*#') { $end = $i; break }
    }
    for ($i = $parent + 1; $i -lt $end; $i++) {
        if ((Get-YamlKeyName $Lines[$i]) -ceq $ChildKey) {
            $Lines.RemoveAt($i)
            return
        }
    }
}

function Remove-YamlSection([System.Collections.Generic.List[string]]$Lines, [string]$SectionKey) {
    while ($true) {
        $start = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ((Get-YamlKeyName $Lines[$i]) -ceq $SectionKey) { $start = $i; break }
        }
        if ($start -lt 0) { return }
        $end = $Lines.Count
        for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^\S' -and $Lines[$i] -notmatch '^\s*#') { $end = $i; break }
        }
        $Lines.RemoveRange($start, $end - $start)
    }
}

function Remove-YamlScalarKey([System.Collections.Generic.List[string]]$Lines, [string]$Key) {
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        if ((Get-YamlKeyName $Lines[$i]) -ceq $Key) { $Lines.RemoveAt($i) }
    }
}

function Remove-YamlTokenLines([System.Collections.Generic.List[string]]$Lines, [string]$Token) {
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.TrimStart().StartsWith('#') -and $line.ToLowerInvariant().Contains($Token.ToLowerInvariant())) {
            $Lines.RemoveAt($i)
        }
    }
}

function Update-TunnelProfile([string]$ExistingText, [string]$TunnelId, [string]$NodePath, [string]$InstallRoot) {
    if (-not (Test-TunnelId $TunnelId)) { throw 'The tunnel ID does not match the required service format.' }
    $node = Get-CanonicalPath $NodePath
    $install = Get-CanonicalPath $InstallRoot
    $command = '"' + $node + '" "' + (Join-Path $install 'server\managed-launcher.mjs') + '"'
    $yamlId = ConvertTo-Json -InputObject $TunnelId -Compress
    $yamlCommand = ConvertTo-Json -InputObject $command -Compress
    $basePath = New-DashboardBasePath
    $yamlBasePath = ConvertTo-Json -InputObject $basePath -Compress
    if ([string]::IsNullOrWhiteSpace($ExistingText)) {
        return @"
config_version: 1
control_plane:
  base_url: "https://api.openai.com"
  tunnel_id: $yamlId
  api_key: "env:CONTROL_PLANE_API_KEY"
health:
  listen_addr: "127.0.0.1:18080"
admin_ui:
  allow_remote: false
  open_browser: false
  base_path: $yamlBasePath
log:
  level: info
  format: json
mcp:
  commands:
    - channel: main
      command: $yamlCommand
"@
    }

    $newline = if ($ExistingText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hadFinalNewline = $ExistingText.EndsWith("`n")
    $rawLines = @($ExistingText -split '\r?\n')
    if ($hadFinalNewline -and $rawLines.Count -gt 0 -and $rawLines[-1] -ceq '') { $rawLines = @($rawLines[0..($rawLines.Count - 2)]) }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $rawLines) { $lines.Add($line) }
    Remove-YamlSection $lines 'cloudflared'
    Remove-YamlScalarKey $lines 'ca_bundle'
    Remove-YamlScalarKey $lines 'http_proxy'
    Remove-YamlTokenLines $lines 'ca_bundle'
    Remove-YamlTokenLines $lines 'http_proxy'
    Remove-YamlTokenLines $lines 'cloudflared'
    Remove-YamlChildValue $lines 'control_plane' 'url_path'
    Remove-YamlChildValue $lines 'control_plane' 'residency'
    Remove-YamlChildValue $lines 'health' 'unix_socket'
    Remove-YamlChildValue $lines 'health' 'url_file'
    Remove-YamlChildValue $lines 'admin_ui' 'public_origin'
    Set-YamlChildValue $lines 'control_plane' 'base_url' '"https://api.openai.com"'
    Set-YamlChildValue $lines 'control_plane' 'api_key' '"env:CONTROL_PLANE_API_KEY"'
    Set-YamlChildValue $lines 'health' 'listen_addr' '"127.0.0.1:18080"'
    Set-YamlChildValue $lines 'admin_ui' 'allow_remote' 'false'
    Set-YamlChildValue $lines 'admin_ui' 'open_browser' 'false'
    Set-YamlChildValue $lines 'admin_ui' 'base_path' $yamlBasePath
    $idIndex = Find-YamlChildLine $lines.ToArray() 'control_plane' 'tunnel_id'
    $lines[$idIndex] = Set-YamlScalar $lines[$idIndex] $yamlId

    $mcpIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '\Amcp\s*:\s*(?:#.*)?\z') { $mcpIndex = $i; break }
    }
    if ($mcpIndex -lt 0) { throw 'The existing profile is missing mcp.commands.' }
    $mcpEnd = $lines.Count
    for ($i = $mcpIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S' -and $lines[$i] -notmatch '^\s*#') { $mcpEnd = $i; break }
    }
    $commandsIndex = -1
    $commandsIndent = -1
    for ($i = $mcpIndex + 1; $i -lt $mcpEnd; $i++) {
        $commandMatch = [regex]::Match($lines[$i], '\A(\s+)commands\s*:\s*(?:#.*)?\z')
        if ($commandMatch.Success) { $commandsIndex = $i; $commandsIndent = $commandMatch.Groups[1].Length; break }
    }
    if ($commandsIndex -lt 0) { throw 'The existing profile is missing a block-style mcp.commands list.' }
    $commandsEnd = $mcpEnd
    $listIndent = 0
    for ($i = $commandsIndex + 1; $i -lt $mcpEnd; $i++) {
        if ($lines[$i] -match '^\s*#' -or [string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        $indent = ($lines[$i].Length - $lines[$i].TrimStart().Length)
        if ($indent -le $commandsIndent) { $commandsEnd = $i; break }
        if ($listIndent -eq 0 -and $lines[$i] -match '^(\s*)-\s+channel\s*:') { $listIndent = $Matches[1].Length }
    }
    $mainChannelIndex = -1
    $commandLineIndex = -1
    for ($i = $commandsIndex + 1; $i -lt $commandsEnd; $i++) {
        if ($lines[$i] -match '^\s*#' -or [string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        $indent = ($lines[$i].Length - $lines[$i].TrimStart().Length)
        if ($indent -le $commandsIndent) { break }
        if ($lines[$i] -match '^\s*-\s+channel\s*:\s*main\s*(?:#.*)?\z') {
            $mainChannelIndex = $i
            $listIndent = $indent
            for ($j = $i + 1; $j -lt $commandsEnd; $j++) {
                if ($lines[$j] -match '^\s*#' -or [string]::IsNullOrWhiteSpace($lines[$j])) { continue }
                $childIndent = ($lines[$j].Length - $lines[$j].TrimStart().Length)
                if ($childIndent -le $listIndent) { break }
                if ($childIndent -eq ($listIndent + 2) -and $lines[$j] -match '^\s+command\s*:') { $commandLineIndex = $j; break }
            }
            break
        }
    }
    if ($mainChannelIndex -ge 0 -and $commandLineIndex -ge 0) {
        $lines[$commandLineIndex] = Set-YamlScalar $lines[$commandLineIndex] $yamlCommand
    } elseif ($mainChannelIndex -ge 0) {
        $lines.Insert($mainChannelIndex + 1, (' ' * ($listIndent + 2)) + 'command: ' + $yamlCommand)
    } else {
        if ($listIndent -eq 0) { $listIndent = $commandsIndent + 2 }
        $lines.Insert($commandsEnd, (' ' * $listIndent) + '- channel: main')
        $lines.Insert($commandsEnd + 1, (' ' * ($listIndent + 2)) + 'command: ' + $yamlCommand)
    }
    $result = $lines -join $newline
    if ($hadFinalNewline) { $result += $newline }
    return $result
}

function Get-YamlScalarValue([string]$Text) {
    $value = $Text.Trim()
    $quoted = [regex]::Match($value, '\A("(?:[^"\\]|\\.)*"|''(?:[^'']|'')*'')')
    if ($quoted.Success) {
        if ($quoted.Value.StartsWith('"')) { return ConvertFrom-Json $quoted.Value }
        return $quoted.Value.Substring(1, $quoted.Value.Length - 2).Replace("''", "'")
    }
    $plain = [regex]::Match($value, '\A([^\s#]+)')
    if (-not $plain.Success) { throw 'The profile contains an empty YAML scalar.' }
    return $plain.Groups[1].Value
}

function Get-ProfileTunnelId([string]$Text) {
    $lines = @($Text -split '\r?\n')
    $index = Find-YamlChildLine $lines 'control_plane' 'tunnel_id'
    $match = [regex]::Match($lines[$index], '\A\s*tunnel_id\s*:\s*(.*?)\s*\z')
    return Get-YamlScalarValue $match.Groups[1].Value
}

function Invoke-TunnelDoctor([string]$TunnelClient, [string]$ProfilePath) {
    # doctor is offline: it parses and preflights the profile but does not start
    # the tunnel or MCP child. A non-secret placeholder lets a fresh standard
    # profile pass credential-shape validation before the user enters a real key.
    $hadKey = $null -ne $env:CONTROL_PLANE_API_KEY
    $oldKey = $env:CONTROL_PLANE_API_KEY
    if (-not $hadKey -or [string]::IsNullOrWhiteSpace($oldKey)) { $env:CONTROL_PLANE_API_KEY = 'deskpilot-installer-validation-only' }
    try {
        $output = & $TunnelClient doctor --profile-file $ProfilePath --explain 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "tunnel-client doctor validation failed (exit code $exitCode):`n$($output -join "`n")" }
    } finally {
        if ($hadKey) { $env:CONTROL_PLANE_API_KEY = $oldKey } else { Remove-Item Env:\CONTROL_PLANE_API_KEY -ErrorAction SilentlyContinue }
    }
}

function Invoke-PathTransaction($Operations, [scriptblock]$Validation, [int]$ValidateAfter = 0, [scriptblock]$AfterCommit, [string]$PreserveBackupFor, [string]$PreservedBackupPath) {
    $journal = New-Object System.Collections.ArrayList
    $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($operation in $Operations) {
        $operation.Target = Get-CanonicalPath $operation.Target
        $operation.Staged = Get-CanonicalPath $operation.Staged
        $operation.Backup = Get-CanonicalPath $operation.Backup
        if ($operation.Target -eq [IO.Path]::GetPathRoot($operation.Target)) { throw 'A transaction cannot replace a filesystem root.' }
        if (-not (Test-Path -LiteralPath $operation.Staged)) { throw "Transaction staging path is missing: $($operation.Staged)" }
        if (Test-Path -LiteralPath $operation.Backup) { throw "Transaction backup path already exists: $($operation.Backup)" }
        if (-not $targets.Add($operation.Target)) { throw "Duplicate transaction target: $($operation.Target)" }
        Assert-NoReparsePoint $operation.Target
        Assert-NoReparseTree $operation.Staged
        New-Item -ItemType Directory -Path (Split-Path $operation.Target -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $operation.Backup -Parent) -Force | Out-Null
    }
    try {
        for ($i = 0; $i -lt $Operations.Count; $i++) {
            $operation = $Operations[$i]
            $state = @{ Operation = $operation; HadTarget = (Test-Path -LiteralPath $operation.Target); Moved = $false; Installed = $false }
            $null = $journal.Add($state)
            if ($state.HadTarget) {
                Move-Item -LiteralPath $operation.Target -Destination $operation.Backup -ErrorAction Stop
                $state.Moved = $true
            }
            # Mark the attempt before a cross-volume move so rollback removes a
            # partially copied target if Move-Item fails midway.
            $state.Installed = $true
            Move-Item -LiteralPath $operation.Staged -Destination $operation.Target -ErrorAction Stop
            if ($ValidateAfter -gt 0 -and ($i + 1) -eq $ValidateAfter -and $null -ne $Validation) { & $Validation ($i + 1) }
        }
        if ($null -ne $AfterCommit) { & $AfterCommit }
        if ($PreserveBackupFor) {
            $preserved = @($journal | Where-Object { $_.Operation.Target -ieq (Get-CanonicalPath $PreserveBackupFor) -and $_.Moved } | Select-Object -First 1)
            if ($preserved.Count -gt 0) {
                Move-Item -LiteralPath $preserved[0].Operation.Backup -Destination $PreservedBackupPath -ErrorAction Stop
                $preserved[0].Moved = $false
            }
        }
    } catch {
        $original = $_
        $rollbackErrors = @()
        for ($i = $journal.Count - 1; $i -ge 0; $i--) {
            $state = $journal[$i]
            try {
                if ($state.Installed -and (Test-Path -LiteralPath $state.Operation.Target)) { Remove-SafePath $state.Operation.Target }
                if ($state.Moved -and (Test-Path -LiteralPath $state.Operation.Backup)) { Move-Item -LiteralPath $state.Operation.Backup -Destination $state.Operation.Target -ErrorAction Stop }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count -gt 0) { throw "Transaction failed: $($original.Exception.Message). Rollback also failed: $($rollbackErrors -join '; ')" }
        throw $original
    }
    foreach ($state in $journal) {
        if ($state.Moved -and (Test-Path -LiteralPath $state.Operation.Backup)) { Remove-SafePath $state.Operation.Backup }
    }
}

function New-DeskPilotShortcut([string]$ShortcutPath, [string]$InstallRoot) {
    $shortcutPath = Get-CanonicalPath $ShortcutPath
    if ((Split-Path -Leaf $shortcutPath) -ine 'DeskPilot.lnk') { throw 'The DeskPilot shortcut must be named DeskPilot.lnk.' }
    Assert-NoReparsePoint $shortcutPath
    New-Item -ItemType Directory -Path (Split-Path $shortcutPath -Parent) -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $InstallRoot 'DeskPilot.exe'
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.IconLocation = Join-Path $InstallRoot 'DeskPilot.exe'
    $shortcut.Description = 'DeskPilot Private Desktop Control'
    $shortcut.Save()
    $explorer = New-Object -ComObject Shell.Application
    $folder = $explorer.Namespace((Split-Path $shortcutPath -Parent))
    $item = $folder.ParseName((Split-Path $shortcutPath -Leaf))
    if ($null -eq $item) { throw 'Could not reopen the staged DeskPilot shortcut.' }
    # Match launcher/src/core.inc.rs APPID so taskbar identity is stable.
    $item.ExtendedProperty('System.AppUserModel.ID') = 'DeskPilot.PrivateDesktopControl.1'
}

function Set-StartupPreference([string]$InstallRoot, [switch]$Enabled) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $name = 'DeskPilot'
    $existing = Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
    try {
        if ($Enabled) {
            $value = '"' + (Join-Path $InstallRoot 'DeskPilot.exe') + '" --background'
            Set-ItemProperty -LiteralPath $key -Name $name -Value $value -Type String -ErrorAction Stop
        } elseif ($null -ne $existing) {
            Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop
        }
    } catch {
        if ($null -ne $existing) {
            Set-ItemProperty -LiteralPath $key -Name $name -Value $existing.$name -Type String -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Test-WebView2Installed {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $value = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($value.name -eq 'Microsoft Edge WebView2 Runtime' -and $value.pv) { return $true }
        }
    }
    return $false
}

function Ensure-WebView2([string]$BootstrapperPath) {
    if (Test-WebView2Installed) {
        return [pscustomobject]@{ Installed = $true; ExitCode = $null; RebootRequired = $false; Sha256 = $null }
    }
    $url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
    $bootstrapper = Get-CanonicalPath $BootstrapperPath
    Assert-NoReparsePoint $bootstrapper
    try {
        Write-Step 'Installing Microsoft Edge WebView2 Runtime'
        # Microsoft's Evergreen bootstrapper URL changes over time and has no
        # stable published SHA-256 pin. Its valid Microsoft Authenticode signature
        # is the publisher verification; the two hashes below detect local changes
        # between download, signature verification, and execution.
        Invoke-WebRequest -Uri $url -OutFile $bootstrapper -UseBasicParsing -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $bootstrapper)) { throw 'The WebView2 bootstrapper download did not create a file.' }
        $downloadedHash = (Get-FileHash -LiteralPath $bootstrapper -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($downloadedHash -notmatch '\A[0-9a-f]{64}\z') { throw 'The WebView2 bootstrapper SHA-256 could not be computed.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
        if ([string]$signature.Status -cne 'Valid' -or [string]$signature.SignerCertificate.Subject -inotmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
            throw "The WebView2 bootstrapper is not validly signed by Microsoft (status: $($signature.Status))."
        }
        $executionHash = (Get-FileHash -LiteralPath $bootstrapper -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($executionHash -cne $downloadedHash) { throw 'The WebView2 bootstrapper hash changed after signature verification.' }

        $process = Start-Process -FilePath $bootstrapper -ArgumentList @('/silent', '/install') -Wait -PassThru
        $exitCode = [int]$process.ExitCode
        if ($exitCode -notin @(0, 1641, 3010)) { throw "WebView2 setup failed with exit code $exitCode." }
        if (-not (Test-WebView2Installed)) { throw 'WebView2 registry verification failed after setup.' }
        return [pscustomobject]@{
            Installed = $true
            ExitCode = $exitCode
            RebootRequired = ($exitCode -in @(1641, 3010))
            Sha256 = $downloadedHash
        }
    } catch {
        # WebView2 is a shared machine dependency. A failure aborts before any
        # DeskPilot swap; never uninstall it as rollback because other applications
        # may rely on it. The staged bootstrapper is always removed below.
        throw "WebView2 Runtime setup failed: $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $bootstrapper) { Remove-SafePath $bootstrapper }
    }
}

function Assert-NoManagedProcesses([string]$InstallRoot, [string]$DataRoot) {
    $managed = @(Get-CimInstance Win32_Process | Where-Object {
        $path = [string]$_.ExecutablePath
        (Test-PathUnderRoot $path $InstallRoot) -or (Test-PathUnderRoot $path (Join-Path $DataRoot 'bin')) -or (Test-PathUnderRoot $path (Join-Path $DataRoot 'runtime'))
    })
    if ($managed.Count -gt 0) { throw 'A DeskPilot-managed process is running. Close DeskPilot and its tunnel before installing.' }
}

function Invoke-Installer {
    param(
        [string]$InstallRoot,
        [string]$DataRoot,
        [string]$TempRoot,
        [string]$ShortcutPath,
        [string]$TunnelId,
        [switch]$EnableStartup,
        [switch]$LaunchDeskPilot,
        [switch]$SkipOpenBrowser
    )
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    $tempBase = $null
    $workRoot = $null
    $createdTempBase = $false
    $createdDataRoot = $false
    $createdInstallParent = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable. Run this installer from a normal Windows user session.' }
        $local = Get-CanonicalPath $env:LOCALAPPDATA
        if ($local -eq [IO.Path]::GetPathRoot($local) -or -not (Test-Path -LiteralPath $local -PathType Container)) { throw 'LOCALAPPDATA must name an existing non-root directory.' }
        Assert-NoReparsePoint $local
        Assert-X64Environment
        $install = Assert-ManagedPath $InstallRoot 'DeskPilot'
        $data = Assert-ManagedPath $DataRoot 'DeskPilot'
        $shortcut = Get-CanonicalPath $ShortcutPath
        if ((Split-Path -Leaf $shortcut) -ine 'DeskPilot.lnk') { throw 'The shortcut path must end in DeskPilot.lnk.' }
        Assert-NoReparsePoint $shortcut
        if (-not (Test-Path -LiteralPath (Split-Path $shortcut -Parent) -PathType Container)) { throw 'The desktop shortcut directory does not exist.' }
        $tempBase = Get-CanonicalPath $TempRoot
        if ($tempBase -eq [IO.Path]::GetPathRoot($tempBase)) { throw 'TEMP root cannot be a filesystem root.' }
        Assert-NoReparsePoint $tempBase
        if ((Test-PathsOverlap $install $data) -or (Test-PathsOverlap $tempBase $install) -or (Test-PathsOverlap $tempBase $data)) { throw 'Install, data, and temporary roots must be distinct and non-overlapping.' }
        if ($TunnelId -and -not (Test-TunnelId $TunnelId)) { throw 'The tunnel ID does not match the required service format.' }

        $profilePath = Join-Path $data 'tunnel-client.yaml'
        $existingProfile = ''
        if (Test-Path -LiteralPath $profilePath) {
            Assert-NoReparsePoint $profilePath
            $existingProfile = [IO.File]::ReadAllText($profilePath)
        }
        $resolvedTunnelId = $TunnelId
        if ([string]::IsNullOrWhiteSpace($resolvedTunnelId) -and -not [string]::IsNullOrWhiteSpace($existingProfile)) {
            $resolvedTunnelId = Get-ProfileTunnelId $existingProfile
        }
        if ([string]::IsNullOrWhiteSpace($resolvedTunnelId)) {
            if (-not $SkipOpenBrowser) { Start-Process 'https://platform.openai.com/settings/organization/tunnels' }
            $resolvedTunnelId = Read-Host 'Paste your OpenAI tunnel ID'
        }
        if (-not (Test-TunnelId $resolvedTunnelId)) { throw 'The tunnel ID does not match the required service format.' }

        $runtimeRoot = Join-Path $data 'runtime'
        $tunnelRoot = Join-Path $data 'bin'
        $permissionsPath = Join-Path $data 'permissions.txt'
        Assert-NoManagedProcesses $install $data
        if (Test-Path -LiteralPath $data -and -not (Test-Path -LiteralPath $data -PathType Container)) { throw "Data root is not a directory: $data" }
        if (Test-Path -LiteralPath $install -and -not (Test-Path -LiteralPath $install -PathType Container)) { throw "Install root is not a directory: $install" }
        Assert-NoReparseTree $runtimeRoot
        Assert-NoReparseTree $tunnelRoot
        Assert-NoReparseTree $install
        Assert-NoReparsePoint $permissionsPath

        # Inputs and existing user state are validated before staging or swapping.
        $createdTempBase = -not (Test-Path -LiteralPath $tempBase)
        New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
        $workRoot = Join-Path $tempBase ('work-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workRoot | Out-Null
        $webView2 = Ensure-WebView2 -BootstrapperPath (Join-Path $workRoot 'MicrosoftEdgeWebView2Setup.exe')
        if ($webView2.RebootRequired) { Write-Warning 'WebView2 was installed and requires a Windows restart to finish setup.' }
        $artifacts = Get-PinnedArtifacts
        $desk = $artifacts | Where-Object Key -eq 'DeskPilot' | Select-Object -First 1
        $tunnel = $artifacts | Where-Object Key -eq 'TunnelClient' | Select-Object -First 1
        $node = $artifacts | Where-Object Key -eq 'Node' | Select-Object -First 1

        Write-Step 'Downloading pinned releases'
        $deskZip = Join-Path $workRoot $desk.Name
        $tunnelZip = Join-Path $workRoot $tunnel.Name
        $nodeZip = Join-Path $workRoot $node.Name
        Get-VerifiedReleaseArchive $desk $deskZip
        Get-VerifiedReleaseArchive $tunnel $tunnelZip
        Download-Verified $node.Url $node.Sha256 $nodeZip

        Write-Step 'Validating and extracting archives'
        $appExtract = Join-Path $workRoot 'app-extract'
        $tunnelExtract = Join-Path $workRoot 'tunnel-extract'
        $nodeExtract = Join-Path $workRoot 'node-extract'
        Expand-SafeZip -ArchivePath $deskZip -DestinationPath $appExtract
        Expand-SafeZip -ArchivePath $tunnelZip -DestinationPath $tunnelExtract
        Expand-SafeZip -ArchivePath $nodeZip -DestinationPath $nodeExtract

        $deskExecutables = @(Get-ChildItem -LiteralPath $appExtract -Recurse -File -Filter 'DeskPilot.exe')
        if ($deskExecutables.Count -ne 1) { throw 'The verified DeskPilot archive must contain exactly one DeskPilot.exe.' }
        $deskRoot = $deskExecutables[0].Directory.FullName
        if (-not (Test-Path -LiteralPath (Join-Path $deskRoot 'server\managed-launcher.mjs')) -or -not (Test-Path -LiteralPath (Join-Path $deskRoot 'server\dist\index.js'))) { throw 'The DeskPilot release archive is missing its server runtime.' }
        Assert-OfficialBinarySignature $deskExecutables[0].FullName 'DeskPilot' -AllowUnsigned
        $appStage = Join-Path $workRoot 'stage/app'
        New-Item -ItemType Directory -Path (Split-Path $appStage -Parent) -Force | Out-Null
        Move-Item -LiteralPath $deskRoot -Destination $appStage

        $tunnelExecutables = @(Get-ChildItem -LiteralPath $tunnelExtract -Recurse -File -Filter 'tunnel-client.exe')
        if ($tunnelExecutables.Count -ne 1) { throw 'The full tunnel-client archive must contain exactly one tunnel-client.exe.' }
        $tunnelStage = Join-Path $workRoot 'stage/bin'
        New-Item -ItemType Directory -Path $tunnelStage | Out-Null
        Copy-Item -LiteralPath (Join-Path $tunnelExecutables[0].Directory.FullName '*') -Destination $tunnelStage -Recurse -Force
        Assert-NoReparseTree $tunnelStage
        Assert-OfficialBinarySignature (Join-Path $tunnelStage 'tunnel-client.exe') 'OpenAI' -AllowUnsigned
        $cloudflared = Join-Path $tunnelStage 'cloudflared.exe'
        if (Test-Path -LiteralPath $cloudflared) { Assert-OfficialBinarySignature $cloudflared 'Cloudflare' -AllowUnsigned }
        $tunnelClient = Join-Path $tunnelStage 'tunnel-client.exe'
        $tunnelVersion = & $tunnelClient --version
        if ($LASTEXITCODE -ne 0 -or -not (Test-TunnelVersion $tunnelVersion)) { throw 'The downloaded full tunnel-client is not version 0.0.21.' }

        $nodeExecutables = @(Get-ChildItem -LiteralPath $nodeExtract -Recurse -File -Filter 'node.exe')
        if ($nodeExecutables.Count -ne 1) { throw 'The verified Node archive must contain exactly one node.exe.' }
        $nodeStage = Join-Path $workRoot 'stage/runtime'
        New-Item -ItemType Directory -Path $nodeStage | Out-Null
        Copy-Item -LiteralPath $nodeExecutables[0].FullName -Destination (Join-Path $nodeStage 'node.exe')
        foreach ($name in @('LICENSE', 'README.md', 'CHANGELOG.md')) {
            $source = Join-Path $nodeExecutables[0].Directory.FullName $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $nodeStage }
        }
        $stagedNode = Join-Path $nodeStage 'node.exe'
        Assert-OfficialBinarySignature $stagedNode 'OpenJS Foundation' # Required: Node publishes signed Windows binaries.
        $nodeVersionOutput = & $stagedNode --version
        if ($LASTEXITCODE -ne 0 -or ($nodeVersionOutput | Select-Object -First 1) -cne 'v24.22.3') { throw 'The downloaded Node runtime is not the pinned v24.22.3 release.' }

        $runtimeManifestStage = Join-Path $workRoot 'stage/runtime-manifest.json'
        New-RuntimeManifest -NodePath $stagedNode -TunnelClientPath $tunnelClient -DestinationPath $runtimeManifestStage

        $profileStage = Join-Path $workRoot 'stage/tunnel-client.yaml'
        $profileText = Update-TunnelProfile -ExistingText $existingProfile -TunnelId $resolvedTunnelId -NodePath (Join-Path $runtimeRoot 'node.exe') -InstallRoot $install
        [IO.File]::WriteAllText($profileStage, $profileText, [Text.UTF8Encoding]::new($false))
        $permissionsStage = Join-Path $workRoot 'stage/permissions.txt'
        if (Test-Path -LiteralPath $permissionsPath) { Copy-Item -LiteralPath $permissionsPath -Destination $permissionsStage } else { [IO.File]::WriteAllText($permissionsStage, '0', [Text.UTF8Encoding]::new($false)) }
        $shortcutStage = Join-Path $workRoot 'stage/DeskPilot.lnk'
        New-DeskPilotShortcut $shortcutStage $install

        $installParent = Split-Path -Parent $install
        $createdInstallParent = -not (Test-Path -LiteralPath $installParent)
        $createdDataRoot = -not (Test-Path -LiteralPath $data)
        New-Item -ItemType Directory -Path $installParent, $data -Force | Out-Null
        $transactionId = [Guid]::NewGuid().ToString('N')
        $dataBackupRoot = Join-Path $data ".deskpilot-transaction-$transactionId"
        $appBackupRoot = Join-Path $installParent ".DeskPilot-transaction-$transactionId"
        New-Item -ItemType Directory -Path $dataBackupRoot, $appBackupRoot | Out-Null
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $preservedBackup = "$install.backup-$timestamp"
        if (Test-Path -LiteralPath $preservedBackup) { throw "An installation backup already exists: $preservedBackup" }
        $operations = @(
            [pscustomobject]@{ Target = $tunnelRoot; Staged = $tunnelStage; Backup = (Join-Path $dataBackupRoot 'bin') },
            [pscustomobject]@{ Target = $runtimeRoot; Staged = $nodeStage; Backup = (Join-Path $dataBackupRoot 'runtime') }
        )
        $operations += @(
            [pscustomobject]@{ Target = $install; Staged = $appStage; Backup = (Join-Path $appBackupRoot 'app') },
            [pscustomobject]@{ Target = (Join-Path $install 'runtime-manifest.json'); Staged = $runtimeManifestStage; Backup = (Join-Path $appBackupRoot 'runtime-manifest.json') },
            [pscustomobject]@{ Target = $profilePath; Staged = $profileStage; Backup = (Join-Path $dataBackupRoot 'profile.yaml') },
            [pscustomobject]@{ Target = $shortcut; Staged = $shortcutStage; Backup = (Join-Path (Split-Path $shortcut -Parent) ".DeskPilot-shortcut-backup-$transactionId.lnk") },
            [pscustomobject]@{ Target = $permissionsPath; Staged = $permissionsStage; Backup = (Join-Path $dataBackupRoot 'permissions.txt') }
        )
        $startupStage = $null
        if ($EnableStartup) {
            $startupStage = Join-Path $workRoot 'stage/launch-on-sign-in.txt'
            [IO.File]::WriteAllText($startupStage, '1', [Text.UTF8Encoding]::new($false))
            $operations += [pscustomobject]@{ Target = (Join-Path $data 'launch-on-sign-in.txt'); Staged = $startupStage; Backup = (Join-Path $dataBackupRoot 'launch-on-sign-in.txt') }
        }

        Write-Step 'Validating the staged installation'
        $validation = {
            param($Completed)
            # doctor validates the final absolute Node path and never starts the
            # tunnel or MCP child. Dependencies are already in their final paths.
            Invoke-TunnelDoctor -TunnelClient (Join-Path $tunnelRoot 'tunnel-client.exe') -ProfilePath $profileStage
        }
        $afterCommit = {
            if ($EnableStartup) { Set-StartupPreference -InstallRoot $install -Enabled }
        }
        try {
            Invoke-PathTransaction -Operations $operations -Validation $validation -ValidateAfter 2 -AfterCommit $afterCommit -PreserveBackupFor $install -PreservedBackupPath $preservedBackup
        } catch {
            if ($createdDataRoot -and (Test-Path -LiteralPath $data)) { Remove-SafePath $data }
            if ($createdInstallParent -and (Test-Path -LiteralPath $installParent)) { Remove-SafePath $installParent }
            throw
        }
        Remove-SafePath $dataBackupRoot
        Remove-SafePath $appBackupRoot

        Write-Host ''
        Write-Host 'DeskPilot is installed.' -ForegroundColor Green
        Write-Host 'The tunnel is not running. Start it manually in DeskPilot after entering a runtime API key with Tunnels Read and Use permissions.'
        Write-Host 'All five desktop permission categories remain unchanged (or disabled on first install).'
        if (Test-Path -LiteralPath $preservedBackup) { Write-Host "Previous installation backup: $preservedBackup" }
        if ($LaunchDeskPilot) {
            $appExecutable = Join-Path $install 'DeskPilot.exe'
            Start-Process -FilePath $appExecutable
        }
    } finally {
        try {
            if ($workRoot) { Remove-SafePath $workRoot }
            if ($createdTempBase -and $tempBase -and (Test-Path -LiteralPath $tempBase)) { Remove-SafePath $tempBase }
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $oldTls
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Installer -InstallRoot $InstallRoot -DataRoot $DataRoot -TempRoot $TempRoot -ShortcutPath $ShortcutPath -TunnelId $TunnelId -EnableStartup:$EnableStartup -LaunchDeskPilot:$LaunchDeskPilot -SkipOpenBrowser:$SkipOpenBrowser
}
