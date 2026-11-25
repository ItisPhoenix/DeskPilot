[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repo 'launcher/Cargo.toml'
$exe = Join-Path $repo 'launcher/target/release/deskpilot.exe'
$paths = @($env:USERPROFILE, $repo, $env:CARGO_HOME, $env:RUSTUP_HOME, $env:TEMP) | Where-Object { $_ } | Select-Object -Unique
$flags = @()
$i = 0
foreach ($p in $paths) {
    $full = [IO.Path]::GetFullPath($p).TrimEnd('\','/')
    foreach ($variant in @($full, $full.Replace('\','/')) | Select-Object -Unique) {
        $flags += "--remap-path-prefix=$variant=/build/path-$i"
    }
    $i++
}
$previous = $env:CARGO_ENCODED_RUSTFLAGS
try {
    $env:CARGO_ENCODED_RUSTFLAGS = $flags -join [char]31
    & cargo build --release --locked --manifest-path $manifest --bin deskpilot
    if ($LASTEXITCODE -ne 0) { throw 'Native privacy-remapped release build failed.' }
} finally {
    if ($null -eq $previous) { Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue }
    else { $env:CARGO_ENCODED_RUSTFLAGS = $previous }
}
$bytes = [IO.File]::ReadAllBytes($exe)
$texts = @([Text.Encoding]::UTF8.GetString($bytes), [Text.Encoding]::Unicode.GetString($bytes), [Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1))
foreach ($p in $paths) {
    $full = [IO.Path]::GetFullPath($p).TrimEnd('\','/')
    foreach ($variant in @($full,$full.Replace('\','/'),$full.Replace('\','\\')) | Select-Object -Unique) {
        foreach ($text in $texts) {
            if ($text.IndexOf($variant,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Native release binary still contains a private build path; do not distribute.' }
        }
    }
}
Write-Host 'NATIVE_BUILD_PRIVACY_PASS'