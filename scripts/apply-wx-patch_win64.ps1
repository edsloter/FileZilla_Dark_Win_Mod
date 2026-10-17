<#
.SYNOPSIS
    Applies the wxWidgets patch series to $WxRoot, in place, and verifies the result.

.DESCRIPTION
    wxWidgets is patched HERE, at $WxRoot, rather than in a copy the way FileZilla
    is. There is no choice to make: build\msw\makefile.gcc and the generated
    setup.h under lib\gcc_dll\mswu resolve everything relative to the source root
    they sit in, and build-filezilla_win64.sh links against import libraries from
    that same lib\gcc_dll. A copy at a different path would build a wxWidgets that
    FileZilla could not link to.

    So this turns the unpacked tree into a git repository in place - one baseline
    commit of the pristine sources, then the series on top, exactly as
    install-filezilla-dark_win64.ps1 does for FileZilla. The tarball is pinned by
    SHA-512 in versions.ps1, so the baseline is reproducible and can be compared
    against a known tree hash.

    Idempotent, in every state it can find the tree in:

      no .git at all          initialise, baseline, apply
      series already applied  verify the tree hash and report, change nothing
      git am interrupted      roll it back, then apply
      -Reset given            discard local edits, return to the pristine baseline
                              commit tagged wx-baseline, apply again

    A tree whose HEAD matches neither the baseline nor the audited patched tree is
    refused rather than guessed at, because that is what a half-applied or
    differently-patched series looks like.

.PARAMETER Reset
    Discard whatever is in the worktree and re-apply the series from the pristine
    baseline commit. Use this after re-extracting the tarball over $WxRoot, or
    after hand-editing wx sources, when the result is a tree the normal checks
    refuse. It cannot lose anything the pinned tarball does not already contain.

.PARAMETER Tree
    Patch this wxWidgets tree instead of the one in versions.ps1. Only the patch
    step moves; the pins still come from versions.ps1, so this is for working on a
    copy - the test suite uses it to prove the series applies to the pristine
    baseline without touching the tree a build reads from.

    Not named -WxRoot: versions.ps1 already owns that name and PowerShell variable
    names are case-insensitive, so a parameter of that name would be overwritten by
    the dot-source and the override would never apply.

.PARAMETER Repin
    For a new wxWidgets release. Applies the series and PRINTS the baseline and
    patched tree hashes instead of refusing when they differ from the pinned ones,
    which is what a deliberate wxWidgets bump looks like. The printed values are the
    ones to paste into $WxBaselineTree and $WxPatchedTree. Nothing is enforced in
    this mode, so it proves nothing about a build - it is for regenerating pins, and
    update-version_win64.ps1 uses it. The hashes it prints are only trustworthy if
    the tarball they came from was verified against $WxSha512.
#>
[CmdletBinding()]
param(
    [Alias('Force')]
    [switch]$Reset,

    [string]$Tree,

    [Alias('RepinTree')]
    [switch]$Repin
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

# patches-wx\ is a sibling of scripts\, so resolve it from this script's own
# location. The repo is relocatable and nothing here may assume C:\fzdark.
$patches = Join-Path (Split-Path -Parent $PSScriptRoot) 'patches-wx'

# Deliberately not called -WxRoot. versions.ps1 already owns $WxRoot and the
# dot-source below sets it, and PowerShell variable names are case-insensitive, so
# a parameter of that name would be silently overwritten and the override would
# never take effect. The default has to be read after the dot-source, not in the
# param block, which runs before it.
$wxRoot = if ($Tree) { $Tree } else { $WxRoot }

# Resolve git in two steps, never as (Get-Command ...).Source.
#
# Under Set-StrictMode reading a property on $null throws, and Get-Command
# returns $null whenever git.exe is not on PATH - which is the normal state in a
# terminal opened before the bootstrap installed Git, because bootstrap's PATH
# fix applies to its own process and its children only. Assigning first and
# testing the result is what keeps the fallback reachable.
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
$git = if ($gitCmd) { $gitCmd.Source } else { $null }
if (-not $git) { $git = 'C:\Program Files\Git\cmd\git.exe' }
if (-not (Test-Path -LiteralPath $git)) { throw 'git.exe not found; the wxWidgets patch series is applied with git am' }

if (-not (Test-Path -LiteralPath (Join-Path $wxRoot 'Makefile.in'))) {
    throw "wxWidgets sources not found at $wxRoot - run extract-deps_win64.ps1, or bootstrap_win64.ps1 -ThenBuild, first"
}

$patchFiles = @(Get-ChildItem -LiteralPath $patches -Filter '*.patch' -File | Sort-Object Name)
if ($patchFiles.Count -eq 0) { throw "no patches found in $patches" }

# The tag naming the pristine baseline. Created when this script first runs, and
# what -Reset returns to. Named so that a reader of `git tag` in $WxRoot can see
# what it is for.
$baselineTag = 'wx-baseline'

function Get-TreeHash {
    <#
        The tree hash of a commit-ish, or '' if the ref does not resolve.
        '^{tree}' is appended because rev-parse on a commit otherwise answers with
        the commit id, and the commit id is not what $WxPatchedTree pins.
    #>
    param([string]$Treeish)

    $out = @(Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'rev-parse', "$Treeish^{tree}") -IgnoreExitCode)
    if ($out.Count -eq 0) { return '' }
    return ([string]$out[0]).Trim()
}

function Get-BaselineCommit {
    <#
        The commit holding the pristine wxWidgets sources, or '' if there is none.

        Normally the tag written at initialisation. A tree git-initialised before
        this script existed has no such tag, so the baseline is found by its commit
        subject instead - the only commit in the history whose message says
        "baseline:" - and the tag is written then, so every later run is a plain
        ref lookup.
    #>
    $tagged = @(Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'rev-parse', "--verify", "-q", "refs/tags/$baselineTag") -IgnoreExitCode)
    if ($tagged.Count -gt 0) { return ([string]$tagged[0]).Trim() }

    $found = @(Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'log', '--format=%H', '--grep=^baseline:', '-1') -IgnoreExitCode)
    if ($found.Count -eq 0) { return '' }

    $commit = ([string]$found[0]).Trim()
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'tag', $baselineTag, $commit) -IgnoreExitCode
    return $commit
}

Write-Host ''
Write-Host "wxWidgets $WxVersion patch series"
Write-Host "  root   : $wxRoot"
Write-Host "  patches: $($patchFiles.Name -join ', ')"
Write-Host ''

$repo = Join-Path $wxRoot '.git'

if ($Reset -and (Test-Path -LiteralPath $repo)) {
    $baselineCommit = Get-BaselineCommit
    if (-not $baselineCommit) {
        throw "no pristine baseline commit found in $wxRoot, so there is nothing to reset to. Delete $wxRoot, re-extract the tarball with extract-deps_win64.ps1 and run this again."
    }
    Write-Host "Resetting $wxRoot to the pristine baseline commit $baselineCommit..."
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'reset', '--hard', $baselineCommit)
    if ($LASTEXITCODE -ne 0) { throw 'git reset --hard failed' }
}

if (-not (Test-Path -LiteralPath $repo)) {
    # First run. The .gitignore goes in BEFORE the first add -A so that the
    # baseline commit is the sources and not the objects left behind by an
    # earlier build, which is what makes $WxPatchedTree a stable hash.
    $ignore = Join-Path $patches '.gitignore.baseline'
    if (-not (Test-Path -LiteralPath $ignore)) { throw "baseline .gitignore missing: $ignore" }
    Copy-Item -LiteralPath $ignore -Destination (Join-Path $wxRoot '.gitignore') -Force

    Write-Host 'Initialising the wxWidgets work tree...'
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'init', '-q', '-b', 'baseline')
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }

    # autocrlf must be off for the same reason it is on the FileZilla work tree:
    # the series was authored with LF and a machine-wide true rewrites files on
    # checkout, after which the tree no longer hashes to the pinned value.
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'config', 'core.autocrlf', 'false')
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'config', 'user.name', 'fzdark build')
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'config', 'user.email', 'build@localhost')

    Write-Host 'Committing the pristine sources as the baseline...'
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'add', '-A')
    if ($LASTEXITCODE -ne 0) { throw 'git add -A failed while creating the wxWidgets baseline' }
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'commit', '-q', '-m', "baseline: pristine wxWidgets $WxVersion release tarball")
    if ($LASTEXITCODE -ne 0) { throw 'the wxWidgets baseline commit failed' }
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'tag', $baselineTag)
    Write-Host "  baseline committed and tagged '$baselineTag'"
}

# The baseline must hash to $WxBaselineTree, checked on every run and not only after
# it is created. This is what stands in for the per-file manifest FileZilla has:
# $WxSha512 verified the tarball once, at fetch, and after that whatever is on disk
# is what gets built, so without this a tree that was already patched - or edited by
# hand before the first run - would be adopted as "pristine" and the series applied on
# top of it, and the wrong answer would look like success.
$baselineCommit = Get-BaselineCommit
if (-not $baselineCommit) {
    throw "no pristine baseline commit found in $wxRoot. Delete $wxRoot, re-extract the tarball with extract-deps_win64.ps1 and run this again."
}
$baselineTree = Get-TreeHash -Treeish $baselineCommit
if (-not $baselineTree) { throw "commit $baselineCommit does not resolve to a tree; the repository at $wxRoot is damaged" }

if ($baselineTree -ne $WxBaselineTree) {
    if ($Repin) {
        Write-Host "  baseline tree is $baselineTree (was pinned to $WxBaselineTree)"
    }
    else {
        throw @"
$wxRoot is not a pristine wxWidgets $WxVersion tree.
  baseline commit : $baselineCommit
  baseline tree   : $baselineTree
  pinned          : $WxBaselineTree

The usual cause is that this tree has already been patched and its .git was deleted,
so the first run adopted the patched sources as the baseline. The series cannot be
applied on top of itself, and the result would not be the audited tree.

Recover with:
  Remove-Item '$wxRoot' -Recurse -Force
  powershell -File .\scripts\extract-deps_win64.ps1
  powershell -File .\scripts\apply-wx-patch_win64.ps1

For a deliberate wxWidgets release bump, use -Repin and paste the printed hashes into
versions.ps1 - but only if the tarball was verified against `$WxSha512.
"@
    }
}

# Anything dirty means a file was edited, or the tarball was re-extracted over
# the top. Either way the tree is no longer the one the series applies to, and
# building it would ship whatever is there rather than the audited sources.
$dirty = @(Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'status', '--porcelain') -IgnoreExitCode)
if ($dirty.Count -gt 0) {
    $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    if ($dirty.Count -gt 10) { Write-Host "  ... and $($dirty.Count - 10) more" }
    throw "$wxRoot has $($dirty.Count) uncommitted change(s). Re-run with -Reset to return to the pristine baseline and re-apply the series."
}

# An interrupted git am leaves the tree part-patched. Resuming it is not a state
# worth trusting, so roll it back and start the series again.
$midAm = @(Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'am', '--show-current-patch=diff') -IgnoreExitCode).Count
if ($midAm -gt 0) {
    Write-Host 'An interrupted "git am" was found; rolling it back and re-applying.'
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'am', '--abort') -IgnoreExitCode
}

$tree = Get-TreeHash -Treeish 'HEAD'

if ($tree -eq $WxPatchedTree) {
    Write-Host "wxWidgets sources are already patched (tree $tree). Nothing to do."
    if ($Repin) {
        Write-Host "  `$WxBaselineTree = '$baselineTree'"
        Write-Host "  `$WxPatchedTree  = '$tree'"
    }
    return
}

if ($tree -ne $baselineTree) {
    throw "wxWidgets sources are at tree $tree, which is neither the pristine baseline ($baselineTree) nor the audited patched tree ($WxPatchedTree). Refusing to apply the series over an unexpected source state - re-run with -Reset."
}

Write-Host 'Applying the patch series...'
$null = Invoke-Native -File $git -ArgumentList (@('-C', $wxRoot, 'am') + $patchFiles.FullName)
if ($LASTEXITCODE -ne 0) {
    $null = Invoke-Native -File $git -ArgumentList @('-C', $wxRoot, 'am', '--abort') -IgnoreExitCode
    throw "git am failed and the series was rolled back. Apply it by hand in $wxRoot and read the error there."
}

$tree = Get-TreeHash -Treeish 'HEAD'

# Report before enforcing, so a -Repin run has its output even when the tree does
# not match the pin - which is the normal case during a release bump.
Write-Host "  baseline tree : $baselineTree"
Write-Host "  patched tree  : $tree"

if ($tree -eq $WxPatchedTree) {
    Write-Host "wxWidgets sources patched; tree $tree matches the audited tree."
    return
}

if ($Repin) {
    Write-Host ''
    Write-Host '  -Repin was given, so the mismatch above was not enforced. Paste these'
    Write-Host '  into versions.ps1 only after reading the diff, and only if the tarball'
    Write-Host '  they came from matched the pinned SHA-512:'
    Write-Host ''
    Write-Host "    `$WxBaselineTree = '$baselineTree'"
    Write-Host "    `$WxPatchedTree  = '$tree'"
    return
}

throw "patched tree is $tree but the audited tree is $WxPatchedTree. Refusing to build from an unexpected source state."