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
    Restore the newest backup this script made and remove the overlay files.

.PARAMETER Force
    Close a running FileZilla without asking, and continue on version mismatch
    warnings.

.PARAMETER NoVersionCheck
    Skip the FileZilla version check. Only for testing against a mock install.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1 -InstallDir 'C:\Program Files\FileZilla'

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-dark-overlay_win64.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallDir,
    [switch]$Uninstall,
    [switch]$Force,
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

# FileZilla uses the autotools layout even on Windows: the install root holds
# bin\, share\ and locale\, and the executable lives in bin\. Some repackaged
# builds flatten it, so accept either.
function Get-FileZillaExePath {
    param([string]$Dir)
    foreach ($rel in @('bin\filezilla.exe', 'filezilla.exe')) {
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
            throw "no filezilla.exe under $explicit. Point -InstallDir at the FileZilla folder that contains bin\."
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

function Invoke-Install {
    param([string]$Dir, $Entries)

    $backupRoot = Join-Path $Dir $BackupDirName
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path $backupRoot $stamp
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
    param([string]$Dir)

    $backupRoot = Join-Path $Dir $BackupDirName
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        throw "no backup directory at $backupRoot, nothing to uninstall."
    }

    $newest = Get-ChildItem -LiteralPath $backupRoot -Directory |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { throw "no backups found in $backupRoot" }

    $logPath = Join-Path $newest.FullName 'backup-manifest.txt'
    if (-not (Test-Path -LiteralPath $logPath)) {
        throw "backup $newest is incomplete (no backup-manifest.txt). Restore it by hand."
    }

    $nRestore = 0; $nDelete = 0
    foreach ($line in [System.IO.File]::ReadAllLines($logPath)) {
        if (-not $line.Trim() -or $line.TrimStart().StartsWith('#')) { continue }
        $m = [regex]::Match($line, '^(replaced|added)\s+(.+)$')
        if (-not $m.Success) { throw "malformed backup manifest line: $line" }
        $action = $m.Groups[1].Value
        $rel = $m.Groups[2].Value.Trim().Replace('/', '\')
        $dst = Join-Path $Dir $rel

        if ($action -eq 'replaced') {
            $save = Join-Path $newest.FullName $rel
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

    Remove-Item -LiteralPath $newest.FullName -Recurse -Force
    if (@(Get-ChildItem -LiteralPath $backupRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $backupRoot -Force
    }

    Write-Step "restored $nRestore file(s), removed $nDelete overlay-only file(s)"
    Write-Step "consumed backup $($newest.Name)"
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

if ($Uninstall) {
    Stop-FileZilla -Dir $dir
    Invoke-Uninstall -Dir $dir
    Write-Host 'Overlay removed; FileZilla restored to its previous state.' -ForegroundColor Green
    return
}

$entries = Read-OverlayManifest
Assert-OverlayIntact -Entries $entries
Assert-TargetVersion -Dir $dir
Stop-FileZilla -Dir $dir

if ($PSCmdlet.ShouldProcess($dir, 'apply FileZilla dark overlay')) {
    Invoke-Install -Dir $dir -Entries $entries
    Write-Host 'Overlay applied. Start FileZilla and confirm it follows your Windows theme.' -ForegroundColor Green
    Write-Host "To undo:  .\install-dark-overlay_win64.ps1 -Uninstall -InstallDir '$dir'"
}
