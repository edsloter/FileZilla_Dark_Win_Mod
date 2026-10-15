<#
.SYNOPSIS
    Prepares this repo to build against a new FileZilla release, and reports what is
    still left to do by hand.

.DESCRIPTION
    Two things pin the kit to one specific release and cannot be carried across a
    version bump by editing a number:

      manifests\filezilla-<ver>.sources.sha256
          A per-file SHA-256 manifest of the pristine upstream tree. A new release
          hashes differently, so a 3.71.1 build cannot start until the manifest for
          the new version exists.

      $FzPatchedTree in versions.ps1
          The git tree hash the patch series is known to produce. It changes if
          upstream moves AND if any patch is edited, so it has to be recomputed after
          the series is re-applied.

    This script does both, from the extracted upstream tree, and then tells you what
    still needs a human: whether each patch applied, what changed, and the new pins to
    paste into versions.ps1.

    It deliberately does not rewrite versions.ps1. versions.ps1 is the audited record
    of what was verified, so it should change only when someone has read the diff and
    agreed the new tree is right. This prints the values instead.

.PARAMETER Version
    The new FileZilla version, e.g. 3.72.0. Must match $FzVersion in versions.ps1.

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
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$SourceTree,
    [string]$WorkTree,
    [string]$Root,
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { throw 'git not found on PATH' }

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
    $null = & $git -C $WorkTree am --keep-non-patch -3 $p.FullName 2>&1
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
        & $git -C $WorkTree am --abort 2>$null
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
    return
}

# ------------------------------------------------------ 3. report the new pins

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
Write-Host '  Then:'
Write-Host "    pwsh -File .\scripts\source-manifest_win64.ps1 -Mode Verify ``"
Write-Host "         -Tree `$SourceTree -Manifest .\manifests\filezilla-$Version.sources.sha256"
Write-Host ''
Write-Host '  and rebuild from scratch. The tree hash gate at step 6 will refuse to'
Write-Host '  continue until $FzPatchedTree matches what the series produces.'
Write-Host ''

if (-not $Keep) {
    Remove-Item -LiteralPath $WorkTree -Recurse -Force -ErrorAction SilentlyContinue
    Step "removed the scratch work tree (pass -Keep to retain it)"
}
else {
    Step "scratch work tree kept at $WorkTree"
}
