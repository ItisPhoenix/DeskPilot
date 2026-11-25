[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\DeskPilot'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'DeskPilot'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeskPilot.lnk'),
    [switch]$RemoveUserData
)

$ErrorActionPreference = 'Stop'

# Trust boundary: this script and the installed executable share a publisher
# trust domain. Path, registry, and process checks reduce accidental damage, but
# a compromised same GitHub release account or same-user attacker can still race local
# state. These checks are not a guarantee against a compromised release account.

function Get-CanonicalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A path is required.' }
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -match '\A[A-Za-z]:[^\\/]') { throw "An absolute fully qualified path is required: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\')
}

function Get-DeskPilotDesktop {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'The Desktop known folder is unavailable.' }
    return Get-CanonicalPath $desktop
}

function Assert-NoReparsePoint([string]$Path, [string]$TrustedBase) {
    $current = Get-CanonicalPath $Path
    $trusted = $null
    if (-not [string]::IsNullOrWhiteSpace($TrustedBase)) { $trusted = Get-CanonicalPath $TrustedBase }
    while ($true) {
        # OneDrive Known Folder Move marks the Desktop folder and its sync root
        # as reparse points. Stop at the resolved known folder so those trusted
        # ancestors are accepted, while the shortcut itself and anything between
        # it and Desktop remain subject to the full reparse-point check.
        if ($null -ne $trusted -and $current -ieq $trusted) { break }
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
        if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { [IO.Directory]::Delete($item.FullName, $false) }
        else { [IO.File]::Delete($item.FullName) }
        return
    }
    if (($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
        foreach ($child in (Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) { Remove-SafePath $child.FullName }
        [IO.Directory]::Delete($item.FullName, $false)
    } else {
        [IO.File]::Delete($item.FullName)
    }
}

function Assert-UninstallRoots([string]$LocalAppData, [string]$InstallRoot, [string]$DataRoot, [string]$ShortcutPath) {
    if ([string]::IsNullOrWhiteSpace($LocalAppData)) { throw 'LOCALAPPDATA is unavailable.' }
    $local = Get-CanonicalPath $LocalAppData
    if ($local -eq [IO.Path]::GetPathRoot($local)) { throw 'LOCALAPPDATA cannot be a drive or filesystem root.' }
    if (-not (Test-Path -LiteralPath $local -PathType Container)) { throw 'LOCALAPPDATA must name an existing directory.' }
    Assert-NoReparsePoint $local
    $expectedInstall = Get-CanonicalPath (Join-Path $local 'Programs\DeskPilot')
    $expectedData = Get-CanonicalPath (Join-Path $local 'DeskPilot')
    $install = Get-CanonicalPath $InstallRoot
    $data = Get-CanonicalPath $DataRoot
    $shortcut = Get-CanonicalPath $ShortcutPath
    if ($install -ieq $data) { throw 'Install and data roots must be distinct.' }
    if ($install -ine $expectedInstall) { throw "Unexpected install root. Expected '$expectedInstall'." }
    if ($data -ine $expectedData) { throw "Unexpected data root. Expected '$expectedData'." }
    $desktop = Get-DeskPilotDesktop
    $shortcutParent = Split-Path -Parent $shortcut
    if ((Split-Path -Leaf $shortcut) -ine 'DeskPilot.lnk' -or $shortcutParent -ine $desktop) { throw 'Unexpected shortcut path; expected Desktop\DeskPilot.lnk.' }
    Assert-NoReparsePoint $install
    Assert-NoReparsePoint $data
    Assert-NoReparsePoint $shortcut -TrustedBase $desktop
    return [pscustomobject]@{
        LocalAppData = $local
        InstallRoot = $install
        DataRoot = $data
        ShortcutPath = $shortcut
        Desktop = $desktop
    }
}

function Test-PathUnderRoot([string]$Path, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $candidate = Get-CanonicalPath $Path
        $canonicalRoot = Get-CanonicalPath $Root
    } catch { return $false }
    return ($candidate.StartsWith($canonicalRoot + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Test-ManagedProcess($Process, [string]$InstallRoot, [string]$CurrentUserSid, [int]$CurrentSessionId) {
    if ($null -eq $Process -or [string]::IsNullOrWhiteSpace([string]$CurrentUserSid)) { return $false }
    if ([string]$Process.OwnerSid -cne [string]$CurrentUserSid) { return $false }
    if ($null -eq $Process.SessionId -or [int]$Process.SessionId -ne $CurrentSessionId) { return $false }
    return (Test-PathUnderRoot ([string]$Process.Path) $InstallRoot)
}

function Get-InstallProcesses([string]$InstallRoot) {
    $records = @()
    foreach ($process in (Get-CimInstance Win32_Process)) {
        if (-not (Test-PathUnderRoot ([string]$process.ExecutablePath) $InstallRoot)) { continue }
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
        $records += [pscustomobject]@{
            Id = [int]$process.ProcessId
            Path = [string]$process.ExecutablePath
            SessionId = [int]$process.SessionId
            OwnerSid = [string]$owner.Sid
            CreationDate = [datetime]$process.CreationDate
        }
    }
    return $records
}

function Wait-ManagedProcessExit($Processes, [int]$TimeoutSeconds = 10) {
    foreach ($record in $Processes) {
        $before = Get-CimInstance Win32_Process -Filter "ProcessId=$($record.Id)" -ErrorAction SilentlyContinue
        if ($null -eq $before) { continue }
        $sameBefore = try {
            [datetime]$before.CreationDate -eq [datetime]$record.CreationDate -and
            [string]$before.ExecutablePath -ieq [string]$record.Path -and
            [int]$before.SessionId -eq [int]$record.SessionId
        } catch { $false }
        if (-not $sameBefore) { continue } # The original exited and its PID was reused.
        Stop-Process -Id $record.Id -Force -ErrorAction Stop
        # The process may exit between Stop-Process and Wait-Process. Verification
        # below, not attachment success, decides whether termination completed.
        try {
            Wait-Process -Id $record.Id -Timeout $TimeoutSeconds -ErrorAction Stop
        } catch {
            $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($record.Id)" -ErrorAction SilentlyContinue
            if ($null -eq $current) { continue }
            if ($_.Exception -isnot [System.TimeoutException]) { throw }
        }
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($record.Id)" -ErrorAction SilentlyContinue
        if ($null -ne $current) {
            $sameCreation = try { [datetime]$current.CreationDate -eq [datetime]$record.CreationDate } catch { $true }
            if ($sameCreation) { throw "Managed process $($record.Id) did not terminate; uninstall canceled before deletion." }
        }
    }
}

function Test-RemovalConfirmation($Answer, [string]$ExpectedPhrase) {
    return ($null -ne $Answer -and $Answer.Trim() -ceq $ExpectedPhrase)
}

function Remove-HkcURunValue {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $name = 'DeskPilot'
    $existing = Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue
    if ($null -ne $existing) { Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop }
}

function Get-DeskPilotBackupRoots([string]$InstallRoot) {
    $install = Get-CanonicalPath $InstallRoot
    if ((Split-Path -Leaf $install) -ine 'DeskPilot') { throw 'Unexpected install root leaf.' }
    $parent = Split-Path -Parent $install
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return @() }
    $backups = @()
    foreach ($item in (Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop)) {
        if ($item.Name -cmatch '\ADeskPilot\.backup-[0-9]{8}-[0-9]{6}\z') {
            $canonical = Get-CanonicalPath $item.FullName
            Assert-NoReparsePoint $canonical
            $backups += $canonical
        }
    }
    return $backups
}

function Invoke-Uninstaller {
    param(
        [string]$InstallRoot,
        [string]$DataRoot,
        [string]$ShortcutPath,
        [switch]$RemoveUserData
    )
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable. Run this uninstaller from a normal Windows user session.' }
    $paths = Assert-UninstallRoots -LocalAppData $env:LOCALAPPDATA -InstallRoot $InstallRoot -DataRoot $DataRoot -ShortcutPath $ShortcutPath
    $install = $paths.InstallRoot
    $data = $paths.DataRoot
    $shortcut = $paths.ShortcutPath
    $backups = @(Get-DeskPilotBackupRoots $install)

    # Validate every recursive target before confirmation, process termination,
    # registry cleanup, or deletion. User data is not even traversed unless asked.
    $recursiveTargets = @()
    if (Test-Path -LiteralPath $install) { $recursiveTargets += $install }
    $recursiveTargets += $backups
    if ($RemoveUserData -and (Test-Path -LiteralPath $data)) { $recursiveTargets += $data }
    foreach ($target in $recursiveTargets) { Assert-NoReparseTree $target }
    if (Test-Path -LiteralPath $shortcut) { Assert-NoReparsePoint $shortcut -TrustedBase $paths.Desktop }

    if ($recursiveTargets.Count -gt 0) {
        Write-Host 'The following DeskPilot folders will be recursively deleted:' -ForegroundColor Yellow
        foreach ($target in $recursiveTargets) { Write-Host "  $target" }
        if ($RemoveUserData) { Write-Host 'This includes local settings and the DPAPI-protected runtime key.' -ForegroundColor Yellow }
        $answer = Read-Host 'Type REMOVE DESKPILOT to confirm recursive deletion'
        if (-not (Test-RemovalConfirmation $answer 'REMOVE DESKPILOT')) { throw 'Uninstall canceled; no files, processes, or registry values were changed.' }
    }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $currentSessionId = (Get-Process -Id $PID).SessionId
    $installProcesses = @(Get-InstallProcesses $install)
    $managed = @($installProcesses | Where-Object { Test-ManagedProcess -Process $_ -InstallRoot $install -CurrentUserSid $currentSid -CurrentSessionId $currentSessionId })
    $unmanaged = @($installProcesses | Where-Object { -not (Test-ManagedProcess -Process $_ -InstallRoot $install -CurrentUserSid $currentSid -CurrentSessionId $currentSessionId) })
    if ($unmanaged.Count -gt 0) { throw 'A DeskPilot executable is running in another user or session. Sign in there and close it before uninstalling.' }

    Remove-HkcURunValue
    if ($managed.Count -gt 0) {
        Write-Host 'Stopping only verified DeskPilot processes in this user session...'
        Wait-ManagedProcessExit $managed
    }
    if (Test-Path -LiteralPath $shortcut) { Remove-SafePath $shortcut }
    foreach ($target in $recursiveTargets) {
        # Recheck immediately before deletion; Remove-SafePath also removes a
        # newly appeared link itself rather than traversing its target.
        Assert-NoReparseTree $target
        Remove-SafePath $target
    }

    if ($RemoveUserData) {
        Write-Host 'DeskPilot and its local data, including the DPAPI key, were removed.' -ForegroundColor Yellow
    } else {
        Write-Host 'DeskPilot application files and installer backups were removed. Local data and the DPAPI-protected key were preserved.' -ForegroundColor Green
        Write-Host 'To remove them too, rerun with -RemoveUserData.'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Uninstaller -InstallRoot $InstallRoot -DataRoot $DataRoot -ShortcutPath $ShortcutPath -RemoveUserData:$RemoveUserData
}
