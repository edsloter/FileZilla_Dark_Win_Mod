<#
.SYNOPSIS
    Proves the NSIS overlay installer and its removal tool work end to end.

.DESCRIPTION
    Builds a user-elevation copy of both artefacts with build-nsis-installer_win64.ps1, then
    runs them against a scratch copy of a stock FileZilla install:

      1. install with only /D (the equivalent of the PowerShell installer's -InstallDir),
         checking that the overlay landed, that nothing was deleted, that the patched client
         starts, and that fzstorj.exe - which the overlay does not replace and which shares
         the runtime DLLs - still starts;
      2. remove with the tool the installer placed in %LOCALAPPDATA%\fzdark, then compare the
         whole FileZilla tree against the pre-install state file by file.

    The live FileZilla installation is never touched: it is only read, as the source of the
    scratch copy.

    User-elevation builds are used because a Program Files target needs admin and a test run
    cannot be handed a UAC prompt. Everything except the elevation setting is byte-identical
    to the shipped artefact, because both come from the same templates.

.EXAMPLE
    .\test-nsis-installer_win64.ps1
#>
[CmdletBinding()]
param(
    # A stock FileZilla installation to copy. Read only.
    [string]$StockDir = 'C:\Program Files\FileZilla FTP Client',
    # Where the scratch copy and the test build are made.
    [string]$Work
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Work) { $Work = Join-Path $BuildRoot 'out\nsis-test' }

$builder = Join-Path $PSScriptRoot 'build-nsis-installer_win64.ps1'
$toolName = 'fzdark-overlay-uninstaller.exe'
$toolPath = Join-Path $env:LOCALAPPDATA "fzdark\$toolName"

# The parameter must not be called $Args: that is a PowerShell automatic variable, and naming
# a parameter after it makes Start-Process receive the wrong value. The symptom is silent and
# nasty - /D never reaches the installer, auto-detection finds the real Program Files install,
# and the resulting Abort message box hangs the run indefinitely.
#
# Start-Process -Wait is also deliberate. An NSIS installer runs a launcher stage that returns
# exit code 2 while the real work continues in a child process, so the call operator returns
# before any file is written and the tree looks untouched.
function Invoke-Wait {
    param([string]$Exe, [string[]]$ExeArgs, [int]$TimeoutMs = 900000)
    $p = Start-Process -FilePath $Exe -ArgumentList $ExeArgs -PassThru
    if (-not $p.WaitForExit($TimeoutMs)) {
        $p.Refresh()
        Write-Host "  !! timed out after ${TimeoutMs}ms - the installer is probably showing a dialog" -ForegroundColor Red
        Write-Host "     MainWindowTitle: '$($p.MainWindowTitle)'"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        throw "timed out: $Exe"
    }
    return $p.ExitCode
}

function Get-TreeState {
    param($Root)
    $h = @{}
    Get-ChildItem $Root -Recurse -File | ForEach-Object {
        $h[$_.FullName.Substring($Root.Length + 1)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
    return $h
}

# Run one of FileZilla's binaries and collect what it says, without ever being able to hang
# the suite and without handing it a console that might keep it waiting for input.
#
# Both details were learned the hard way. Invoking these with the call operator hangs in an
# interactive session - fzstorj.exe inherits stdin and blocks - while it returns instantly
# from a non-interactive one, so the same check passed here and stalled on the VM. And stdin
# is pointed at an empty file so the child sees EOF immediately instead of a console.
#
# A nonzero exit is not treated as failure: FileZilla writes its --version banner to stdout
# and then exits nonzero on a perfectly good build, and fzstorj.exe likewise announces itself
# and exits 1. Success is judged on the banner text.
function Invoke-Probe {
    param([string]$Exe, [string[]]$ExeArgs, [int]$TimeoutMs = 60000)

    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    $inFile = [IO.Path]::GetTempFileName()   # empty: the child gets EOF on stdin at once
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $ExeArgs -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -RedirectStandardInput $inFile
        if (-not $p.WaitForExit($TimeoutMs)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Text = ''; TimedOut = $true }
        }
        $text = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue) +
                (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
        return [pscustomobject]@{ Text = "$text".Trim(); TimedOut = $false }
    }
    finally {
        Remove-Item $outFile, $errFile, $inFile -Force -ErrorAction SilentlyContinue
    }
}

$problems = [System.Collections.Generic.List[string]]::new()

function Ok  { param([string]$m) Write-Host "  OK  $m" }
function Bad { param([string]$m) Write-Host "  !!  $m" -ForegroundColor Red; $problems.Add($m) }
function Step { param([string]$m) Write-Host ''; Write-Host "=== $m ===" }

if (-not (Test-Path -LiteralPath $StockDir -PathType Container)) {
    throw "no stock FileZilla installation at $StockDir. Pass -StockDir."
}

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Work | Out-Null

# ---------------------------------------------------------------------- build

Step 'A: build a user-elevation installer and removal tool'
# Invoke-Native always returns the output lines, so there is no -PassThru to pass;
# only Invoke-NativeLogged has one. The target here is the PowerShell host executable
# with its own -File switch, not a script invoked directly, so an argv-style
# -ArgumentList is correct - and the 5.1 stderr trap that would otherwise abort on a
# warning is why this goes through the helper at all.
Invoke-Native -File (Get-Process -Id $PID).Path `
    -ArgumentList @('-NoProfile', '-File', $builder, '-Elevation', 'user', '-OutName', 'setup-test-user.exe', '-OutputDir', $Work) `
    -IgnoreExitCode |
    ForEach-Object { if ("$_".Trim()) { "  $_" } }
$setup = Join-Path $Work 'setup-test-user.exe'
if (-not (Test-Path $setup)) { throw 'no test installer was produced' }

# -------------------------------------------------------------------- install

Step 'B: scratch copy of the stock install'
$dir = Join-Path $Work 'FileZilla FTP Client'
robocopy $StockDir $dir /E /NFL /NDL /NJH /NJS /NP | Out-Null
$before = Get-TreeState $dir
Ok "$($before.Count) files copied from $StockDir"

Step 'C: install silently, directory only via /D'
$code = Invoke-Wait -Exe $setup -ExeArgs @('/S', "/D=$dir")
Ok "installer exit=$code"

$after = Get-TreeState $dir
$removed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) })
$added = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
$changed = @($after.Keys | Where-Object { $before.ContainsKey($_) -and $before[$_] -ne $after[$_] })
Ok "replaced $($changed.Count), added $($added.Count), removed $($removed.Count)"
if ($removed.Count) { Bad "the installer deleted files it should not have: $($removed -join ', ')" }

$must = @(
    'filezilla.exe'
    'libfzclient-private-3-71-1.dll'
    'msys-fzclient-private-3-71-1.dll'
    'cygfilezilla-59.dll'
    'libfilezilla-59.dll'
    'resources\default\480x480\auto_light.png'
)
$miss = @($must | Where-Object { -not (Test-Path (Join-Path $dir $_)) })
if ($miss.Count) { Bad "overlay files missing after install: $($miss -join ', ')" }
else { Ok "all $($must.Count) expected overlay files are present" }

if (Test-Path $toolPath) { Ok "removal tool installed at $toolPath" }
else { Bad "no removal tool at $toolPath" }

Step 'C2: a second install over an installed overlay is refused'
# Installing twice used to be allowed, and it made the overlay impossible to remove: the
# second install backed up the already-overlaid files as if they were the originals, the
# uninstaller then restored the overlay over itself, and the Add/Remove Programs entry was
# deleted anyway. The user was left with dark mode and no way to undo it.
$beforeSecond = Get-TreeState $dir
$secondCode = Invoke-Wait -Exe $setup -ExeArgs @('/S', "/D=$dir") -TimeoutMs 300000
if ($secondCode -eq 0) {
    Bad 'a second install SUCCEEDED - the guard is missing and the undo chain can be corrupted'
}
else { Ok "second install refused with exit=$secondCode" }

$afterSecond = Get-TreeState $dir
$secondTouched = @($afterSecond.Keys | Where-Object {
    -not $beforeSecond.ContainsKey($_) -or $beforeSecond[$_] -ne $afterSecond[$_]
})
if ($secondTouched.Count) { Bad "the refused second install still changed $($secondTouched.Count) file(s)" }
else { Ok 'the refused install changed nothing on disk' }

$setupLog = Join-Path $env:TEMP 'fzdark-overlay-setup.log'
if (Test-Path $setupLog) {
    $logText = Get-Content $setupLog -Raw
    if ($logText -match 'already registered|backup folder from a previous') {
        Ok "refusal logged the real reason: $((($logText -split "`n") | Where-Object { $_ -match 'already registered|backup folder' } | Select-Object -First 1).Trim())"
    }
    else {
        Bad "the refusal did not log why. Log said: $($logText.Trim())"
    }
}
else { Bad "no refusal log at $setupLog" }

Step 'D: refuses cleanly while FileZilla from that folder is running'
# Regression test for a real failure. The first lock probe renamed filezilla.exe, and Windows
# permits renaming a running image - the image handle allows rename, just not delete - so the
# probe passed while FileZilla was open and the install then died part way through with NSIS's
# own "Error opening file for writing cygfilezilla-59.dll". The expected behaviour is a clean
# refusal before anything is touched.
#
# This runs against its OWN clean copy. The overlay is already installed in $dir by now, so
# reusing it would make the new already-installed guard refuse first and the lock would never
# actually be tested - the phase would pass without proving anything.
$dirLock = Join-Path $Work 'FileZilla FTP Client (lock test)'
if (Test-Path $dirLock) { Remove-Item $dirLock -Recurse -Force }
robocopy $StockDir $dirLock /E /NFL /NDL /NJH /NJS /NP | Out-Null
Ok "clean stock copy for the lock test at $dirLock"

$snapshot = Get-TreeState $dirLock
$backupsBefore = @(Get-ChildItem (Join-Path $dirLock 'fzdark-backup') -Directory -ErrorAction SilentlyContinue).Name

$fz = Start-Process -FilePath (Join-Path $dirLock 'filezilla.exe') -PassThru
Start-Sleep -Seconds 6
$running = @(Get-Process -Name 'filezilla' -ErrorAction SilentlyContinue |
    Where-Object { try { $_.Path -and $_.Path.StartsWith($dirLock, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
if ($running.Count -eq 0) {
    # Not fatal: a headless session may not be able to start a GUI app at all.
    Write-Host '  --  could not start FileZilla from the target folder, so the lock test did not run'
    $fz | Stop-Process -Force -ErrorAction SilentlyContinue
}
else {
    $refuseCode = Invoke-Wait -Exe $setup -ExeArgs @('/S', "/D=$dirLock") -TimeoutMs 300000
    foreach ($r in $running) { Stop-Process -Id $r.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2

    $postRefusal = Get-TreeState $dirLock
    $touched = @($postRefusal.Keys | Where-Object { -not $snapshot.ContainsKey($_) -or $snapshot[$_] -ne $postRefusal[$_] })
    $backupsAfter = @(Get-ChildItem (Join-Path $dirLock 'fzdark-backup') -Directory -ErrorAction SilentlyContinue).Name

    if ($refuseCode -eq 0) { Bad 'the installer ran to completion while FileZilla was open, so it must have written over locked files' }
    else { Ok "refused with exit=$refuseCode while filezilla.exe was running" }

    if ($touched.Count -eq 0) { Ok 'the refused install changed nothing at all' }
    else {
        Bad "the refused install still modified $($touched.Count) file(s)"
        $touched | Select-Object -First 8 | ForEach-Object { Write-Host "        $_" }
    }
    if (($backupsAfter -join ',') -eq ($backupsBefore -join ',')) { Ok "no stray backup directory: $($backupsBefore -join ', ')" }
    else { Bad "a backup directory was created by the refused run: was '$($backupsBefore -join ',')', now '$($backupsAfter -join ',')'" }
}

Step 'E: the patched client starts, and the untouched canary still starts'
$v = Invoke-Probe -Exe (Join-Path $dir 'filezilla.exe') -ExeArgs @('--version')
if ($v.TimedOut) {
    Bad 'patched FileZilla did not exit within 60s of --version'
}
elseif ($v.Text -match "^FileZilla $([regex]::Escape($FzVersion))") {
    Ok "patched FileZilla starts: $($v.Text)"
}
else {
    Bad "patched FileZilla did not report its version: $($v.Text)"
}

# fzstorj.exe is not replaced by the overlay but shares the runtime DLLs, so if the overlay
# disturbed anything it shows up here.
$st = Invoke-Probe -Exe (Join-Path $dir 'fzstorj.exe') -ExeArgs @('--version')
if ($st.TimedOut) {
    Bad 'fzstorj.exe did not exit within 60s, so the canary proved nothing. It is expected to announce itself and exit 1 immediately.'
}
elseif ($st.Text -match 'fzStorj started') {
    Ok "fzstorj.exe still starts, so the overlay left the shared runtime alone: $($st.Text)"
}
else {
    Bad "fzstorj.exe broke: $($st.Text)"
}

# ---------------------------------------------------------------------- remove

Step 'F: remove with the tool the installer shipped'
if (-not (Test-Path $toolPath)) { Bad 'cannot test removal: no tool installed'; return }
$rcode = Invoke-Wait -Exe $toolPath -ExeArgs @('/S', "/D=$dir")
Ok "removal tool exit=$rcode"

Step 'G: the FileZilla tree is byte-for-byte what it was'
$final = Get-TreeState $dir
$diff = @($final.Keys | Where-Object { -not $before.ContainsKey($_) -or $before[$_] -ne $final[$_] })
$gone = @($before.Keys | Where-Object { -not $final.ContainsKey($_) })
if ($diff.Count -eq 0 -and $gone.Count -eq 0) {
    Ok "all $($before.Count) files are exactly as they were"
}
else {
    Bad "$($diff.Count) new or changed, $($gone.Count) missing"
    $diff | Select-Object -First 10 | ForEach-Object { Write-Host "        new/changed: $_" }
    $gone | Select-Object -First 10 | ForEach-Object { Write-Host "        missing:     $_" }
}

foreach ($l in @('fzdark-backup', 'unins000.exe', 'unins000.dat', $toolName)) {
    if (Test-Path (Join-Path $dir $l)) { Bad "left behind in the FileZilla directory: $l" }
    else { Ok "not left behind: $l" }
}
Write-Host "  note  $toolPath is kept: a running executable cannot delete itself."
Write-Host '        It lives outside the FileZilla directory precisely so the installation can be'
Write-Host '        restored exactly, and it can be deleted at any time.'

Write-Host ''
if ($problems.Count -eq 0) { Write-Host '  ALL NSIS INSTALLER TESTS PASSED' }
else {
    Write-Host "  $($problems.Count) NSIS INSTALLER PROBLEM(S):" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}