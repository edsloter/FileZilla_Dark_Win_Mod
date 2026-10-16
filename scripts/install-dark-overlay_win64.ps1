<#
.SYNOPSIS
    Applies, or removes, the FileZilla system light/dark overlay.

.DESCRIPTION
    Drop-in replacement for the modified FileZilla binaries, the wxWidgets runtime
    they were linked against, and the extra light-appearance icons. Anything not
    listed in overlay-manifest.txt is left untouched, so a normal FileZilla
    installation stays otherwise intact.

    Installing is reversible. Every file that is overwritten is copied to
    <InstallDir>\fzdark-backup\<timestamp>\ first, and files that are newly added
    are recorded as such, so -Uninstall can restore the installation exactly.

    Extracting the 7z archive over a FileZilla installation also works and needs no
    script, but that route cannot be undone by this script, so prefer it.

    The FileZilla version this overlay was built for comes from versions.ps1, which
    ships inside the same 7z archive. Nothing is hardcoded here, so a new release is
    a one-file change plus a rebuild.

  Runs under Windows PowerShell 5.1, which is what Windows ships, because the
  machine receiving the overlay may have nothing else installed - this is a
  file-copy operation and has no reason to demand a newer shell.

.PARAMETER InstallDir
    FileZilla installation directory. Autodetected when omitted.

.PARAMETER Uninstall
    Remove the overlay and restore the installation. Restores from the OLDEST backup
    this script made - that one holds the genuine originals - then removes every backup
    it finds, so a directory installed more than once still comes back clean.

.PARAMETER Force
    Close a running FileZilla without asking, and continue on version mismatch
    warnings.

.PARAMETER ForceOverAlreadyInstalled
    Install even though an overlay is already present in the target directory.

    The normal behaviour is to refuse, and the reason is worth stating: a second
    install backs up the already-overlaid files as if they were the originals. This
    is now recoverable rather than dangerous, because -Uninstall restores from the
    OLDEST backup, which still holds the genuine stock files, and clears them all
    afterwards. The flag exists for repairing a tree left in a confusing state. It
    adds a second backup rather than replacing the first, and prints what it found.

.PARAMETER NoVersionCheck
    Skip the FileZilla version check. Only for testing against a mock install.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1 -InstallDir 'C:\Program Files\FileZilla'

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1 -Uninstall

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1 -ForceOverAlreadyInstalled
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDir,
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$ForceOverAlreadyInstalled,
    [switch]$NoVersionCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BackupDirName = 'fzdark-backup'
$ManifestName = 'overlay-manifest.txt'

$script:OverlayRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# versions.ps1 ships inside the same 7z, next to this script. In the repo it sits one
# directory up, because the scripts live in scripts\. Both layouts are accepted.
$versionsCandidates = @(
    (Join-Path $script:OverlayRoot 'versions.ps1')                          # released archive
    (Join-Path (Split-Path -Parent $script:OverlayRoot) 'versions.ps1')    # repo checkout
)
$versionsFile = $versionsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $versionsFile) {
    throw @"
versions.ps1 was not found next to this script.

Expected it in either location:
  $script:OverlayRoot\versions.ps1
  $(Split-Path -Parent $script:OverlayRoot)\versions.ps1

It ships inside the 7z archive alongside this script and records which FileZilla
version the overlay was built for. Without it this script cannot tell whether the
overlay matches the installed FileZilla, and guessing would risk writing wxWidgets
binaries of the wrong ABI over a working install.
"@
}
. $versionsFile
$ExpectedVersion = $FzVersion

function Write-Step { param([string]$m) Write-Host "  [overlay] $m" }
function Write-Warn2 { param([string]$m) Write-Host "  [overlay] $m" -ForegroundColor Yellow }
function Write-Err2 { param([string]$m) Write-Host "  [overlay] $m" -ForegroundColor Red }

function Get-CandidateInstallDirs {
    $c = [System.Collections.Generic.List[string]]::new()

    # The registry is the only source that knows about a non-default install location, but
    # it is matched on "FileZilla*" rather than on one exact key name: the key embeds
    # whatever version was installed, which need not be the version this overlay targets.
    foreach ($root in @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        )) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like 'FileZilla*' })) {
            $p = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).InstallLocation
            if ($p) { $c.Add($p) }
        }
    }

    # The official Windows build installs to "FileZilla FTP Client", not to "FileZilla",
    # and the Microsoft Store build lives under %LOCALAPPDATA%\Programs as "FileZilla 3".
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        foreach ($leaf in @('FileZilla FTP Client', 'FileZilla FTP', 'FileZilla', 'FileZilla 3')) {
            $c.Add((Join-Path $base $leaf))
            $c.Add((Join-Path $base "Programs\$leaf"))
        }
    }

    # Last resort: anything under those roots whose name starts with FileZilla and which
    # actually holds the executable, so no particular folder name is load-bearing.
    # FileZilla Server shows up here too and is filtered out by the filezilla.exe probe.
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))) {
        if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'FileZilla*' })) {
            $c.Add($d.FullName)
        }
    }

    return $c
}

# Two layouts exist and both are real. The Windows installer and the released
# overlay are flat: the executable sits directly in the install root, next to its
# DLLs. Only the build tree under C:\fzdark\install follows the autotools prefix and
# puts the executable in bin\ beside share\locale\. A .7z of the official ZIP is flat
# too. So accept either rather than insisting on the one this kit happens to produce.
function Get-FileZillaExePath {
    param([string]$Dir)
    foreach ($rel in @('filezilla.exe', 'bin\filezilla.exe')) {
        $p = Join-Path $Dir $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Resolve-InstallDir {
    if ($InstallDir) {
        if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
            throw "install directory not found: $InstallDir"
        }
        $explicit = (Resolve-Path -LiteralPath $InstallDir).Path
        if (-not (Get-FileZillaExePath -Dir $explicit)) {
            # Naming the file rather than the bin\ subdirectory: a Windows install is
            # flat, so telling someone to look for bin\ sends them hunting for a
            # directory their install has never had.
            throw "no filezilla.exe in $explicit, nor in a bin\ subdirectory there. " +
                  "Point -InstallDir at the FileZilla install folder itself - the one " +
                  "containing filezilla.exe."
        }
        return $explicit
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in (Get-CandidateInstallDirs)) {
        if (-not $c) { continue }
        if ((Get-FileZillaExePath -Dir $c) -and $seen.Add($c)) { return (Resolve-Path -LiteralPath $c).Path }
    }

    # The probed locations are echoed back: "no FileZilla installation found" on its own
    # is unactionable when the real problem is that the install sits somewhere unlisted.
    $probed = @(Get-CandidateInstallDirs | Where-Object { $_ } | Select-Object -Unique)
    throw ("no FileZilla installation found. Looked for filezilla.exe under: " +
        $(if ($probed.Count) { $probed -join '; ' } else { '(no candidate locations)' }) +
        " - pass -InstallDir explicitly.")
}

function Assert-TargetVersion {
    param([string]$Dir)

    $exe = Get-FileZillaExePath -Dir $Dir
    if (-not $exe) {
        throw "filezilla.exe not found under $Dir. This does not look like a FileZilla installation."
    }

    $fv = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
    if (-not $fv) {
        if ($NoVersionCheck) { Write-Warn2 "no version resource on filezilla.exe, continuing"; return }
        throw "cannot read the version of filezilla.exe in $Dir"
    }

    # FileVersion comes back comma-and-space separated ("3, 71, 1, 0"). Normalise once
    # and use the normalised form for display too, so the message reads 3.71.1.0 rather
    # than leaking the raw separator.
    $norm = $fv -replace '[, ]+', '.'
    if ($norm -notlike "$ExpectedVersion.*" -and $norm -ne $ExpectedVersion) {
        $msg = "target is FileZilla $norm, but this overlay is built for $ExpectedVersion. Version mismatches are not supported."
        if ($Force) { Write-Warn2 "$msg Continuing because -Force was given."; return }
        throw "$msg Use -Force to override, or -NoVersionCheck for a mock install."
    }
    Write-Step "target is FileZilla $norm (overlay built for $ExpectedVersion)"
}

function Stop-FileZilla {
    param([string]$Dir)

    # Only FileZilla processes running *out of the target directory* hold locks on
    # the files we are about to overwrite. Matching on process name alone was both
    # too strict and too destructive: it refused to install into a scratch copy
    # while an unrelated FileZilla was open, and -Force would then close that
    # unrelated window - including a live transfer - to fix a problem it did not
    # have.
    $target = $null
    if ($Dir) {
        try { $target = (Resolve-Path -LiteralPath $Dir -ErrorAction Stop).Path.TrimEnd('\') } catch { $target = $null }
    }

    $procs = @(Get-Process -Name 'FileZilla' -ErrorAction SilentlyContinue | Where-Object {
        if (-not $target) { return $false }
        try { $_.Path -and $_.Path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }   # no Path means we cannot prove it is ours, so ignore it
    })
    if ($procs.Count -eq 0) { return }
    $names = ($procs | ForEach-Object { "$($_.Id)" }) -join ', '
    Write-Warn2 "FileZilla is running from $target (pid $names). It holds file locks and must be closed."
    if (-not $Force) {
        throw "close FileZilla and re-run, or pass -Force to close it automatically."
    }
    $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    Start-Sleep -Seconds 2
    $left = @(Get-Process -Name 'FileZilla' -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        Write-Warn2 "FileZilla did not close gracefully, terminating."
        $left | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
    Write-Step "closed running FileZilla"
}

function Read-OverlayManifest {
    $path = Join-Path $script:OverlayRoot $ManifestName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "overlay-manifest.txt not found next to this script ($script:OverlayRoot)."
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        $m = [regex]::Match($line, '^([0-9a-f]{64})\s\s(.+)$')
        if (-not $m.Success) { throw "malformed manifest line: $line" }
        $entries.Add([pscustomobject]@{
            Hash = $m.Groups[1].Value
            Rel  = $m.Groups[2].Value.Trim().Replace('/', '\')
        })
    }
    if ($entries.Count -eq 0) { throw 'overlay-manifest.txt contains no payload files.' }
    return $entries
}

function Assert-OverlayIntact {
    param($Entries)
    $bad = 0
    foreach ($e in $Entries) {
        $p = Join-Path $script:OverlayRoot $e.Rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-Err2 "missing from package: $($e.Rel)"; $bad++
            continue
        }
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ne $e.Hash) { Write-Err2 "corrupt in package: $($e.Rel)"; $bad++ }
    }
    if ($bad -gt 0) { throw "overlay package is incomplete or modified ($bad problem(s)). Re-extract the archive." }
    Write-Step "payload verified against manifest ($($Entries.Count) files)"
}

function Assert-DirectoryWritable {
    param([string]$Dir)

    # Probed by creating and removing a real file rather than by inspecting the ACL:
    # UAC filtered tokens, per-user overrides and inherited deny ACEs all make an
    # access check unreliable, and this is the exact condition that produces the bare
    # "Access to the path ... is denied" from New-Item further down with no hint that
    # elevation is the fix.
    $probe = Join-Path $Dir ".fzdark-write-probe-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    try {
        Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
    }
    catch {
        $msg = "cannot write to $Dir : $($_.Exception.Message)"
        if ($Dir -like "$env:ProgramFiles*") {
            $msg += "`nThat is a Program Files location, which needs an elevated shell. Re-run as Administrator,"
            $msg += "`nor pass -InstallDir pointing at a writable copy of FileZilla."
        }
        throw $msg
    }
    finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ state detection
#
# The overlay is a single layer, and this is the function that decides whether one is
# already there. Three independent signals, because each covers a case the others miss:
#
#   1. a backup directory  - what our own install leaves behind
#   2. the Add/Remove key  - what the .exe installer registers
#   3. a payload file whose hash already matches ours - proof the overlay is applied even
#      if both of the above were deleted by hand or lost to a partial uninstall
#
# Signal 3 is the one that matters most, and it is why this is not just a file check: a
# single missing marker file would otherwise let a second install run, and a second
# install backs up the ALREADY-OVERLAID files as though they were the originals. That
# silently corrupts the undo chain - the uninstaller then restores the overlay over
# itself, the true originals are orphaned in an older backup nobody points at, and the
# removal entry in Add/Remove Programs is deleted anyway. The user is left with dark
# mode they cannot remove.
$script:ArpKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\FileZillaDarkOverlay'

# Both installers' markers are recognised. They use different names for the same thing -
# this kit writes backup-manifest.txt, the NSIS installer writes installed.txt - and a
# tree can hold both if a user tried one, then the other. Treating an unfamiliar marker
# as "no backup" is how a real backup gets ignored and the originals get lost.
function Get-OverlayBackups {
    param([string]$Dir)

    $root = Join-Path $Dir $BackupDirName
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $found = @()
    foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'backup-manifest.txt') -PathType Leaf) {
            $found += [pscustomobject]@{ Dir = $d; Kind = 'ps1' }
        }
        elseif (Test-Path -LiteralPath (Join-Path $d.FullName 'installed.txt') -PathType Leaf) {
            $found += [pscustomobject]@{ Dir = $d; Kind = 'nsis' }
        }
    }

    # Oldest first, by creation time. Sorting by NAME is wrong the moment the two
    # conventions meet: 'backup-0000' sorts above '20261016-044853' because 'b' is a
    # later byte than '2', so name order picked the newer install as the older one.
    return @($found | Sort-Object { $_.Dir.CreationTimeUtc })
}

function Test-ArpEntryPresent {
    try { return (Test-Path -LiteralPath $script:ArpKey) } catch { return $false }
}

function Test-OverlayApplied {
    param([string]$Dir, $Entries)

    $backups = @(Get-OverlayBackups -Dir $Dir)
    if ($backups.Count -gt 0) {
        return [pscustomobject]@{
            Installed = $true
            Why = "a backup from a previous install is present ($($backups[0].Dir.Name))"
            Fix = 'remove the overlay first, then install again'
        }
    }

    if (Test-ArpEntryPresent) {
        return [pscustomobject]@{
            Installed = $true
            Why = 'the overlay is still registered in Add/Remove Programs'
            Fix = 'uninstall FileZilla ... light/dark overlay from Add/Remove Programs, then install again'
        }
    }

    # No backup and no registry entry, but the files themselves may still be ours.
    if ($Entries) {
        foreach ($e in $Entries) {
            $dst = Join-Path $Dir $e.Rel
            if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { continue }
            try {
                $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            catch { continue }
            if ($h -eq $e.Hash.ToLowerInvariant()) {
                return [pscustomobject]@{
                    Installed = $true
                    Why = "the overlay's own file is already in place ($($e.Rel)), but its backup and its Add/Remove entry are both missing"
                    Fix = 'that is a leftover from an interrupted removal. Reinstall FileZilla from the official package to get a clean copy, then install the overlay again'
                }
            }
        }
    }

    return [pscustomobject]@{ Installed = $false; Why = $null; Fix = $null }
}

function Assert-OverlayNotInstalled {
    param([string]$Dir, $Entries, [switch]$Force)

    $state = Test-OverlayApplied -Dir $Dir -Entries $Entries
    if (-not $state.Installed) { return }

    if ($Force) {
        Write-Warn2 "installing over an existing overlay ($($state.Why))."
        Write-Warn2 "The existing backup is kept, and -Uninstall restores from the OLDEST backup,"
        Write-Warn2 "which holds the genuine stock files, then removes every backup. So this is"
        Write-Warn2 "recoverable - but run -Uninstall rather than deleting the backup folder, or the"
        Write-Warn2 "originals go with it."
        return
    }

    $msg = @(
        "The dark overlay is already installed in:"
        "  $Dir"
        ""
        "Detected because $state.Why."
        ""
        "Installing a second time would back up the already-overlaid files as if they"
        "were the originals, which breaks removal: the uninstaller would restore the"
        "overlay over itself and delete the only entry in Add/Remove Programs."
        ""
        "Nothing has been changed."
        ""
        "What to do: $($state.Fix)."
        "If you are deliberately repairing this directory, -ForceOverAlreadyInstalled"
        "installs anyway. It stays recoverable, because -Uninstall restores from the"
        "oldest backup rather than the newest."
    ) -join "`n"
    throw $msg
}

function Invoke-Install {
    param([string]$Dir, $Entries)

    $backupRoot = Join-Path $Dir $BackupDirName
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path $backupRoot $stamp

    # The timestamp is only accurate to a second, and two installs inside the same second
    # - which is exactly what -ForceOverAlreadyInstalled followed by a retry looks like -
    # would otherwise land in the same directory. New-Item -Force treats an existing
    # directory as success, so the run would silently reuse it and overwrite the STOCK
    # originals saved there with the overlay's own files. That is precisely the corruption
    # the already-installed guard exists to prevent, reintroduced through the override.
    # The marker file marks a name as taken, so a half-written directory does not.
    $suffix = 0
    while (Test-Path -LiteralPath (Join-Path $backup 'backup-manifest.txt')) {
        $suffix++
        $backup = Join-Path $backupRoot ("{0}-{1}" -f $stamp, $suffix)
    }
    New-Item -ItemType Directory -Force -Path $backup | Out-Null

    $log = [System.Collections.Generic.List[string]]::new()
    $log.Add("# fzdark dark overlay backup manifest")
    # Note the doubled parens: $(Get-Date) closes the subexpression at the first
    # ')', so anything after it would be emitted as literal text rather than called.
    $log.Add("# created  $((Get-Date).ToUniversalTime().ToString('u'))")
    $log.Add("# install  $Dir")
    $log.Add('# "replaced" = the original was saved in this backup and can be restored.')
    $log.Add('# "added"    = the overlay created it; uninstall deletes it.')

    $nReplace = 0; $nAdd = 0

    foreach ($e in $Entries) {
        $src = Join-Path $script:OverlayRoot $e.Rel
        $dst = Join-Path $Dir $e.Rel

        if (Test-Path -LiteralPath $dst -PathType Leaf) {
            $save = Join-Path $backup $e.Rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $save) | Out-Null
            Copy-Item -LiteralPath $dst -Destination $save -Force
            $log.Add("replaced $($e.Rel.Replace('\', '/'))")
            $nReplace++
        }
        else {
            $log.Add("added $($e.Rel.Replace('\', '/'))")
            $nAdd++
        }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force

        $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ne $e.Hash) { throw "copy verification failed for $($e.Rel)" }
    }

    [System.IO.File]::WriteAllLines((Join-Path $backup 'backup-manifest.txt'), $log)

    Write-Step "installed $($Entries.Count) files ($nReplace replaced, $nAdd added)"
    Write-Step "backup written to $backup"
}

function Invoke-Uninstall {
    param([string]$Dir, $Entries)

    $backupRoot = Join-Path $Dir $BackupDirName
    $backups = @(Get-OverlayBackups -Dir $Dir)

    # No backup is NOT the same as "no overlay". Saying "nothing to uninstall" here is how
    # a user ends up with dark mode they cannot get rid of and no tool that admits it
    # exists. Report what is actually on disk instead.
    if ($backups.Count -eq 0) {
        $left = @(Get-LeftoverOverlayFiles -Dir $Dir)
        $lines = @(
            "No overlay backup was found under $backupRoot, so no original file can be restored."
        )
        if ($left.Count -gt 0) {
            $lines += ""
            $lines += "These overlay files are still in place:"
            foreach ($f in ($left | Select-Object -First 12)) { $lines += "  $($f.Rel)" }
            if ($left.Count -gt 12) { $lines += "  ... and $($left.Count - 12) more" }
            $lines += ""
            $lines += "The originals they replaced were deleted, so this cannot be undone"
            $lines += "from here. Reinstall FileZilla from the official package, then run"
            $lines += "this installer again to apply the overlay."
        }
        else {
            $lines += ""
            $lines += "No overlay files were found either, so nothing is applied here."
        }
        throw ($lines -join "`n")
    }

    # The OLDEST backup holds the true originals. Only consuming the newest is what breaks
    # a tree that was installed twice: the newest backup then contains the overlay itself,
    # restoring it changes nothing, and the real originals stay buried in the older
    # directory. Restoring from the oldest repairs that case instead of compounding it.
    $oldest = $backups[0]

    $nRestore = 0; $nDelete = 0

    if ($oldest.Kind -eq 'ps1') {
        $logPath = Join-Path $oldest.Dir.FullName 'backup-manifest.txt'
        foreach ($line in [System.IO.File]::ReadAllLines($logPath)) {
            if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
            $m = [regex]::Match($line, '^(replaced|added)\s+(.+)$')
            if (-not $m.Success) { throw "malformed backup manifest line: $line" }
            $action = $m.Groups[1].Value
            $rel = $m.Groups[2].Value.Trim().Replace('/', '\')
            $dst = Join-Path $Dir $rel

            if ($action -eq 'replaced') {
                $save = Join-Path $oldest.Dir.FullName $rel
                if (-not (Test-Path -LiteralPath $save -PathType Leaf)) {
                    Write-Warn2 "backup copy missing, leaving $rel alone: $save"
                    continue
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $save -Destination $dst -Force
                $nRestore++
            }
            else {
                if (Test-Path -LiteralPath $dst -PathType Leaf) {
                    Remove-Item -LiteralPath $dst -Force
                    $nDelete++
                }
            }
        }
    }
    else {
        # A backup made by the .exe installer. It records no per-file list; the directory
        # itself IS the list, so restore everything in it and delete every manifest entry
        # that is not. Without this branch, removing an .exe overlay with this script threw
        # "incomplete (no backup-manifest.txt)" and did nothing.
        $present = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $oldest.Dir.FullName -Recurse -File)) {
            $rel = $f.FullName.Substring($oldest.Dir.FullName.Length).TrimStart('\')
            $present[$rel.ToLowerInvariant()] = $f.FullName
        }
        foreach ($k in $present.Keys) {
            $dst = Join-Path $Dir $k
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $present[$k] -Destination $dst -Force
            $nRestore++
        }
        foreach ($e in $Entries) {
            if ($present.ContainsKey($e.Rel.ToLowerInvariant())) { continue }
            $dst = Join-Path $Dir $e.Rel
            if (Test-Path -LiteralPath $dst -PathType Leaf) {
                Remove-Item -LiteralPath $dst -Force
                $nDelete++
            }
        }
    }

    # Every backup goes, not just the one consumed: leaving the rest behind is how the
    # next install picks up a stale chain, and a stray backup directory in a FileZilla
    # install is not something the user should have to know to delete.
    foreach ($b in $backups) {
        Remove-Item -LiteralPath $b.Dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $backupRoot) {
        if (@(Get-ChildItem -LiteralPath $backupRoot -Force).Count -eq 0) {
            Remove-Item -LiteralPath $backupRoot -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Warn2 "left unrecognised content in ${backupRoot}: $((Get-ChildItem -LiteralPath $backupRoot -Force | ForEach-Object { $_.Name }) -join ', ')"
        }
    }

    Write-Step "restored $nRestore file(s), removed $nDelete overlay-only file(s)"
    if ($backups.Count -gt 1) {
        Write-Step "consumed $($backups.Count) overlapping backups and restored from the oldest ($($oldest.Dir.Name))"
    }
    else {
        Write-Step "consumed backup $($oldest.Dir.Name)"
    }
}

# Payload files still matching our own hashes, used to report an honest state when no
# backup survives to undo them.
function Get-LeftoverOverlayFiles {
    param([string]$Dir)

    $left = @()
    foreach ($e in $Entries) {
        $dst = Join-Path $Dir $e.Rel
        if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { continue }
        try {
            $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        catch { continue }
        if ($h -eq $e.Hash.ToLowerInvariant()) {
            $left += [pscustomobject]@{ Rel = $e.Rel }
        }
    }
    return $left
}

# ---------------------------------------------------------------- main

Write-Host "FileZilla $ExpectedVersion - system light/dark overlay" -ForegroundColor Cyan


$dir = Resolve-InstallDir
Write-Step "target: $dir"

# Checked here, before anything else, so a missing elevation is reported as such instead
# of surfacing later as a bare "Access to the path ... is denied" from whichever
# New-Item or Copy-Item happened to touch the directory first. Uninstall needs write
# access too, so the check covers both paths.
Assert-DirectoryWritable -Dir $dir

$entries = Read-OverlayManifest
Assert-OverlayIntact -Entries $entries

if ($Uninstall) {
    Stop-FileZilla -Dir $dir
    Invoke-Uninstall -Dir $dir -Entries $entries
    Write-Host 'Overlay removed; FileZilla restored to its previous state.' -ForegroundColor Green
    return
}

Assert-TargetVersion -Dir $dir

# After the manifest and version are confirmed - so the refusal cannot fire on a
# directory that is not even FileZilla - but before FileZilla is closed and a single
# byte is written.
Assert-OverlayNotInstalled -Dir $dir -Entries $entries -Force:$ForceOverAlreadyInstalled

Stop-FileZilla -Dir $dir

if ($PSCmdlet.ShouldProcess($dir, 'apply FileZilla dark overlay')) {
    Invoke-Install -Dir $dir -Entries $entries
    Write-Host 'Overlay applied. Start FileZilla and confirm it follows your Windows theme.' -ForegroundColor Green
    Write-Host "To undo:  .\install-dark-overlay_win64.ps1 -Uninstall -InstallDir '$dir'"
}
