<#
.SYNOPSIS
    Prepares this repo to build against a new FileZilla release, and reports what is
    still left to do by hand.

.DESCRIPTION
    Four things pin the kit to one specific release and cannot be carried across a
    version bump by editing a number:

      manifests\filezilla-<ver>.sources.sha256
          A per-file SHA-256 manifest of the pristine upstream tree. A new release
          hashes differently, so a 3.71.1 build cannot start until the manifest for
          the new version exists.

      $FzPatchedTree in versions.ps1
          The git tree hash the FileZilla patch series is known to produce. It changes
          if upstream moves AND if any patch is edited, so it has to be recomputed
          after the series is re-applied.

      $WxBaselineTree in versions.ps1
          The same for wxWidgets, for the PRISTINE tree.

      $WxPatchedTree in versions.ps1
          The same for wxWidgets, after the series is applied.

    This script does all four, and then tells you what still needs a human: whether
    each patch applied, what changed, and the new pins to paste into versions.ps1.

    It deliberately does not rewrite versions.ps1. versions.ps1 is the audited record
    of what was verified, so it should change only when someone has read the diff and
    agreed the new tree is right. This prints the values instead.

    wxWidgets is handled separately from FileZilla because it moves separately. A
    FileZilla release does not change wxWidgets, so $WxBaselineTree and $WxPatchedTree
    carry over untouched, and this script says so rather than leaving you to wonder
    whether they still apply. Pass -WxVersion to bump wxWidgets at the same time; the
    series is then re-applied with -Repin so both new hashes are printed.

.PARAMETER Version
    The new FileZilla version, e.g. 3.72.0. Must match $FzVersion in versions.ps1.

.PARAMETER WxVersion
    The new wxWidgets version, e.g. 3.3.4, when wxWidgets is being bumped too. Omit it
    when only FileZilla moves, which is the usual case. The new wxWidgets sources must
    already be extracted to $WxRoot - extract-deps_win64.ps1 - because that is where
    the series is re-applied and re-pinned.

.PARAMETER SourceTree
    Extracted pristine upstream tree for the new version. Defaults to
    <root>\src\filezilla\filezilla-<ver>.

.PARAMETER WorkTree
    Scratch git work tree used to apply the series. Defaults to
    <root>\work\port-<ver>. Left in place afterwards so a rejected hunk can be
    examined rather than deleted.

.PARAMETER Root
    Build root. Defaults to $BuildRoot from versions.ps1.

.PARAMETER Keep
    Do not delete the scratch work tree at the end.

.EXAMPLE
    .\update-version_win64.ps1 -Version 3.72.0

.EXAMPLE
    .\update-version_win64.ps1 -Version 3.72.0 -WxVersion 3.3.4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$WxVersion,

    [string]$SourceTree,
    [string]$WorkTree,
    [string]$Root,
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Captured before versions.ps1 is dot-sourced below, which defines $WxVersion itself.
# PowerShell variable names are case-insensitive, so a parameter of that name is the
# same variable and the dot-source would overwrite the request with the pinned
# version. Reading it here is the only way to tell "bump wxWidgets" from "leave it".
$wxRequested = $WxVersion

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PatchesDir = Join-Path $RepoRoot 'patches'
$Manifests = Join-Path $RepoRoot 'manifests'

if (-not $Root) { $Root = $BuildRoot }
if (-not $SourceTree) { $SourceTree = Join-Path $Root "src\filezilla\filezilla-$Version" }
if (-not $WorkTree) { $WorkTree = Join-Path $Root "work\port-$Version" }

function Step { param([string]$m) Write-Host "  [port] $m" }
function Good { param([string]$m) Write-Host "  [ok]   $m" }
function Warn { param([string]$m) Write-Host "  [warn] $m" }
function Bad  { param([string]$m) Write-Host "  [!!]   $m" }

# Assigned first, never as (Get-Command ...).Source: under Set-StrictMode,
# reading .Source on the $null that Get-Command returns when git is not on PATH
# throws PropertyNotFoundStrict, so the check below would never run.
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
$git = if ($gitCmd) { $gitCmd.Source } else { $null }
if (-not $git) {
    $candidate = 'C:\Program Files\Git\cmd\git.exe'
    if (Test-Path -LiteralPath $candidate) { $git = $candidate }
}
if (-not $git) { throw 'git not found on PATH or at its standard install location' }

# ------------------------------------------------------------------ preflight

if ($Version -eq $FzVersion) {
    Warn "versions.ps1 already pins $Version; this is the version the repo is built against."
    Warn 'Bump $FzVersion in versions.ps1 first if you are moving to a different release.'
}
else {
    Step "targeting FileZilla $Version (repo currently pins $FzVersion)"
}

if (-not (Test-Path -LiteralPath $SourceTree -PathType Container)) {
    throw "upstream tree not found: $SourceTree`nExtract the release tarball there first (get-filezilla-source_win64.ps1), or pass -SourceTree."
}

$patchFiles = @(Get-ChildItem -LiteralPath $PatchesDir -Filter '*.patch' -ErrorAction SilentlyContinue | Sort-Object Name)
if ($patchFiles.Count -eq 0) { throw "no patches in $patchFiles" }

# ------------------------------------------------- 1. manifest for the new tree

Step "hashing the upstream tree for the per-file manifest"
$manifestName = "filezilla-$Version.sources.sha256"
$manifestPath = Join-Path $Manifests $manifestName

& (Join-Path $PSScriptRoot 'source-manifest_win64.ps1') -Mode Create -Tree $SourceTree -Manifest $manifestPath

if (Test-Path -LiteralPath $manifestPath) {
    $count = (Get-Content -LiteralPath $manifestPath | Measure-Object -Line).Lines
    Good "$manifestName written ($count files)"
    if ($count -eq 0) { throw 'manifest is empty - the source tree looks wrong' }
}

# --------------------------------------- 2. apply the series to the new upstream

# A fresh work tree per attempt: reusing one across versions would let a stale commit
# or a half-applied hunk from the previous port masquerade as success.
Remove-Item -LiteralPath $WorkTree -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $WorkTree | Out-Null

Step "copying the upstream tree into a scratch work tree"
# Only .git is excluded. An earlier version of this script also excluded *.o, *.exe,
# *.dll and friends to skip in-tree build leftovers, which is wrong here: upstream
# ships data\nsis_appid.dll and data\UAC.dll as real source files, and dropping them
# makes the regenerated manifest silently disagree with the real tree. The extracted
# tree under src\ is clean, and a stale in-tree build is caught by the manifest.
$null = & robocopy $SourceTree $WorkTree /E /XD '.git'
# robocopy exit codes below 8 are success, not failure.
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# Upstream ships no .gitignore, and patch 0003 adds one by extending the baseline,
# so the baseline has to be in place first or git am stops on that commit.
$baselineIgnore = Join-Path $PatchesDir '.gitignore.baseline'
if (Test-Path -LiteralPath $baselineIgnore) {
    Copy-Item -LiteralPath $baselineIgnore -Destination (Join-Path $WorkTree '.gitignore') -Force
}

& $git -C $WorkTree init -q -b baseline
& $git -C $WorkTree config user.email 'port@localhost'
& $git -C $WorkTree config user.name 'port'
# The build sets this too: a CRLF checkout would rewrite .gitignore and two theme.xml
# files and the tree would no longer hash to what the patches expect.
& $git -C $WorkTree config core.autocrlf false

& $git -C $WorkTree add -A
& $git -C $WorkTree commit -q -m "baseline: pristine FileZilla $Version"
$baselineTree = (& $git -C $WorkTree rev-parse 'HEAD^{tree}').Trim()
Step "baseline tree: $baselineTree"

# ------------------------------------------------------------------ apply them

$failed = @()
$applied = 0

foreach ($p in $patchFiles) {
    # -3 does a 3-way merge from the blob hashes in the index lines, so a hunk whose
    # surrounding lines moved still applies. Without it, any context drift is fatal.
    # (There is no --no-edit option on git am; it only exists on git rebase.)
    $null = Invoke-Native -File $git -ArgumentList @('-C', $WorkTree, 'am', '--keep-non-patch', '-3', $p.FullName) -IgnoreExitCode
    if ($LASTEXITCODE -eq 0) {
        $applied++
        Step "applied $($p.Name)"
    }
    else {
        $failed += $p.Name
        Bad "FAILED  $($p.Name)"
        Write-Host ''
        Write-Host '  A hunk did not apply. The usual causes, in order of likelihood:'
        Write-Host '    1. Upstream edited the code this patch touches. Open the conflicts:'
        Write-Host "         git -C `"$WorkTree`" am --show-current-patch=diff"
        Write-Host '    2. Upstream fixed the problem upstream already applies - rebase it away.'
        Write-Host '    3. The patch is no longer needed for this release.'
        Write-Host ''
        Write-Host "  Fix it there, then continue with:"
        Write-Host "    git -C `"$WorkTree`" am --continue   (after git add of the resolved files)"
        Write-Host "    git -C `"$WorkTree`" am --abort      (to give up and start over)"
        Write-Host ''
        # The remaining patches cannot be applied on top of a broken one, so stop here
        # rather than reporting a misleading partial result.
    # Nothing may be mid-application here, so a non-zero exit is expected and
    # ignored rather than aborting the script under Windows PowerShell 5.1.
    $null = Invoke-Native -File $git -ArgumentList @('-C', $WorkTree, 'am', '--abort') -IgnoreExitCode
    break
    }
}

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "  Applied $applied of $($patchFiles.Count) patches; stopped at the first failure."
    Write-Host ''
    Write-Host '  When the series applies again, re-run this script to regenerate the manifest'
    Write-Host '  and read off the new tree hash.'
    Write-Host ''
    if (-not $Keep) {
        Write-Host "  The scratch work tree has been kept for inspection: $WorkTree"
        Write-Host '  (-Keep was not needed - a failed run never deletes it.)'
    }
    # Non-zero, not a bare return. A caller that cannot see the console still has to
    # learn the series did not apply, and "it printed some values" is not that.
    Write-Host ''
    Write-Host '  RESULT: FAILED - the FileZilla series did not apply cleanly.' -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------ 4. the wxWidgets series
#
# Separate from FileZilla because it moves separately. A FileZilla release does not
# touch wxWidgets, so the common case is "nothing to do, and here is the evidence
# that the existing pins still hold" rather than silently leaving two of the four
# pins unmentioned.

Write-Host ''
Write-Host '  ==========================================================================='
Write-Host "   wxWidgets $WxVersion"
Write-Host '  ==========================================================================='

$wxTree = Join-Path $WxRoot 'Makefile.in'
$wxRefused = $false
if (-not (Test-Path -LiteralPath $wxTree)) {
    Warn "wxWidgets sources are not extracted at $WxRoot, so the wxWidgets series was not exercised."
    Warn '  A FileZilla release does not change wxWidgets, so this is expected when you'
    Warn '  are only bumping FileZilla. Its two pins carry over unchanged:'
    Step "  `$WxBaselineTree = '$WxBaselineTree'"
    Step "  `$WxPatchedTree  = '$WxPatchedTree'"
}
elseif (-not $wxRequested -or $wxRequested -eq $WxVersion) {
    Good 'wxWidgets is unchanged by a FileZilla release; both pins carry over.'
    Step "  `$WxBaselineTree = '$WxBaselineTree'"
    Step "  `$WxPatchedTree  = '$WxPatchedTree'"
    Step '  Those still hold unless patches-wx\ itself changed. Prove it with:'
    Step '    powershell -File .\scripts\test-wx-patch_win64.ps1'
}
else {
    # Refuse to re-pin the wrong tree. -Repin does not enforce the pins - that is the
    # point of it during a deliberate bump - so without this check an operator who has
    # not yet extracted the new tarball would get the OLD version's hashes printed
    # under the NEW version's heading, and paste them into versions.ps1. The tree on
    # disk says which version it is; ask it rather than assume.
    $verHeader = Join-Path $WxRoot 'include\wx\version.h'
    $actualWx = ''
    if (Test-Path -LiteralPath $verHeader) {
        $vtext = [System.IO.File]::ReadAllText($verHeader)
        $maj = [regex]::Match($vtext, '#define\s+wxMAJOR_VERSION\s+(\d+)')
        $min = [regex]::Match($vtext, '#define\s+wxMINOR_VERSION\s+(\d+)')
        $rel = [regex]::Match($vtext, '#define\s+wxRELEASE_NUMBER\s+(\d+)')
        if ($maj.Success -and $min.Success -and $rel.Success) {
            $actualWx = "$($maj.Groups[1].Value).$($min.Groups[1].Value).$($rel.Groups[1].Value)"
        }
    }

    if ($actualWx -and $actualWx -ne $wxRequested) {
        $wxRefused = $true
        Bad "the wxWidgets tree at $WxRoot is version $actualWx, not $wxRequested"
        Write-Host ''
        Write-Host '    Re-pinning it would print hashes that belong to the old version, under'
        Write-Host "    the new version's name. Bump `$WxVersion, `$WxFile, `$WxUrl, `$WxSize and"
        Write-Host "    `$WxSha512 in versions.ps1 first, then:"
        Write-Host ''
        Write-Host '      powershell -File .\scripts\fetch-deps_win64.ps1'
        Write-Host '      powershell -File .\scripts\extract-deps_win64.ps1'
        Write-Host "      powershell -File .\scripts\update-version_win64.ps1 -Version $Version -WxVersion $wxRequested"
        Write-Host ''
        Write-Host '    extract-deps verifies the tarball against $WxSha512, which is what makes'
        Write-Host '    the hashes it produces worth pinning.'
    }
    else {
        Step "wxWidgets $WxVersion -> ${wxRequested}: re-applying patches-wx\ to re-pin"
        $applyWx = Join-Path $PSScriptRoot 'apply-wx-patch_win64.ps1'
        $wxOut = @()
        $wxFailed = $false
        try {
            # -Repin reports the two new hashes instead of refusing on them, which is
            # what a deliberate bump looks like. -Tree is $WxRoot, the default, and is
            # passed explicitly so the intent is visible at the call site.
            $wxOut = @(Invoke-NativeLogged -File $applyWx -Splat @{ Tree = $WxRoot; Repin = $true } -PassThru)
        }
        catch {
            $wxFailed = $true
            Bad 'the wxWidgets patch step failed'
            Write-Host ''
            Write-Host '    It is idempotent and refuses rather than guessing, so a failure here is'
            Write-Host '    real. Resolve it in the tree itself:'
            Write-Host "      powershell -File .\scripts\apply-wx-patch_win64.ps1 -Repin"
            Write-Host ''
            Write-Host '    If the new tarball is in place but the tree is still the old one, remove'
            Write-Host "    $WxRoot and re-extract before retrying."
        }
        if (-not $wxFailed) {
            $wxOut | ForEach-Object { Step "  $_" }
            Good 'the new wxWidgets pins are printed above'
        }
    }
}

# ------------------------------------------------------ 5. report the new pins

$finalTree = (& $git -C $WorkTree rev-parse 'HEAD^{tree}').Trim()

Write-Host ''
Write-Host '  ==========================================================================='
Write-Host "   All $($patchFiles.Count) patches applied to FileZilla $Version."
Write-Host '  ==========================================================================='
Write-Host ''
Write-Host '  Patches that applied without a conflict. Upstream may still have moved the'
Write-Host '  code they touch, so read the diff before trusting the result:'
Write-Host ''
Write-Host "    git -C `"$WorkTree`" diff $baselineTree..HEAD --stat"
Write-Host ''
Write-Host '  Now update versions.ps1 by hand. These values are printed here rather than'
Write-Host '  written for you, because versions.ps1 is the audited record of what was'
Write-Host '  verified:'
Write-Host ''
Write-Host "    `$FzVersion       = '$Version'"
Write-Host "    `$FzManifestFile  = `"filezilla-$Version.sources.sha256`"     # already exists"
Write-Host "    `$FzPatchedTree   = '$finalTree'"
Write-Host ''
Write-Host '  Plus these from the new release, which cannot be guessed:'
Write-Host '    $FzSourceFile     the exact filename from the download page'
Write-Host '    $FzSourceSize     byte size of the tarball'
Write-Host '    $FzSourceSha512   SHA-512 of the tarball'
Write-Host ''
if ($wxRequested -and $wxRequested -ne $WxVersion) {
    Write-Host '  wxWidgets is being bumped, so its four pins need the same treatment.'
    Write-Host '  Extract the new tarball to $WxRoot, re-run this script, and paste the'
    Write-Host '  two hashes the wxWidgets phase prints:'
    Write-Host ''
    Write-Host "    `$WxVersion       = '$wxRequested'"
    Write-Host '    $WxFile / $WxUrl / $WxSize / $WxSha512'
    Write-Host "    `$WxBaselineTree = '<printed>'"
    Write-Host "    `$WxPatchedTree  = '<printed>'"
    Write-Host ''
}
else {
    Write-Host '  wxWidgets is unchanged, so its two pins are already right:'
    Write-Host ''
    Write-Host "    `$WxBaselineTree = '$WxBaselineTree'"
    Write-Host "    `$WxPatchedTree  = '$WxPatchedTree'"
    Write-Host ''
}
Write-Host '  Then:'
  Write-Host "    powershell -File .\scripts\source-manifest_win64.ps1 -Mode Verify ``"
Write-Host "         -Tree `$SourceTree -Manifest .\manifests\filezilla-$Version.sources.sha256"
Write-Host "    powershell -File .\scripts\test-powershell-compat_win64.ps1"
Write-Host "    powershell -File .\scripts\test-wx-patch_win64.ps1"
Write-Host ''
Write-Host '  and rebuild from scratch. The tree hash gate at step 6 will refuse to'
Write-Host '  continue until $FzPatchedTree matches what the series produces, and'
Write-Host '  build-wx_win64.ps1 refuses to compile a wxWidgets tree that is not'
Write-Host '  $WxPatchedTree.'
Write-Host ''

if (-not $Keep) {
    Remove-Item -LiteralPath $WorkTree -Recurse -Force -ErrorAction SilentlyContinue
    Step "removed the scratch work tree (pass -Keep to retain it)"
}
else {
    Step "scratch work tree kept at $WorkTree"
}

# A wxWidgets bump that was refused leaves a pin unpinned, so this cannot exit 0
# having silently done less than was asked.
if ($wxRefused) {
    Write-Host ''
    Write-Host '  RESULT: the FileZilla series applied, but the wxWidgets bump did NOT.' -ForegroundColor Red
    Write-Host '  versions.ps1 is only half updated - do not paste anything yet.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  RESULT: every requested pin is printed above and ready to paste.' -ForegroundColor Green
exit 0
