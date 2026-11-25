[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$uninstallerPath = Join-Path $PSScriptRoot '../Uninstall-DeskPilot.ps1'
$source = Get-Content -LiteralPath $uninstallerPath -Raw
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

# Load only real function definitions. The uninstaller entry point must never run in tests.
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($uninstallerPath, [ref]$tokens, [ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) ("Uninstaller parse errors: " + (($parseErrors | ForEach-Object Message) -join '; '))
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) {
    . ([scriptblock]::Create($function.Extent.Text))
}

function New-FixtureRoot([string]$Prefix) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    return $root
}

$temp = New-FixtureRoot 'deskpilot-uninstaller-test-'
$script:fixtureDesktop = $null
function Get-DeskPilotDesktop {
    if ([string]::IsNullOrWhiteSpace($script:fixtureDesktop)) { throw 'Fixture desktop was not configured.' }
    return Get-CanonicalPath $script:fixtureDesktop
}
try {
    Test-Case 'uninstall roots are canonical explicit DeskPilot leaves' {
        $local = Join-Path $temp 'LocalAppData'
        $install = Join-Path $local 'Programs/DeskPilot'
        $data = Join-Path $local 'DeskPilot'
        $desktop = Join-Path $local 'Desktop'
        $script:fixtureDesktop = $desktop
        $shortcut = Join-Path $desktop 'DeskPilot.lnk'
        New-Item -ItemType Directory -Path $local, $install, $data, $desktop -Force | Out-Null
        $paths = Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot $data -ShortcutPath $shortcut
        Assert ($paths.InstallRoot -eq [IO.Path]::GetFullPath($install)) 'Install root was not canonicalized.'
        Assert ($paths.DataRoot -eq [IO.Path]::GetFullPath($data)) 'Data root was not canonicalized.'
        Assert ($paths.ShortcutPath -eq [IO.Path]::GetFullPath($shortcut)) 'Shortcut path was not canonicalized.'
        Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $local -DataRoot $data -ShortcutPath $shortcut } 'root|leaf|unexpected'
        Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot (Join-Path $local 'Programs/Other') -DataRoot $data -ShortcutPath $shortcut } 'unexpected|DeskPilot'
        Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot (Join-Path $local 'Other') -ShortcutPath $shortcut } 'unexpected|DeskPilot'
        Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot $install -ShortcutPath $shortcut } 'overlap|distinct|same'
        Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot $data -ShortcutPath (Join-Path $desktop 'Other.lnk') } 'shortcut|DeskPilot'
        Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot $data -ShortcutPath (Join-Path $local 'DeskPilot.lnk') } 'shortcut|Desktop'
    }

    Test-Case 'LOCALAPPDATA must be an existing absolute directory and not a root' {
        $local = Join-Path $temp 'ValidLocal'
        $install = Join-Path $local 'Programs/DeskPilot'
        $data = Join-Path $local 'DeskPilot'
        $desktop = Join-Path $local 'Desktop'
        $script:fixtureDesktop = $desktop
        $shortcut = Join-Path $desktop 'DeskPilot.lnk'
        New-Item -ItemType Directory -Path $local, $install, $data, $desktop -Force | Out-Null
        Assert-Throws { Assert-UninstallRoots -LocalAppData '' -InstallRoot $install -DataRoot $data -ShortcutPath $shortcut } 'LOCALAPPDATA'
        Assert-Throws { Assert-UninstallRoots -LocalAppData 'relative' -InstallRoot $install -DataRoot $data -ShortcutPath $shortcut } 'LOCALAPPDATA|absolute'
        Assert-Throws { Assert-UninstallRoots -LocalAppData ([IO.Path]::GetPathRoot($local)) -InstallRoot $install -DataRoot $data -ShortcutPath $shortcut } 'LOCALAPPDATA|root'
        Assert-Throws { Assert-UninstallRoots -LocalAppData (Join-Path $temp 'missing') -InstallRoot $install -DataRoot $data -ShortcutPath $shortcut } 'LOCALAPPDATA|directory'
    }

    Test-Case 'path containment does not accept sibling prefixes or relative paths' {
        $root = Join-Path $temp 'containment/DeskPilot'
        Assert (Test-PathUnderRoot -Path (Join-Path $root 'DeskPilot.exe') -Root $root) 'Child path rejected.'
        Assert (Test-PathUnderRoot -Path (Join-Path $root 'server/file.js') -Root $root) 'Nested path rejected.'
        Assert (-not (Test-PathUnderRoot -Path ($root + '-other/DeskPilot.exe') -Root $root)) 'Sibling prefix accepted.'
        Assert (-not (Test-PathUnderRoot -Path 'DeskPilot/DeskPilot.exe' -Root $root)) 'Relative process path accepted.'
        Assert (-not (Test-PathUnderRoot -Path $root -Root $root)) 'Root itself must not be treated as a child executable path.'
    }

    Test-Case 'reparse points are rejected in roots and recursive deletion trees' {
        $local = Join-Path $temp 'ReparseLocal'
        $data = Join-Path $local 'DeskPilot'
        $install = Join-Path $local 'Programs/DeskPilot'
        $desktop = Join-Path $local 'Desktop'
        $script:fixtureDesktop = $desktop
        $shortcut = Join-Path $desktop 'DeskPilot.lnk'
        $outside = Join-Path $temp 'outside'
        New-Item -ItemType Directory -Path $local, $data, $install, $desktop, $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep'
        $junction = Join-Path $data 'linked'
        try {
            New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop | Out-Null
            Assert-Throws { Assert-NoReparseTree -Path $data } 'reparse|link'
            $linkedInstall = Join-Path $local 'Programs/LinkedDeskPilot'
            New-Item -ItemType Junction -Path $linkedInstall -Target $install -ErrorAction Stop | Out-Null
            Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $linkedInstall -DataRoot $data -ShortcutPath $shortcut } 'reparse|link|unexpected'
        } catch [Management.Automation.ItemNotFoundException] {
            Write-Host 'SKIP junction fixture unavailable'
        }
    }

    Test-Case 'OneDrive-redirected Desktop is accepted while links below it are rejected' {
        $local = Join-Path $temp 'OneDriveLocal'
        $install = Join-Path $local 'Programs/DeskPilot'
        $data = Join-Path $local 'DeskPilot'
        $syncRoot = Join-Path $temp 'onedrive-target'
        $redirectedDesktop = Join-Path $local 'OneDrive/Desktop'
        $shortcut = Join-Path $redirectedDesktop 'DeskPilot.lnk'
        New-Item -ItemType Directory -Path $local, $install, $data, $syncRoot -Force | Out-Null
        try {
            New-Item -ItemType Junction -Path (Join-Path $local 'OneDrive') -Target $syncRoot -ErrorAction Stop | Out-Null
        } catch [Management.Automation.ItemNotFoundException] {
            Write-Host 'SKIP OneDrive junction fixture unavailable'
            return
        }
        New-Item -ItemType Directory -Path $redirectedDesktop -Force | Out-Null
        Set-Content -LiteralPath $shortcut -Value 'fixture'
        $script:fixtureDesktop = $redirectedDesktop
        $paths = Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot $data -ShortcutPath $shortcut
        Assert ($paths.ShortcutPath -eq [IO.Path]::GetFullPath($shortcut)) 'OneDrive Desktop shortcut was rejected.'
        Assert ($paths.Desktop -eq [IO.Path]::GetFullPath($redirectedDesktop)) 'OneDrive Desktop was not resolved.'
        $linkedChild = Join-Path $redirectedDesktop 'linked'
        try {
            New-Item -ItemType Junction -Path $linkedChild -Target $syncRoot -ErrorAction Stop | Out-Null
            $nestedShortcut = Join-Path $linkedChild 'DeskPilot.lnk'
            Set-Content -LiteralPath $nestedShortcut -Value 'fixture'
            Assert-Throws { Assert-UninstallRoots -LocalAppData $local -InstallRoot $install -DataRoot $data -ShortcutPath $nestedShortcut } 'unexpected|Desktop'
            Assert-Throws { Assert-NoReparsePoint -Path $nestedShortcut -TrustedBase $redirectedDesktop } 'reparse|link'
        } catch [Management.Automation.ItemNotFoundException] {
            Write-Host 'SKIP nested junction fixture unavailable'
        }
    }

    Test-Case 'process filtering requires full path ownership and current session' {
        $install = Join-Path $temp 'processes/Programs/DeskPilot'
        $base = @{ SessionId = 3; OwnerSid = 'S-1-5-21-user'; Id = 100 }
        Assert (Test-ManagedProcess -Process ([pscustomobject]($base + @{ Path = (Join-Path $install 'DeskPilot.exe') })) -InstallRoot $install -CurrentUserSid 'S-1-5-21-user' -CurrentSessionId 3) 'Managed current-user process rejected.'
        Assert (-not (Test-ManagedProcess -Process ([pscustomobject]($base + @{ Path = 'D:\OtherApp\OtherApp.exe' })) -InstallRoot $install -CurrentUserSid 'S-1-5-21-user' -CurrentSessionId 3)) 'Unrelated process accepted.'
        Assert (-not (Test-ManagedProcess -Process ([pscustomobject]($base + @{ Path = ($install + '-other/DeskPilot.exe') })) -InstallRoot $install -CurrentUserSid 'S-1-5-21-user' -CurrentSessionId 3)) 'Sibling-prefix process accepted.'
        $otherSession = $base.Clone(); $otherSession.SessionId = 4; $otherSession.Path = Join-Path $install 'DeskPilot.exe'
        $otherUser = $base.Clone(); $otherUser.OwnerSid = 'S-1-5-21-other'; $otherUser.Path = Join-Path $install 'DeskPilot.exe'
        Assert (-not (Test-ManagedProcess -Process ([pscustomobject]$otherSession) -InstallRoot $install -CurrentUserSid 'S-1-5-21-user' -CurrentSessionId 3)) 'Other-session process accepted.'
        Assert (-not (Test-ManagedProcess -Process ([pscustomobject]$otherUser) -InstallRoot $install -CurrentUserSid 'S-1-5-21-user' -CurrentSessionId 3)) 'Other-user process accepted.'
        Assert (-not (Test-ManagedProcess -Process ([pscustomobject]($base + @{ Path = '' })) -InstallRoot $install -CurrentUserSid 'S-1-5-21-user' -CurrentSessionId 3)) 'Process without a full executable path accepted.'
    }

    Test-Case 'recursive removal requires an explicit typed confirmation' {
        Assert (Test-RemovalConfirmation -Answer 'REMOVE DESKPILOT' -ExpectedPhrase 'REMOVE DESKPILOT') 'Correct confirmation rejected.'
        Assert (-not (Test-RemovalConfirmation -Answer 'yes' -ExpectedPhrase 'REMOVE DESKPILOT')) 'Generic yes accepted.'
        Assert (-not (Test-RemovalConfirmation -Answer '' -ExpectedPhrase 'REMOVE DESKPILOT')) 'Empty confirmation accepted.'
        Assert (-not (Test-RemovalConfirmation -Answer $null -ExpectedPhrase 'REMOVE DESKPILOT')) 'Missing confirmation accepted.'
    }

    Test-Case 'only the HKCU DeskPilot Run value is removed' {
        $script:removedPath = ''
        $script:removedName = ''
        function Get-ItemProperty { param($LiteralPath, $Name, $ErrorAction) return [pscustomobject]@{ DeskPilot = 'fixture' } }
        function Remove-ItemProperty { param($LiteralPath, $Name, $ErrorAction) $script:removedPath = $LiteralPath; $script:removedName = $Name }
        Remove-HkcURunValue
        Assert ($script:removedPath -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') 'Wrong registry key touched.'
        Assert ($script:removedName -eq 'DeskPilot') 'Wrong registry value removed.'
    }

    Test-Case 'termination wait tolerates a process that exits before attachment' {
        $record = [pscustomobject]@{ Id = 4242; Path = 'C:\fixture\DeskPilot.exe'; CreationDate = [datetime]'2026-01-01T00:00:00Z' }
        function Stop-Process { param($Id, [switch]$Force, $ErrorAction) }
        function Wait-Process { param($Id, $Timeout, $ErrorAction) throw [Management.Automation.ItemNotFoundException]::new('Already exited') }
        function Get-CimInstance { param($Filter, $ErrorAction) return $null }
        Wait-ManagedProcessExit -Processes @($record) -TimeoutSeconds 1
        Assert $true 'The already-exited process was accepted.'
    }

    Test-Case 'termination does not stop a reused PID' {
        $record = [pscustomobject]@{ Id = 4243; Path = 'C:\fixture\DeskPilot.exe'; SessionId = 3; CreationDate = [datetime]'2026-01-01T00:00:00Z' }
        $script:stopCalls = 0
        function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stopCalls++ }
        function Get-CimInstance { param($Filter, $ErrorAction) return [pscustomobject]@{ ProcessId = 4243; ExecutablePath = 'C:\other\other.exe'; SessionId = 3; CreationDate = [datetime]'2026-01-02T00:00:00Z' } }
        Wait-ManagedProcessExit -Processes @($record) -TimeoutSeconds 1
        Assert ($script:stopCalls -eq 0) 'A reused PID was stopped.'
    }

    Test-Case 'backup cleanup recognizes only exact installer backup leaves' {
        $install = Join-Path $temp 'backups/Programs/DeskPilot'
        New-Item -ItemType Directory -Path $install -Force | Out-Null
        $valid = Join-Path (Split-Path $install -Parent) 'DeskPilot.backup-20261125-120000'
        $unexpected = Join-Path (Split-Path $install -Parent) 'DeskPilot.backup-not-a-timestamp'
        $other = Join-Path (Split-Path $install -Parent) 'Other.backup-20261125-120000'
        New-Item -ItemType Directory -Path $valid, $unexpected, $other -Force | Out-Null
        $backups = @(Get-DeskPilotBackupRoots -InstallRoot $install)
        Assert ($backups.Count -eq 1 -and $backups[0] -eq [IO.Path]::GetFullPath($valid)) 'Backup discovery included an unexpected path.'
    }

    Test-Case 'safe cleanup removes read-only managed files' {
        $readOnly = Join-Path $temp 'read-only.txt'
        Set-Content -LiteralPath $readOnly -Value 'fixture'
        Set-ItemProperty -LiteralPath $readOnly -Name IsReadOnly -Value $true
        Remove-SafePath $readOnly
        Assert (-not (Test-Path -LiteralPath $readOnly)) 'Read-only managed file was not removed.'
    }

    Test-Case 'missing LOCALAPPDATA fails validation before any uninstall work' {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $PSHOME 'powershell.exe'
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $uninstallerPath + '"'
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables.Remove('LOCALAPPDATA')
        $process = [Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Assert ($process.ExitCode -ne 0 -and $output -match 'LOCALAPPDATA') "Missing LOCALAPPDATA was not rejected explicitly: $output"
    }

    Test-Case 'uninstaller never removes user data without explicit request' {
        Assert ($source -match '\[switch\]\$RemoveUserData') 'RemoveUserData opt-in is missing.'
        Assert ($source -match 'Remove-HkcURunValue') 'HKCU Run cleanup is missing.'
        Assert ($source -match 'Wait-Process') 'Process termination is not awaited.'
        Assert ($source -match 'CreationDate') 'Termination verification does not guard against PID reuse.'
        Assert ($source -match 'Test-ManagedProcess') 'Process name-only stopping remains.'
        Assert ($source -notmatch 'Get-Process\s+-Name\s+''DeskPilot''') 'Uninstaller still stops processes by name.'
        Assert ($source -match 'same (?:GitHub )?release account|release-account') 'Script must document the same-release-account trust limitation.'
    }
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures.Count -gt 0) {
    Write-Host ('FAILED ' + $script:failures.Count + ' uninstaller security checks:')
    foreach ($failure in $script:failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host "PASS DeskPilot uninstaller security: $script:checks checks"
