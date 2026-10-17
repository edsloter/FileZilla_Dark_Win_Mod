<#
.SYNOPSIS
    Proves the wxWidgets patch series applies to the pristine baseline and produces
    exactly the audited tree, and that it cannot be applied twice.

.DESCRIPTION
    FileZilla's series has a test that exercises it end to end. wxWidgets' did not,
    and that is the gap this fills: $WxPatchedTree is checked on every build, but
    nothing checked that the series still APPLIES. A wxWidgets release that moved
    the code patch 0001 touches would fail the tree hash on the build machine, hours
    into a build, instead of here in a second.

    What it checks, in order:

      1. versions.ps1 pins both $WxBaselineTree and $WxPatchedTree, each a 40-character
         lowercase hex tree hash, and that they differ - a series that changes nothing
         is a series that will not fix anything.
      2. patches-wx\ holds at least one .patch and the .gitignore.baseline the first
         run copies into the tree.
      3. $WxRoot is a git repository whose 'wx-baseline' tag hashes to $WxBaselineTree.
      4. A scratch work tree cut at that tag is pristine, and apply-wx-patch_win64.ps1
         takes it to exactly $WxPatchedTree - so the series applies to the real
         baseline and produces the pinned result.
      5. Running the patch step again changes nothing. This is the double-patch guard,
         and it is the one that matters day to day.
      6. A tree that has already been patched and had its .git deleted is REFUSED
         rather than adopted as its own pristine baseline.
      7. The result carries no .orig or .rej, so a 3-way merge that half-succeeded did
         not slip through unnoticed.

    Checks 3 to 7 need an extracted and patched $WxRoot. Without one they are reported
    as SKIPPED with the reason, never as passed, so this can sit in the pre-commit
    suite on a machine that has not built wxWidgets yet without reporting a false green.

    The work tree is a linked git work tree of $WxRoot, so cutting it costs one
    checkout of the sources rather than a copy, and it cannot disturb the tree a
    build reads from. -Tree is what apply-wx-patch_win64.ps1 takes for exactly this.

.PARAMETER Keep
    Leave the scratch work tree in place instead of removing it, and print where.

.EXAMPLE
    powershell -File .\scripts\test-wx-patch_win64.ps1
#>
[CmdletBinding()]
param(
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$patchesDir = Join-Path $repoRoot 'patches-wx'
$applyScript = Join-Path $PSScriptRoot 'apply-wx-patch_win64.ps1'

# Assigned first, never as (Get-Command ...).Source: under Set-StrictMode reading a
# property on the $null that Get-Command returns throws, so the fallback below would
# never be reached.
$gitCmd = Get-Command git.exe -ErrorAction SilentlyContinue
$git = if ($gitCmd) { $gitCmd.Source } else { $null }
if (-not $git) { $git = 'C:\Program Files\Git\cmd\git.exe' }

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Ok   { param([string]$m) Write-Host "  PASS  $m" -ForegroundColor Green;  $script:Pass++ }
function No   { param([string]$m) Write-Host "  FAIL  $m" -ForegroundColor Red;    $script:Fail++ }
function Skip { param([string]$m) Write-Host "  SKIP  $m" -ForegroundColor Yellow; $script:Skip++ }

function Section { param([string]$Title) Write-Host ''; Write-Host "$Title" }

function Test-TreeHash {
    param([string]$Value, [string]$Label)
    if ($Value -match '^[0-9a-f]{40}$') { return $true }
    No "$Label is not a 40-character lowercase hex tree hash: '$Value'"
    return $false
}

# Run the patch step and report whether it succeeded, rather than letting a failure
# abort the suite. Deliberately not $LASTEXITCODE: the target is a PowerShell script,
# which does not set it, and a throw from it arrives here as a terminating error.
function Invoke-PatchStep {
    param([string]$Tree, [switch]$Repin)

    $call = @{ Tree = $Tree }
    if ($Repin) { $call['Repin'] = $true }
    try {
        $out = & $applyScript @call *>&1
        return @{ Ok = $true; Out = @($out | ForEach-Object { "$_" }) }
    }
    catch {
        return @{ Ok = $false; Out = @(("$($_.Exception.Message)" -split "`r?`n") | Where-Object { $_.Trim() }) }
    }
}

Write-Host ''
Write-Host "wxWidgets $WxVersion patch series" -ForegroundColor White
Write-Host "  root: $WxRoot" -ForegroundColor DarkGray

# ------------------------------------------------------- 1. the pins are sane

Section '1. versions.ps1 pins both trees'
if (-not (Test-Path $applyScript)) { throw "not found: $applyScript" }

$baselineOk = Test-TreeHash -Value $WxBaselineTree -Label '$WxBaselineTree'
$patchedOk  = Test-TreeHash -Value $WxPatchedTree  -Label '$WxPatchedTree'
if ($baselineOk) { Ok '$WxBaselineTree is a well-formed tree hash' }
if ($patchedOk)  { Ok '$WxPatchedTree is a well-formed tree hash' }

if ($baselineOk -and $patchedOk) {
    if ($WxBaselineTree -eq $WxPatchedTree) {
        No 'the series produces the same tree it started from, so it changes nothing'
    }
    else {
        Ok 'the series changes the tree, and the two pins differ'
    }
}

# ------------------------------------------------- 2. the series is actually here

Section '2. patches-wx\ holds a series'
$patches = @(Get-ChildItem -LiteralPath $patchesDir -Filter '*.patch' -File -EA SilentlyContinue | Sort-Object Name)
if ($patches.Count -eq 0) { No "no .patch files in $patchesDir" }
else { Ok "$($patches.Count) patch(es): $(($patches.Name) -join ', ')" }

if (Test-Path -LiteralPath (Join-Path $patchesDir '.gitignore.baseline')) { Ok '.gitignore.baseline is present' }
else { No '.gitignore.baseline is missing; the first run copies it into the tree' }

# ------------------------------------------ 3. the real tree carries the baseline

Section "3. $WxRoot carries the pristine baseline"
$needTree = $false
$why = ''

if (-not (Test-Path -LiteralPath $git)) {
    $why = 'git.exe not found'
}
elseif (-not (Test-Path -LiteralPath (Join-Path $WxRoot 'Makefile.in'))) {
    $why = "wxWidgets sources not extracted at $WxRoot"
}
elseif (-not (Test-Path -LiteralPath (Join-Path $WxRoot '.git'))) {
    $why = "$WxRoot is not a git repository yet - run apply-wx-patch_win64.ps1"
}
else { $needTree = $true }

if (-not $needTree) {
    foreach ($n in 4, 5, 6, 7) { Skip "check $n needs an extracted and patched $WxRoot ($why)" }
    Write-Host ''
    Write-Host "RESULT: pins and series OK; 4 tree checks SKIPPED - $why" -ForegroundColor Yellow
    exit 0
}

$tagHash = [string](Invoke-Native -File $git -ArgumentList @('-C', $WxRoot, 'rev-parse', '--verify', '-q', "refs/tags/wx-baseline^{tree}") -IgnoreExitCode)
$tagHash = $tagHash.Trim()
if ($tagHash -eq $WxBaselineTree) { Ok 'the wx-baseline tag hashes to $WxBaselineTree' }
else { No "the wx-baseline tag hashes to '$tagHash' but the pin is '$WxBaselineTree'" }

# --------------------------------- 4-7. a scratch tree, cut at the baseline

$scratch = Join-Path $env:TEMP ("wxpatch-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
$linked = $false

try {
    Section '4. the series applies to the pristine baseline'
    $null = Invoke-Native -File $git -ArgumentList @('-C', $WxRoot, 'worktree', 'add', '--detach', '-q', $scratch, 'wx-baseline')
    if ($LASTEXITCODE -ne 0) {
        No "could not cut a work tree at wx-baseline into $scratch"
        foreach ($n in 5, 6, 7) { Skip "check $n needs the scratch work tree" }
    }
    else {
        $linked = $true
        $cutHash = ([string](Invoke-Native -File $git -ArgumentList @('-C', $scratch, 'rev-parse', 'HEAD^{tree}') -IgnoreExitCode)).Trim()
        if ($cutHash -eq $WxBaselineTree) { Ok "the scratch tree is pristine (tree $cutHash)" }
        else { No "the scratch tree hashes to '$cutHash', expected '$WxBaselineTree'" }

        $first = Invoke-PatchStep -Tree $scratch
        if (-not $first.Ok) {
            No 'the patch step refused a pristine tree'
            $first.Out | Select-Object -First 8 | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
            foreach ($n in 5, 6, 7) { Skip "check $n could not run; the tree was not patched" }
        }
        else {
            $after = ([string](Invoke-Native -File $git -ArgumentList @('-C', $scratch, 'rev-parse', 'HEAD^{tree}') -IgnoreExitCode)).Trim()
            if ($after -eq $WxPatchedTree) { Ok ('applying the series produced $WxPatchedTree ({0})' -f $after) }
            else { No "the series produced tree '$after', expected '$WxPatchedTree'" }

            Section '5. a second run changes nothing (double-patch guard)'
            $second = Invoke-PatchStep -Tree $scratch
            if (-not $second.Ok) {
                No 'the patch step failed on an already-patched tree'
                $second.Out | Select-Object -First 8 | ForEach-Object { Write-Host "        $_" -ForegroundColor Red }
            }
            else {
                $again = ([string](Invoke-Native -File $git -ArgumentList @('-C', $scratch, 'rev-parse', 'HEAD^{tree}') -IgnoreExitCode)).Trim()
                if ($again -eq $WxPatchedTree) { Ok ('the tree is unchanged and still $WxPatchedTree ({0})' -f $again) }
                else { No "the second run moved the tree to '$again'" }
                $saidNothingToDo = @($second.Out | Where-Object { $_ -match 'already patched' }).Count -gt 0
                if ($saidNothingToDo) { Ok 'and it said so rather than re-applying' }
                else { No 'and it did NOT report the tree as already patched' }
            }

            Section '6. the patched result carries no merge leftovers'
            # A 3-way merge that half-succeeded can leave .orig or .rej behind and
            # still produce a tree, so this is checked rather than assumed.
            # -File is required here. Get-ChildItem -Recurse -Include without a wildcard in the
            # path does not filter what it returns, it filters the final component, so
            # every directory in the tree comes back too - 10440 of them last run.
            $leftovers = @(Get-ChildItem -LiteralPath $scratch -Recurse -Force -File -EA SilentlyContinue |
                Where-Object { $_.Name -like '*.orig' -or $_.Name -like '*.rej' })
            if ($leftovers.Count -eq 0) { Ok 'no .orig or .rej anywhere in the patched tree' }
            else {
                No "$($leftovers.Count) merge leftover(s) in the patched tree"
                $leftovers | Select-Object -First 5 | ForEach-Object { Write-Host "        $($_.FullName)" -ForegroundColor Red }
            }

            Section '7. an already-patched tree with .git removed is refused'
            # Exactly what deleting the .git leaves behind, and the case the baseline
            # pin exists for: without it the run adopts the patched sources as its own
            # "pristine" baseline, and the series is then applied on top of itself.
            #
            # A linked work tree's .git is a FILE, so removing it leaves a plain
            # directory holding the patched sources and no history - the exact state
            # to test, and it costs nothing to produce.
            Remove-Item -LiteralPath (Join-Path $scratch '.git') -Force -EA SilentlyContinue
            $linked = $false

            $refused = Invoke-PatchStep -Tree $scratch
            if ($refused.Ok) {
                No 'the patch step ACCEPTED an already-patched tree with no .git'
            }
            else {
                Ok 'the patch step refused it'
                if (@($refused.Out | Where-Object { $_ -match 'not a pristine' }).Count -gt 0) { Ok 'and said the tree is not pristine, rather than failing bare' }
                else { No 'but did not say the tree was not pristine' }
                if (@($refused.Out | Where-Object { $_ -match 'Remove-Item' }).Count -gt 0) { Ok 'and named the recovery' }
                else { Skip 'but did not name a recovery' }
            }
        }
    }
}
finally {
    # --expire now, and it matters. Plain `worktree prune` only drops registrations whose
    # administrative files are older than gc.worktreePruneExpire - three months by default -
    # so pruning before removing the directory does nothing at all, and the suite leaves a
    # "prunable" entry behind that the next `worktree add` then trips over. Removing the
    # directory first and pruning after, with everything expired, is the order that works.
    if (-not $Keep) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -EA SilentlyContinue
    }
    $null = Invoke-Native -File $git -ArgumentList @('-C', $WxRoot, 'worktree', 'prune', '--expire', 'now') -IgnoreExitCode
}

Write-Host ''
Write-Host "  $script:Pass passed, $script:Fail failed, $script:Skip skipped"
if ($script:Fail -gt 0) {
    if ($Keep) { Write-Host "scratch tree kept at $scratch" -ForegroundColor DarkGray }
    Write-Host 'RESULT: FAILED' -ForegroundColor Red
    exit 1
}
if ($Keep -and (Test-Path -LiteralPath $scratch)) {
    Write-Host "scratch tree kept at $scratch" -ForegroundColor DarkGray
}
Write-Host 'RESULT: the wxWidgets patch series applies cleanly and is idempotent' -ForegroundColor Green
exit 0