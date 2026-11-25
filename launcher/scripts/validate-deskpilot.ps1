param(
    [string]$ExePath,
    [string]$EvidenceRoot,
    [switch]$RequireSignedLauncher
)

$ErrorActionPreference = 'Stop'
$launcherRoot = Split-Path -Parent $PSScriptRoot
$runId = [guid]::NewGuid().ToString('N')
$results = @()
$failures = 0
$process = $null
$stdoutTask = $null
$stderrTask = $null
$runtimeRoot = $null
$evidenceDir = $null

function Check($name, [bool]$ok, $detail) {
    $script:results += [PSCustomObject]@{
        Check = $name
        Result = $(if ($ok) { 'PASS' } else { 'FAIL' })
        Detail = $detail
    }
    if (-not $ok) { $script:failures++ }
    Write-Output ("{0,-46} {1}  {2}" -f $name, $(if ($ok) { 'PASS' } else { 'FAIL' }), $detail)
}

function Warn($name, $detail) {
    $script:results += [PSCustomObject]@{ Check = $name; Result = 'WARN'; Detail = $detail }
    Write-Output ("{0,-46} {1}  {2}" -f $name, 'WARN', $detail)
}

function Copy-IfPresent($source, $destination) {
    if ($source -and (Test-Path -LiteralPath $source)) {
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

try {
    $evidenceParent = if ($EvidenceRoot) {
        [IO.Path]::GetFullPath($EvidenceRoot)
    } else {
        Join-Path ([IO.Path]::GetTempPath()) 'DeskPilot-validation'
    }
    New-Item -ItemType Directory -Path $evidenceParent -Force | Out-Null
    $evidenceDir = Join-Path $evidenceParent ("run-" + $runId)
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    $runtimeRoot = Join-Path $evidenceDir 'isolated-runtime'
    $localAppData = Join-Path $runtimeRoot 'local-app-data'
    $tempRoot = Join-Path $runtimeRoot 'temp'
    $dataRoot = Join-Path $localAppData 'DeskPilot'
    New-Item -ItemType Directory -Path $dataRoot,$tempRoot -Force | Out-Null

    $exe = if ($ExePath) {
        (Resolve-Path -LiteralPath $ExePath).Path
    } else {
        Join-Path $launcherRoot 'target\release\deskpilot.exe'
    }
    Check 'Launcher executable exists' (Test-Path -LiteralPath $exe -PathType Leaf) $exe

    $core = Get-Content -LiteralPath (Join-Path $launcherRoot 'src\core.inc.rs') -Raw
    $main = Get-Content -LiteralPath (Join-Path $launcherRoot 'src\bin\command-center.rs') -Raw
    $cargoToml = Get-Content -LiteralPath (Join-Path $launcherRoot 'Cargo.toml') -Raw
    $cargoLock = Get-Content -LiteralPath (Join-Path $launcherRoot 'Cargo.lock') -Raw
    $buildScript = Get-Content -LiteralPath (Join-Path $launcherRoot 'build.rs') -Raw

    Check 'No executable PATH fallback' (-not ($core -match 'find_on_path|env::var_os\("PATH"\)')) 'Node and tunnel-client resolve only at managed paths'
    Check 'Single well-named Run value' ($core -match 'const RUN_VALUE_NAME:\s*&str\s*=\s*"DeskPilot";') 'HKCU Run value: DeskPilot'
    Check 'Modern self-test filename only' (-not ($core -match '"self-test\.txt"')) 'self-test-modern.txt is the only result filename'
    Check 'Background path has no start call' (-not ($main -match '[-][-]background[\s\S]{0,800}?\.start\(')) 'sign-in launch never starts the tunnel'
    Check 'Launcher package is 1.0.0' ($cargoToml -match '(?m)^name\s*=\s*"deskpilot-launcher"' -and $cargoToml -match '(?m)^version\s*=\s*"1\.0\.0"') 'deskpilot-launcher 1.0.0'
    Check 'Lockfile root is deskpilot-launcher' ($cargoLock -match '(?s)\[\[package\]\]\s*name\s*=\s*"deskpilot-launcher"\s*version\s*=\s*"1\.0\.0"' -and -not ($cargoLock -match 'name\s*=\s*"desktop-commander-local"')) 'regenerated root package'
    Check 'Build resources stay at 1.0.0' ($buildScript -match 'FILEVERSION 1,0,0,0' -and $buildScript -match 'PRODUCTVERSION 1,0,0,0' -and $buildScript -match '"FileVersion", "1\.0\.0\.0' -and $buildScript -match '"ProductVersion", "1\.0\.0') 'Windows version resources'

    $glibVersions = @([regex]::Matches($cargoLock, '(?s)\[\[package\]\]\s*name\s*=\s*"glib"\s*version\s*=\s*"([^"]+)"') | ForEach-Object { [version]$_.Groups[1].Value })
    if ($glibVersions.Count -eq 0) {
        Check 'glib dependency present' $false 'no glib package found'
    } elseif (@($glibVersions | Where-Object { $_ -ge [version]'0.20' }).Count -eq $glibVersions.Count) {
        Check 'glib is at least 0.20' $true ($glibVersions -join ', ')
    } elseif ($cargoLock -match 'name\s*=\s*"wry"\s*version\s*=\s*"0\.57' -and $cargoLock -match 'name\s*=\s*"gtk"\s*version\s*=\s*"0\.18') {
        Warn 'glib upgrade compatibility' ('wry 0.57 requires gtk 0.18, whose semver excludes glib 0.20; resolved glib: ' + ($glibVersions -join ', '))
    } else {
        Check 'glib is at least 0.20' $false ($glibVersions -join ', ')
    }

    $assetHashes = @{
        'dashboard.html' = '140646F09168DE8F9870BCED99C3F18E6E93DC5D2D4BB4502E42FD40B9330648'
        'deskpilot-wordmark.svg' = 'C1E4E01A231C11BE3F1EEC70916B30A75F4284AFA04F1A4DA03E4E8D2ACAB54C'
        'deskpilot-mark.svg' = '10C045FDCDC2364AB549E454A62E4890D5024F924BF76803DAF726A1D87ABA0D'
        'icon.png' = '3CFDA43D2D27CFFC00863EAD4838242D122608281BC43FC97BA24A437536A250'
        'deskpilot.ico' = '426AEC9B23E6378ECA1BD17A4366F09C4BD9E78C2D7988AAD0DB23661C712269'
    }
    foreach ($asset in $assetHashes.Keys) {
        $assetPath = Join-Path $launcherRoot "assets\$asset"
        $actual = if (Test-Path -LiteralPath $assetPath) { (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash } else { 'MISSING' }
        Check ("Approved asset unchanged: " + $asset) ($actual -eq $assetHashes[$asset]) $actual
    }

    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $signature = Get-AuthenticodeSignature -LiteralPath $exe
        if ($signature.Status -eq 'Valid') {
            Check 'Launcher Authenticode signature' $true $signature.SignerCertificate.Subject
        } elseif ($RequireSignedLauncher) {
            Check 'Launcher Authenticode signature' $false $signature.Status
        } else {
            Warn 'Launcher Authenticode signature' ('development binary is not signed: ' + $signature.Status)
        }
    }

    # Seed stale artifacts so only evidence produced by this run can pass.
    [IO.File]::WriteAllText((Join-Path $dataRoot 'self-test-modern.txt'), 'STALE')
    [IO.File]::WriteAllText((Join-Path $dataRoot 'self-test-evidence-modern.json'), '{"runId":"stale","success":false}')

    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $exe
        $startInfo.Arguments = '--self-test'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $localAppData
        $startInfo.EnvironmentVariables['TEMP'] = $tempRoot
        $startInfo.EnvironmentVariables['TMP'] = $tempRoot
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($process.WaitForExit(30000)) {
            Check 'Native self-test exit code' ($process.ExitCode -eq 0) $process.ExitCode
        } else {
            Check 'Native self-test exit code' $false 'timed out after 30 seconds'
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $evidenceDir 'stdout.txt'), $stdout)
        [IO.File]::WriteAllText((Join-Path $evidenceDir 'stderr.txt'), $stderr)
    }

    $resultPath = Join-Path $dataRoot 'self-test-modern.txt'
    $evidencePath = Join-Path $dataRoot 'self-test-evidence-modern.json'
    Copy-IfPresent $resultPath (Join-Path $evidenceDir 'self-test-modern.txt')
    Copy-IfPresent $evidencePath (Join-Path $evidenceDir 'self-test-evidence-modern.json')

    $resultText = if (Test-Path -LiteralPath $resultPath) { (Get-Content -LiteralPath $resultPath -Raw).Trim() } else { 'MISSING' }
    Check 'Self-test result is fresh and exact' ($resultText -eq 'DPAPI_AND_JOB_PASS') $resultText
    Check 'Legacy self-test filename absent' (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'self-test.txt'))) 'no legacy result accepted'

    if (Test-Path -LiteralPath $evidencePath) {
        $selfTestEvidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
        Check 'Self-test evidence is fresh' ($selfTestEvidence.runId -and $selfTestEvidence.runId -ne 'stale') $selfTestEvidence.runId
        Check 'Job Object close killed descendant tree' ($selfTestEvidence.descendantTreeKilled -eq $true -and $selfTestEvidence.jobObjectClosed -eq $true -and @($selfTestEvidence.processTreePids).Count -eq 3 -and @($selfTestEvidence.survivingDescendantPids).Count -eq 0) ('survivors=' + (@($selfTestEvidence.survivingDescendantPids) -join ','))
        Check 'Self-test temporary artifacts removed' ($selfTestEvidence.tempArtifactsRemoved -eq $true -and @(Get-ChildItem -LiteralPath $tempRoot -Force).Count -eq 0) $tempRoot
    } else {
        Check 'Self-test evidence is fresh' $false 'self-test-evidence-modern.json is missing'
        Check 'Job Object close killed descendant tree' $false 'evidence is missing'
        Check 'Self-test temporary artifacts removed' $false 'evidence is missing'
    }
}
catch {
    Check 'Validator completed without an exception' $false $_.Exception.Message
    if ($evidenceDir) {
        [IO.File]::WriteAllText((Join-Path $evidenceDir 'validator-error.txt'), $_.Exception.ToString())
    }
}
finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit(5000) | Out-Null
            }
        }
        catch {
            Check 'Validator process cleanup' $false $_.Exception.Message
        }
        $process.Dispose()
    }
    if ($runtimeRoot -and (Test-Path -LiteralPath $runtimeRoot)) {
        try {
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
            Check 'Isolated runtime cleaned' $true $runtimeRoot
        }
        catch {
            Check 'Isolated runtime cleaned' $false $_.Exception.Message
        }
    }
    if ($evidenceDir) {
        $summary = [PSCustomObject]@{
            RunId = $runId
            Failures = $failures
            Results = $results
        }
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $evidenceDir 'summary.json') -Encoding UTF8
        Write-Output ''
        Write-Output "EVIDENCE=$evidenceDir"
        Write-Output "TOTAL=$($results.Count) PASS=$(@($results | Where-Object { $_.Result -eq 'PASS' }).Count) WARN=$(@($results | Where-Object { $_.Result -eq 'WARN' }).Count) FAIL=$failures"
    }
    if ($failures -gt 0) { exit 1 }
    exit 0
}
