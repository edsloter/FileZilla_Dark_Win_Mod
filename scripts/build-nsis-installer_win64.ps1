<#
.SYNOPSIS
    Compiles the overlay payload into FileZilla-<ver>-dark-overlay-setup.exe with NSIS.

.DESCRIPTION
    Takes the staged, stripped payload that build-overlay_win64.ps1 produced and turns it
    into a self-contained installer: the result detects the user's FileZilla directory,
    backs up what it is about to replace, installs, and registers a working uninstaller.
    Same outcome as the PowerShell installer shipped in the .7z, with no 7-Zip and no
    PowerShell needed by the end user.

    Compression is solid LZMA. makensis 3.13 accepts "SetCompressor /SOLID lzma" and rejects
    both "/SOLID lzma2" and "/SOLID_LZMA", so this is the strongest compressor NSIS offers
    here. The dictionary size is left at the default: measured against this payload it
    changes nothing (16, 32 and 64 MB produced byte-identical output).

    The installer logic lives in scripts\nsis\overlay-installer.nsi as a reviewable
    template. This script substitutes the version tokens and generates the per-file backup,
    copy and undo code from the staged tree, so the payload has exactly one source of truth -
    the staged overlay that the test suite validates - and the three generated lists cannot
    drift apart. They are generated independently and their sizes cross-checked below.

    Why per-file code instead of an embedded manifest the installer reads at run time: this
    NSIS build is not dependable for that. FileOpen on a file embedded with File into
    $PLUGINSDIR fails, and FileWrite does not expand backtick escapes, so a multi-line log
    cannot be written either. Compiling the list in avoids both.

.PARAMETER StageDir
    Staged overlay payload, normally <root>\out\stage\overlay.

.PARAMETER OutputDir
    Where the .exe is written. Normally <root>\out.

.PARAMETER Elevation
    RequestExecutionLevel for the generated installer. The shipped artefact wants admin,
    because a Program Files target needs it. A test build wants user: it runs unattended
    against a scratch copy and must not be handed a UAC prompt. Everything else is
    identical, so the test exercises the real thing.

.PARAMETER OutName
    Override the output file name, so a test build does not overwrite the release artefact.

.EXAMPLE
    .\build-nsis-installer_win64.ps1
#>
[CmdletBinding()]
param(
    [string]$StageDir,
    [string]$OutputDir,

    [ValidateSet('admin', 'user')]
    [string]$Elevation = 'admin',

    [string]$OutName,

    # File name for the removal tool that is embedded in the installer and copied into the
    # FileZilla directory. Overridable so a test build does not collide with a real one.
    [string]$UninstName = 'fzdark-overlay-uninstaller.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $StageDir) { $StageDir = Join-Path $BuildRoot 'out\stage\overlay' }
if (-not $OutputDir) { $OutputDir = Join-Path $BuildRoot 'out' }

function Write-Step { param([string]$m) Write-Host "  [nsis] $m" }

if (-not (Test-Path -LiteralPath $NsisExe)) { throw "makensis not found at $NsisExe. Run get-nsis_win64.ps1." }
if (-not (Test-Path -LiteralPath $StageDir -PathType Container)) { throw "staged payload not found: $StageDir" }

# The payload is everything in the staged tree except the PowerShell installer, its
# launcher, the manifest and the licences. Those stay behind in the .7z; the .exe does not
# need a script inside it to do the same job.
$excludeNames = @(
    'install-dark-overlay_win64.ps1'
    'install-dark-overlay_win64.bat'
    'versions.ps1'
    'overlay-manifest.txt'
    'README.md'
    'README.txt'
)
$payload = @(
    Get-ChildItem -LiteralPath $StageDir -Recurse -File |
        Where-Object { $excludeNames -notcontains $_.Name -and $_.FullName -notmatch '[\\/]licenses[\\/]' } |
        Sort-Object FullName
)
if ($payload.Count -eq 0) { throw "no payload files under $StageDir" }

$rawBytes = ($payload | Measure-Object -Property Length -Sum).Sum
Write-Step "payload: $($payload.Count) files, $([math]::Round($rawBytes / 1MB, 2)) MB"

# ---------------------------------------------------------------- generate script

$template = Join-Path $PSScriptRoot 'nsis\overlay-installer.nsi'
if (-not (Test-Path -LiteralPath $template)) { throw "installer template not found: $template" }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
if (-not $OutName) { $OutName = $NsisSetupName }
$outExe = Join-Path $OutputDir $OutName
$buildDir = Join-Path $OutputDir 'nsis-build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

# Relative paths, exactly as the manifest records them, in staged-tree order.
$relPaths = @(
    $payload | ForEach-Object { $_.FullName.Substring($StageDir.Length).TrimStart('\') }
)

# File statements grouped by destination directory: NSIS installs relative to the current
# OutPath and silently flattens everything otherwise.
$fileList = foreach ($group in ($payload | Group-Object { $_.DirectoryName } | Sort-Object Name)) {
    "`n  SetOutPath `"`$INSTDIR$($group.Name.Substring($StageDir.Length))`""
    foreach ($f in ($group.Group | Sort-Object Name)) {
        # Backslashes, not forward slashes: makensis resolves File paths itself and reports
        # an existing forward-slash path as "no files found".
        '  File "' + $f.FullName + '"'
    }
}
$fileList = ($fileList -join "`n")

# Pass 1: probe every payload file that already exists for write access, and abort on the
# first one that is locked. This runs before the backup directory is created, so a refusal
# leaves the installation exactly as it was - not even an empty backup folder.
#
# The probe is an append-open followed by a close with nothing written: a file held by a
# running FileZilla is opened by the loader with FILE_SHARE_READ only, so the open fails with
# a sharing violation, while an unlocked file opens fine and is left byte-identical.
#
# This replaced an in-place rename of filezilla.exe, which was wrong: Windows permits renaming
# a running image (the image handle allows rename, just not delete), so that probe passed
# while FileZilla was open, and the install then died part way through with NSIS's own
# "Error opening file for writing".
$probeCode = foreach ($rel in $relPaths) {
    @"
  ; $rel
  `${If} `${FileExists} "`$TargetDir\$rel"
    ClearErrors
    FileOpen `$Fh "`$TargetDir\$rel" a
    `${If} `${Errors}
      !insertmacro REFUSE "FileZilla is running from this folder, so its files cannot be replaced.$\n$\nLocked: $rel$\n$\nFolder:\n`$TargetDir$\n$\nClose FileZilla - or let your transfers finish -\nthen run this installer again.$\n$\nNothing has been changed."
    `${EndIf}
    FileClose `$Fh
  `${EndIf}
"@
}
$probeCode = ($probeCode -join "`n")

# Pass 2: back up everything that is about to be replaced, before writing any of it, so an
# install that fails later can still be undone from the backup directory alone. CopyFiles
# creates the intermediate directories, so the backup keeps the payload layout with no path
# surgery. This NSIS build cannot be relied on for runtime file I/O - FileOpen on a file
# embedded into $PLUGINSDIR fails, and FileWrite does not expand backtick escapes - so the
# payload is compiled in as code instead of read from a list at run time.
$backupCode = foreach ($rel in $relPaths) {
    @"
  ; $rel
  `${If} `${FileExists} "`$TargetDir\$rel"
    ClearErrors
    CopyFiles /SILENT "`$TargetDir\$rel" "`$NewestBackup\$rel"
    `${If} `${Errors}
      !insertmacro REFUSE "Could not back up one of the files it is about to replace:$\n$\n$rel$\n$\nin `$TargetDir$\n$\nNothing has been changed."
    `${EndIf}
    IntOp `$Replaced `$Replaced + 1
  `${Else}
    IntOp `$Added `$Added + 1
  `${EndIf}
"@
}
$backupCode = ($backupCode -join "`n")

# Per-file undo code: restore what has a backup copy, delete what has none.
$restoreCode = foreach ($rel in $relPaths) {
    @"
  ; $rel
  `${If} `${FileExists} "`$NewestBackup\$rel"
    ClearErrors
    CopyFiles /SILENT "`$NewestBackup\$rel" "`$TargetDir\$rel"
    `${If} `${Errors}
      DetailPrint "Could not restore $rel from the backup."
    `${EndIf}
    IntOp `$Replaced `$Replaced + 1
  `${Else}
    Delete "`$TargetDir\$rel"
    IntOp `$Added `$Added + 1
  `${EndIf}
"@
}
$restoreCode = ($restoreCode -join "`n")

$tpl = Get-Content -LiteralPath $template -Raw
$tpl = $tpl.Replace('@@OUTFILE@@', $outExe)
$tpl = $tpl.Replace('@@FZVERSION@@', $FzVersion)
# The client DLL names carry the version with dots turned into dashes, e.g. 3.71.1 ->
# 3-71-1. Deriving it here keeps that convention in one place.
$tpl = $tpl.Replace('@@FZVERSIONFILE@@', ($FzVersion -replace '\.', '-'))
$tpl = $tpl.Replace('@@ELEVATION@@', $Elevation)
$tpl = $tpl.Replace('@@PAYLOAD_BEGIN@@', $fileList)
$tpl = $tpl.Replace('@@PROBE_BEGIN@@', $probeCode)
$tpl = $tpl.Replace('@@BACKUP_BEGIN@@', $backupCode)
$tpl = $tpl.Replace('@@RESTORE_BEGIN@@', $restoreCode)
$tpl = $tpl.Replace('@@PAYLOAD_COUNT@@', [string]$relPaths.Count)

$genNsi = Join-Path $buildDir 'overlay-installer.nsi'
Set-Content -LiteralPath $genNsi -Value $tpl -Encoding UTF8

# ---------------------------------------------------------------- uninstaller

# A second, payload-free executable performs removal. NSIS's own uninstaller was tried and
# abandoned: this makensis builds one that runs silently and does nothing at all, so it was
# replaced with an ordinary installer whose section does the restore. It carries no files,
# so it is around 100 KB and its restore code is generated from the same payload list.
$uninstTemplate = Join-Path $PSScriptRoot 'nsis\overlay-uninstaller.nsi'
if (-not (Test-Path -LiteralPath $uninstTemplate)) { throw "uninstaller template not found: $uninstTemplate" }

$uninstExe = Join-Path $buildDir $UninstName
$uninstNsi = Join-Path $buildDir 'overlay-uninstaller.generated.nsi'
$u = Get-Content -LiteralPath $uninstTemplate -Raw
$u = $u.Replace('@@UNINST_OUTFILE@@', $uninstExe)
$u = $u.Replace('@@UNINST_NAME@@', $UninstName)
$u = $u.Replace('@@FZVERSION@@', $FzVersion)
$u = $u.Replace('@@ELEVATION@@', $Elevation)
$u = $u.Replace('@@RESTORE_BEGIN@@', $restoreCode)
Set-Content -LiteralPath $uninstNsi -Value $u -Encoding UTF8

# The uninstaller is embedded in the installer, so the shipped .exe is self-contained.
$tpl2 = [IO.File]::ReadAllText($genNsi)
$tpl2 = $tpl2.Replace('@@UNINST_EXE@@', $uninstExe).Replace('@@UNINST_NAME@@', $UninstName)
Set-Content -LiteralPath $genNsi -Value $tpl2 -Encoding UTF8

# The three lists are emitted independently from one enumeration, so their sizes are
# cross-checked rather than trusted.
$copied = ([regex]::Matches($fileList, '(?m)^\s*File "')).Count
$backed = ([regex]::Matches($backupCode, '(?m)^\s*; ')).Count
$probed = ([regex]::Matches($probeCode, '(?m)^\s*; ')).Count
$undone = ([regex]::Matches($restoreCode, '(?m)^\s*; ')).Count
if ($copied -ne $relPaths.Count -or $probed -ne $relPaths.Count -or
    $backed -ne $relPaths.Count -or $undone -ne $relPaths.Count) {
    throw "internal error: $($relPaths.Count) payload paths produced $copied copy, $probed probe, $backed backup and $undone undo blocks"
}

# ---------------------------------------------------------------- compile

Write-Step "compiling the uninstaller with $(& $NsisExe -VERSION)"
$uninstLog = Join-Path $buildDir 'makensis-uninstaller.log'
$uninstOut = Invoke-Native -File $NsisExe -ArgumentList @('/V3', $uninstNsi) -IgnoreExitCode
$uninstCode = $LASTEXITCODE
$uninstOut | Set-Content -LiteralPath $uninstLog -Encoding UTF8
$uninstErrors = @($uninstOut | Select-String -Pattern '\berror\b\s*:' -CaseSensitive:$false)
$uninstUnresolved = @($uninstOut | Select-String -Pattern 'warning\s+6040' -CaseSensitive:$false)
if ($uninstCode -ne 0 -or $uninstErrors.Count -or $uninstUnresolved.Count) {
    Write-Host ($uninstOut | Select-Object -Last 30) -ForegroundColor Red
    throw "uninstaller compile failed (exit $uninstCode, $($uninstErrors.Count) error(s), $($uninstUnresolved.Count) unresolved reference(s)). See $uninstLog"
}
if (-not (Test-Path -LiteralPath $uninstExe)) { throw "makensis produced no uninstaller at $uninstExe" }
Write-Step ("uninstaller built ({0:N0} KB)" -f ((Get-Item $uninstExe).Length / 1KB))

Write-Step "compiling the installer with $(& $NsisExe -VERSION)"
$log = Join-Path $buildDir 'makensis.log'
$out = Invoke-Native -File $NsisExe -ArgumentList @('/V3', $genNsi) -IgnoreExitCode
$code = $LASTEXITCODE
$out | Set-Content -LiteralPath $log -Encoding UTF8

# Two classes of problem are fatal here, and neither is signalled by the exit code.
#
#   "error"        a genuine compile failure.
#   warning 6040   "LangString X is not set in language table". This is what a mistyped
#                  reference produces: $(FZ_VERSION) instead of ${FZ_VERSION} in an NSIS
#                  script is a LangString lookup, not a variable or define reference, and it
#                  silently expands to nothing while still compiling. That is how an earlier
#                  version of this installer ended up testing the version check against a
#                  root-relative path and refusing every install.
$errors = @($out | Select-String -Pattern '\berror\b\s*:' -CaseSensitive:$false)
$unresolved = @($out | Select-String -Pattern 'warning\s+6040' -CaseSensitive:$false)
if ($code -ne 0 -or $errors.Count -or $unresolved.Count) {
    Write-Host ($out | Select-Object -Last 40) -ForegroundColor Red
    foreach ($w in $unresolved) {
        Write-Host ("  unresolved reference: " + ($w.Line -replace '^.*?warning\s+6040:\s*', '')) -ForegroundColor Yellow
    }
    throw "makensis failed (exit $code, $($errors.Count) error(s), $($unresolved.Count) unresolved reference(s)). See $log"
}
Write-Step 'compile clean'

# ---------------------------------------------------------------- verify

Remove-Item -LiteralPath "$outExe.sha256" -Force -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $outExe)) { throw "makensis reported success but produced no $outExe" }

$len = (Get-Item -LiteralPath $outExe).Length
$fs = [IO.File]::OpenRead($outExe)
try { $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2) } finally { $fs.Close() }
if ([Text.Encoding]::ASCII.GetString($b) -ne 'MZ') { throw "$outExe is not a PE file (no MZ signature)" }

Write-Step ("built {0} ({1:N2} MB, {2:N1}% of raw payload)" -f (Split-Path -Leaf $outExe), ($len / 1MB), (100 * $len / $rawBytes))

$sha = (Get-FileHash -LiteralPath $outExe -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$outExe.sha256" -Value "$sha  $(Split-Path -Leaf $outExe)" -Encoding ASCII
Write-Step "sha256 $sha"

Write-Host "  [nsis] $outExe"