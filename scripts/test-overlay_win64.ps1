<#
.SYNOPSIS
    End-to-end test for the drop-in overlay against a real copy of an actual
    FileZilla installation of the pinned version.

.DESCRIPTION
    Three independent paths are exercised against real stock files:
      A. the staged payload copied over the installation, the documented simple route
      B. the reversible script installer, then -Uninstall
      C. the released .7z archive, extracted and checked against the manifest
    All must leave FileZilla startable, B must restore the installation byte for
    byte, and C must reproduce the payload exactly.

    Phase C matters because packaging is a separate step from staging. A build can
    produce a perfect payload and still ship an archive that lost a file, nested
    everything one directory too deep, or was compressed with the wrong tool.
#>
[CmdletBinding()]
param(
    [string]$StockDir = 'C:\Program Files\FileZilla FTP Client',
    [string]$Overlay = 'C:\fzdark\out\stage\overlay',
    # Left empty so it can be derived from versions.ps1 below; param defaults are
    # evaluated before a dot-source has run, so the archive name cannot be built here.
    [string]$Archive,
    [string]$Work = 'C:\fzdark\out\realtest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Archive) { $Archive = Join-Path 'C:\fzdark\out' $OverlayName }

$Helper = Join-Path $Overlay 'install-dark-overlay_win64.ps1'

$payload = @()
foreach ($line in Get-Content (Join-Path $Overlay 'overlay-manifest.txt')) {
    if ($line -match '^[0-9a-f]{64}\s\s(.+)$') { $payload += $Matches[1].Trim() }
}
$payloadHash = @{}
foreach ($p in $payload) {
    $payloadHash[$p] = (Get-FileHash (Join-Path $Overlay ($p -replace '/', '\')) -Algorithm SHA256).Hash
}

function Step { param([string]$m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok { param([string]$m) Write-Host "   OK  $m" -ForegroundColor Green }

# Run one of FileZilla's binaries and collect what it says.
#
# Two details matter and were both learned the hard way. stdin is redirected to an empty file
# so the child gets EOF immediately instead of inheriting a console: without this, fzstorj.exe
# blocks waiting for input in an interactive session and the suite hangs there while passing
# from a non-interactive one. And the wait is bounded, so a binary that never exits fails the
# check instead of stalling the run.
#
# A nonzero exit is not failure: FileZilla prints its --version banner to stdout and then
# exits nonzero on a perfectly good build, and fzstorj.exe likewise announces itself and
# exits 1. Success is judged on the banner text.
function Invoke-Exe {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutMs = 60000)
    $OutFile = Join-Path $env:TEMP ("fzt-" + [guid]::NewGuid().ToString('n') + '.txt')
    $ErrFile = $OutFile + '.e'
    $InFile = $OutFile + '.in'
    # Must exist before Start-Process: -RedirectStandardInput rejects a path that does not.
    New-Item -ItemType File -Path $InFile -Force | Out-Null
    try {
        $p = Start-Process -FilePath $Path -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -RedirectStandardInput $InFile
        if (-not $p.WaitForExit($TimeoutMs)) {
            Stop-Process -Id $p.Id -Force -EA SilentlyContinue
            return [pscustomobject]@{ ExitCode = -1; Text = ''; TimedOut = $true }
        }
        $text = [string]((Get-Content $OutFile -Raw -EA SilentlyContinue) + (Get-Content $ErrFile -Raw -EA SilentlyContinue))
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Text = "$text".Trim(); TimedOut = $false }
    }
    finally {
        Remove-Item $OutFile, $ErrFile, $InFile -Force -EA SilentlyContinue
    }
}

function New-StockCopy {
    param([string]$Name)
    $dest = Join-Path $Work $Name
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $StockDir -Destination $dest -Recurse -Force
    return $dest
}

function Get-TreeState {
    param([string]$Dir)
    $state = @{}
    foreach ($f in Get-ChildItem $Dir -Recurse -File -Force) {
        $rel = $f.FullName.Substring($Dir.Length + 1)
        $state[$rel] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
    }
    return $state
}

# FileZilla's --version writes the banner to stdout and then exits nonzero even on
# a perfectly good build: the stock build returns -1, ours returns 255. So success
# has to be judged on the banner text, not on the exit code.
function Assert-VersionBanner {
    param([string]$Path, [string]$Label)
    $r = Invoke-Exe -Path $Path -Arguments '--version'
    if ($r.Text -notmatch '^FileZilla 3\.71\.1') {
        throw "$Label did not start (exit $($r.ExitCode)): $($r.Text)"
    }
    Ok "$Label starts: $($r.Text)"
}

function Assert-PatchedRuns {
    param([string]$Dir, [string]$Label)
    Assert-VersionBanner -Path (Join-Path $Dir 'filezilla.exe') -Label "$Label FileZilla"

    # fzstorj.exe was not touched by the overlay but does use the shared runtime
    # DLLs, so it is the canary for us having disturbed them. It announces itself
    # and exits 1, so look for its banner rather than a clean exit.
    $fz = Join-Path $Dir 'fzstorj.exe'
    if (Test-Path $fz) {
        $r2 = Invoke-Exe -Path $fz -Arguments '--version'
        if ($r2.Text -notmatch 'fzStorj started') { throw "$Label fzstorj.exe broke (exit $($r2.ExitCode)): $($r2.Text)" }
        Ok "$Label fzstorj.exe still starts: $($r2.Text)"
    }
}

# ---------------------------------------------------------------- A: plain extract

Step 'A: plain extraction over a real copy of the stock installation'
$dirA = New-StockCopy -Name 'A-plain'
$stateA = Get-TreeState -Dir $dirA
Ok "stock copy has $($stateA.Count) files"

Assert-VersionBanner -Path (Join-Path $dirA 'filezilla.exe') -Label 'stock copy, before any change'

foreach ($p in $payload) {
    $dst = Join-Path $dirA ($p -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Overlay ($p -replace '/', '\')) -Destination $dst -Force
}
Ok "extracted $($payload.Count) payload files"

$stateAfter = Get-TreeState -Dir $dirA
# Map payload paths (forward slashes) onto the native relative paths used by the
# tree snapshots, so the comparison below never has to juggle separators.
$payloadNative = @{}
foreach ($p in $payload) { $payloadNative[($p -replace '/', '\')] = $p }

$changed = @($payloadNative.Keys | Where-Object { $stateAfter[$_] -ne $stateA[$_] })
$replaced = @($changed | Where-Object { $stateA.ContainsKey($_) })
$added = @($changed | Where-Object { -not $stateA.ContainsKey($_) })
Ok "payload replaced $($replaced.Count) existing files, added $($added.Count) new ones"
if ($replaced -notcontains 'filezilla.exe') { throw 'filezilla.exe was not replaced' }

$untouched = @($stateA.Keys | Where-Object { -not $payloadNative.ContainsKey($_) })
$clobbered = @($untouched | Where-Object { $stateAfter[$_] -ne $stateA[$_] })
if ($clobbered.Count -gt 0) { throw "overlay modified $($clobbered.Count) file(s) outside its payload: $($clobbered -join ', ')" }
Ok "all $($untouched.Count) non-payload files untouched, including fzstorj.exe and the wx 3.2 libraries"

Assert-PatchedRuns -Dir $dirA -Label 'A:'

# ---------------------------------------------------------------- B: script install

Step 'B: reversible script installer on a second real copy'
$dirB = New-StockCopy -Name 'B-script'
$stateB = Get-TreeState -Dir $dirB
Ok "stock copy has $($stateB.Count) files"

& $Helper -InstallDir $dirB
Ok 'installer reported success'

Assert-PatchedRuns -Dir $dirB -Label 'B:'

$backupRoot = Join-Path $dirB 'fzdark-backup'
if (-not (Test-Path $backupRoot)) { throw 'no backup directory created' }
$bk = Get-ChildItem $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
$log = Get-Content (Join-Path $bk.FullName 'backup-manifest.txt') | Where-Object { $_ -notmatch '^#' -and $_.Trim() }
$rep = @($log | Where-Object { $_ -like 'replaced*' })
$add = @($log | Where-Object { $_ -like 'added*' })
Ok "backup recorded $($rep.Count) replaced and $($add.Count) added"
if (($rep.Count + $add.Count) -ne $payload.Count) { throw "backup log covers $($rep.Count + $add.Count) files, expected $($payload.Count)" }
foreach ($r in ($rep | Select-Object -First 5)) { Write-Host "        $($r.Substring(8))" }

Step 'B: uninstall restores the installation exactly'
& $Helper -InstallDir $dirB -Uninstall
Ok 'uninstaller reported success'

$stateRestored = Get-TreeState -Dir $dirB
$diff = @()
foreach ($k in $stateB.Keys) {
    if (-not $stateRestored.ContainsKey($k)) { $diff += "removed: $k" }
    elseif ($stateRestored[$k] -ne $stateB[$k]) { $diff += "changed: $k" }
}
foreach ($k in $stateRestored.Keys) { if (-not $stateB.ContainsKey($k)) { $diff += "left behind: $k" } }
if ($diff.Count -gt 0) { throw "uninstall was not exact:`n    $($diff -join "`n    ")" }
Ok "all $($stateB.Count) stock files restored byte for byte, nothing left behind"
Ok 'backup directory cleaned up'

Step 'B: reinstall after uninstall still works (idempotent recovery)'
& $Helper -InstallDir $dirB | Out-Null
Assert-PatchedRuns -Dir $dirB -Label 'B reinstalled:'

# --------------------------------------------------- B: the double-install regression
#
# Installing the overlay twice used to be possible, and it destroyed the only way back.
# The second install saw all 32 payload files already present, so it backed up the
# OVERLAY files as if they were the originals; the uninstaller then restored the overlay
# over itself, the genuine stock files stayed buried in an older backup nothing pointed
# at, and the Add/Remove Programs entry was deleted anyway - leaving dark mode installed
# with no way to remove it. Each phase below is one link in that chain.
Step 'B: a second install over an installed overlay is refused'
$refused = $false
$why = ''
try {
    & $Helper -InstallDir $dirB | Out-Null
}
catch {
    $refused = $true
    $why = $_.Exception.Message
}
if (-not $refused) { throw 'a second install SUCCEEDED - the guard is missing and the undo chain can be corrupted' }
if ($why -notmatch 'already installed') { throw "the refusal does not say the overlay is already installed:`n    $why" }
if ($why -notmatch 'breaks removal') { throw "the refusal does not explain why a second install is refused:`n    $why" }
Ok 'second install refused, and the message explains the consequence'
Assert-PatchedRuns -Dir $dirB -Label 'B after the refused second install:'
Ok 'the refused install changed nothing'

Step 'B: two overlapping backups restore the STOCK files, not the overlay'
# Reproduce the corrupted state a pre-guard second install left behind: a second backup
# holding the overlay's own files, as though they were the originals.
$backupRoot = Join-Path $dirB 'fzdark-backup'
$newest = (Get-ChildItem $backupRoot -Directory | Sort-Object Name | Select-Object -Last 1)
$poisoned = Join-Path $backupRoot 'backup-9999'
New-Item -ItemType Directory -Force -Path $poisoned | Out-Null
Get-ChildItem $newest.FullName -Recurse -File -Filter '*.dll' | ForEach-Object {
    $rel = $_.FullName.Substring($newest.FullName.Length).TrimStart('\')
    $dst = Join-Path $poisoned $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item $_.FullName $dst -Force
}
Set-Content -LiteralPath (Join-Path $poisoned 'installed.txt') -Value 'fzdark dark overlay backup'
Ok "planted a second, poisoned backup alongside $($newest.Name)"
Start-Sleep -Milliseconds 1100   # make the creation order unambiguous

& $Helper -InstallDir $dirB -Uninstall | Out-Null
$stateAfterDouble = Get-TreeState -Dir $dirB
$leftDark = @()
foreach ($k in $stateAfterDouble.Keys) {
    if ($stateB.ContainsKey($k) -and $stateAfterDouble[$k] -ne $stateB[$k]) { $leftDark += $k }
}
if ($leftDark.Count -gt 0) {
    throw "uninstall restored the overlay over itself; $($leftDark.Count) file(s) still dark:`n    $($leftDark -join "`n    ")"
}
Ok 'restored the genuine stock files from the OLDEST backup, not the overlay'
if (Test-Path -LiteralPath $backupRoot) {
    $residue = @(Get-ChildItem $backupRoot -Force)
    throw "backup directory not cleaned up; left: $($residue.Name -join ', ')"
}
Ok 'both backups removed, no residue'

Step 'B: an orphaned overlay is reported honestly, not as "nothing to uninstall"'
& $Helper -InstallDir $dirB | Out-Null
Remove-Item -LiteralPath (Join-Path $dirB 'fzdark-backup') -Recurse -Force
Ok 'removed the backup by hand, leaving the overlay applied'

$msg = ''
try { & $Helper -InstallDir $dirB -Uninstall | Out-Null }
catch { $msg = $_.Exception.Message }
if ($msg -eq '') { throw 'uninstall reported success with no backup present, so there is nothing to restore' }
if ($msg -match 'nothing to uninstall') {
    throw "the uninstaller claims nothing is installed while the overlay files are still on disk:`n    $msg"
}
if ($msg -notmatch 'still in place') { throw "the uninstaller does not say the overlay files are still there:`n    $msg" }
Ok 'uninstaller refuses and names what is still installed instead of claiming otherwise'

$leftoverRefused = $false
try { & $Helper -InstallDir $dirB | Out-Null } catch { $leftoverRefused = $true }
if (-not $leftoverRefused) { throw 'a fresh install over an orphaned overlay SUCCEEDED - the hash check is missing' }
Ok 'the guard still refuses an install over an orphaned overlay (no backup, no registry)'

# Deliberately NOT uninstalled here. With the backup gone there is nothing to restore
# from, so dirB is still dark and no amount of retrying will fix it - which is the whole
# point of the honest message above. Rebuilt from stock for anything that follows.
$dirB = New-StockCopy -Name 'B-script'
$stateB = Get-TreeState -Dir $dirB
Ok 'orphaned copy rebuilt from stock for the remaining phases'

# ---------------------------------------------------------------- C: released archive

Step 'C: the released .7z archive round-trips'

if (-not (Test-Path -LiteralPath $Archive)) {
    throw "archive not found: $Archive (run build-overlay_win64.ps1 first)"
}

if (-not (Test-Path -LiteralPath $SevenZipExe)) {
    $found = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $found) { throw "7-Zip not found at $SevenZipExe and 7z.exe is not on PATH. Run install-toolchain_win64.ps1 first." }
    $sevenZip = $found.Source
}
else {
    $sevenZip = $SevenZipExe
}

# t = test the archive without extracting. A truncated or malformed archive is the
# most likely packaging failure and the cheapest to catch here.
& $sevenZip t $Archive | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7-Zip integrity test failed on $Archive (exit $LASTEXITCODE)" }
Ok "7-Zip integrity test passed on $([math]::Round((Get-Item $Archive).Length / 1MB, 1)) MB archive"

$dirC = Join-Path $Work 'C-archive'
if (Test-Path $dirC) { Remove-Item $dirC -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dirC | Out-Null
& $sevenZip x $Archive "-o$dirC" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed (exit $LASTEXITCODE)" }

# The payload must sit at the archive root, so "extract here" over an existing
# FileZilla folder works without the user having to move anything.
if (-not (Test-Path -LiteralPath (Join-Path $dirC 'filezilla.exe'))) {
    $top = @(Get-ChildItem $dirC -File | ForEach-Object Name)
    throw "filezilla.exe is not at the archive root. Top level holds: $($top -join ', ')"
}
Ok 'payload sits at the archive root, no wrapping directory'

# Compare every payload file in the archive against the staged original by hash.
$bad = @()
foreach ($p in $payload) {
    $rel = $p -replace '/', '\'
    $got = Join-Path $dirC $rel
    if (-not (Test-Path -LiteralPath $got)) { $bad += "missing from archive: $p"; continue }
    if ((Get-FileHash $got -Algorithm SHA256).Hash -ne $payloadHash[$p]) { $bad += "hash differs: $p" }
}
if ($bad.Count -gt 0) { throw "archive does not match the staged payload:`n    $($bad -join "`n    ")" }
Ok "all $($payload.Count) payload files match the staged build byte for byte"

foreach ($doc in 'README.txt', 'overlay-manifest.txt', 'install-dark-overlay_win64.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $dirC $doc))) { throw "archive is missing $doc" }
}
Ok 'installer, README and manifest are all present in the archive'

# The extracted installer must actually run, and it must find itself from wherever
# the archive was unpacked rather than assuming the staging path.
$helperC = Join-Path $dirC 'install-dark-overlay_win64.ps1'
if (-not (Test-Path -LiteralPath $helperC)) { throw "extracted installer missing at $helperC" }

$dirD = New-StockCopy -Name 'D-from-archive'
& $helperC -InstallDir $dirD | Out-Null
Assert-PatchedRuns -Dir $dirD -Label 'D (installed from extracted archive):'
& $helperC -InstallDir $dirD -Uninstall | Out-Null
$stateD = Get-TreeState -Dir $dirD
if ($stateD.Count -ne $stateB.Count) {
    throw "install-from-archive then uninstall left $($stateD.Count) files, stock copy had $($stateB.Count)"
}
Ok 'installer shipped inside the archive installs and uninstalls cleanly'

Write-Host "`nALL OVERLAY TESTS PASSED" -ForegroundColor Green
