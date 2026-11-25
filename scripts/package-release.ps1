[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Commit,
    [string]$Version = '1.0.1',
    [string]$Repo = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)][string]$ProdDeps,
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Assert-SafeArchivePath([string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Contains('\') -or $Relative.Contains([char]0) -or $Relative.Contains('`')) {
        throw "Unsafe archive entry path: $Relative"
    }
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative.IndexOf(':') -ge 0 -or $Relative.StartsWith('/')) {
        throw "Absolute archive entry path: $Relative"
    }
    $segments = @($Relative -split '/')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { [string]::IsNullOrEmpty($_) -or $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
        throw "Unsafe archive entry segments: $Relative"
    }
    foreach ($segment in $segments) {
        if ($segment -match '[\x00-\x1f<>"|?*]' -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment -imatch '\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            throw "Unsafe archive entry segment: $segment"
        }
    }
    return $Relative
}

function New-ReleaseArchive([string]$Stage, [string]$Destination) {
    # Compress-Archive writes backslash entry names on Windows, which the
    # installer's Expand-SafeZip rejects. Build the ZIP explicitly so every
    # entry uses a forward-slash relative path with no explicit root entry.
    $files = @(Get-ChildItem -LiteralPath $Stage -Recurse -File -Force)
    if ($files.Count -eq 0) { throw 'Release staging directory is empty.' }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($file in $files) {
                $relative = Assert-SafeArchivePath ($file.FullName.Substring($Stage.Length + 1).Replace('\', '/'))
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $input = [IO.File]::OpenRead($file.FullName)
                try {
                    $output = $entry.Open()
                    try { $input.CopyTo($output, 81920) } finally { $output.Dispose() }
                } finally { $input.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }

    # Re-read the central directory and verify every name before publishing.
    $verify = [IO.File]::OpenRead($Destination)
    try {
        $read = New-Object IO.Compression.ZipArchive($verify, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            if ($read.Entries.Count -ne $files.Count) { throw 'Archive entry count changed after writing.' }
            foreach ($entry in $read.Entries) { $null = Assert-SafeArchivePath ([string]$entry.FullName) }
        } finally { $read.Dispose() }
    } finally { $verify.Dispose() }
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
$stage = Join-Path $OutDir 'stage'
New-Item -ItemType Directory -Path $stage, (Join-Path $stage 'server') -Force | Out-Null

$tracked = @(
    'LICENSE', 'NOTICE', 'UPSTREAM.md', 'README.md', 'PRIVACY.md', 'SECURITY.md',
    'CONTRIBUTING.md', 'CHANGELOG.md', 'PUBLISH.md', 'RELEASE_NOTES.md',
    'Install-DeskPilot.ps1', 'Uninstall-DeskPilot.ps1', 'managed-launcher.mjs', 'package.json', 'docs'
)
Push-Location $Repo
try {
    $tar = Join-Path $OutDir 'tracked.tar'
    git archive -o $tar $Commit @tracked
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
    tar -xf $tar -C $stage
    if ($LASTEXITCODE -ne 0) { throw 'tar extraction failed.' }
} finally { Pop-Location }

Move-Item -LiteralPath (Join-Path $stage 'Install-DeskPilot.ps1') -Destination (Join-Path $stage "Install-DeskPilot-v$Version.ps1")
Move-Item -LiteralPath (Join-Path $stage 'managed-launcher.mjs') -Destination (Join-Path $stage 'server\managed-launcher.mjs')
Move-Item -LiteralPath (Join-Path $stage 'package.json') -Destination (Join-Path $stage 'server\package.json')
Copy-Item -LiteralPath (Join-Path $Repo 'dist') -Destination (Join-Path $stage 'server\dist') -Recurse
Copy-Item -LiteralPath (Join-Path $ProdDeps 'node_modules') -Destination (Join-Path $stage 'server\node_modules') -Recurse
Copy-Item -LiteralPath (Join-Path $Repo 'launcher\target\release\deskpilot.exe') -Destination (Join-Path $stage 'DeskPilot.exe')

$archiveName = "DeskPilot-v$Version-windows-x64.zip"
$installerName = "Install-DeskPilot-v$Version.ps1"
$archivePath = Join-Path $OutDir $archiveName
$installerPath = Join-Path $OutDir $installerName
$checksumsPath = Join-Path $OutDir 'SHA256SUMS.txt'
New-ReleaseArchive -Stage $stage -Destination $archivePath
Copy-Item -LiteralPath (Join-Path $stage $installerName) -Destination $installerPath
$lines = @(
    "$((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant())  $archiveName",
    "$((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLowerInvariant())  $installerName"
)
[IO.File]::WriteAllLines($checksumsPath, $lines, [Text.UTF8Encoding]::new($false))

Write-Host 'RELEASE_ARCHIVE_PATHS_PASS'
Get-Item -LiteralPath $archivePath, $installerPath, $checksumsPath | Select-Object Name, Length
Get-Content -LiteralPath $checksumsPath
