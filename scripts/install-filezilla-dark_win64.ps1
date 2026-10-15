<#
.SYNOPSIS
    Builds the pinned FileZilla release from source with system light/dark theme support.

.DESCRIPTION
    One script that takes a machine with nothing installed and ends with a working
    FileZilla, by running the individual build steps in order:

      1. MSYS2 / UCRT64 toolchain
      2. third-party dependencies (gnutls, sqlite, brotli, zstd, argon2, ...)
      3. wxWidgets 3.3.3
      4. libfilezilla and libfzssh
      5. the FileZilla source: verified against a per-file SHA-256 manifest, the
         patch series applied, then configured, built and installed

    Everything lands under a single root, C:\fzdark by default, because the
    existing build scripts have that layout baked in.

    Steps that already completed are detected and skipped, so re-running after a
    failure resumes rather than starting over. Pass -Force to redo a step anyway.

    Source integrity is enforced per file rather than by pinning one tarball hash.
    filezilla-project.org publishes downloads only through short-lived signed
    links, and the archive container has changed between releases, so a pinned
    hash would be unusable; hashing the extracted tree instead proves we compiled
    exactly the files that were audited.

.PARAMETER Root
    Working root for everything this build creates: downloads, sources, dependency
    trees, intermediate build trees, logs, deps\, the installed program and the
    overlay archive. Defaults to the value in versions.ps1. Two locations are fixed
    regardless: the MSYS2/UCRT64 toolchain at C:\msys64, and the wxWidgets source
    tree at $WxRoot, which is built in place because the linker finds its import
    libraries there.

.PARAMETER Keep
    Keep intermediates: downloaded archives, extracted dependency trees, the Meson
    build tree, the build logs and the patched work tree. Without it each step
    removes what it created as soon as it is finished with it. The installed program
    and the overlay archive are outputs and are always kept.

.PARAMETER Tarball
    Source tarball to build from. Omit to look in the cache, then try to scrape a
    signed link from the project site.

.PARAMETER SkipOverlay
    Do not build the drop-in overlay 7z archive at the end.

.PARAMETER Force
    Re-run every step, ignoring what is already present.

.EXAMPLE
    .\install-filezilla-dark_win64.ps1

.EXAMPLE
    .\install-filezilla-dark_win64.ps1 -Tarball D:\dl\FileZilla_3.71.1_src.tar.bz2
#>
[CmdletBinding()]
param(
    # Left empty so it can be defaulted from versions.ps1 after the dot-source;
    # a param default here would run before $BuildRoot exists.
    [string]$Root,
    [string]$Tarball,
    [switch]$SkipOverlay,
    # Skip the 7z archive. The NSIS .exe is the distribution form and is always built; this
    # flag only drops the .7z, which is the manual extract-over-your-installation route.
    #
    # Worth keeping either way: the .7z is the only route that needs nothing installed on the
    # target machine at all, and it ships the PowerShell installer and the licence texts.
    [Alias('NoSevenZipArchive')]
    [switch]$No7z,
    [switch]$Force,
    # Retain intermediates - downloaded archives, extracted dependency trees, the
    # Meson build tree, logs and the work tree. Without it each step removes what it
    # created as soon as the step is done with it, and the orchestrator removes the
    # work tree at the end. The installed program and the overlay archive are outputs
    # and are always kept either way.
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Every pinned version, URL and digest lives in versions.ps1 at the repo root. The
# .sh scripts underneath cannot read a PowerShell file, so this orchestrator exports
# what they need into the environment (see step 8) - that way a release bump is a
# one-file change and the shell scripts never carry a version of their own.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Root) { $Root = $BuildRoot }
$DefaultRoot = $BuildRoot

$Version = $FzVersion
$Scripts = $PSScriptRoot
$Logs = Join-Path $Root 'logs'
$Work = Join-Path $Root "work\filezilla-$Version"
# Its own subdirectory, not src\ itself: extract-deps_win64.ps1 unpacks boost,
# libfilezilla, fzssh and sqlite into that directory, and extracting the FileZilla
# tarball alongside them leaves five top-level directories and no way to tell which
# one is the source root.
$Src = Join-Path $Root 'src\filezilla'
$Install = Join-Path $Root 'install'
# patches/ and manifests/ are siblings of scripts/ in the repo, so resolve them
# relative to the parent rather than assuming they sit next to this file.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Patches = Join-Path $RepoRoot 'patches'
$Manifests = Join-Path $RepoRoot 'manifests'

# The tree the patch series is known to produce. Checked after patching, so a
# silently mis-applied patch cannot turn into a shipped binary.
#
# This hash is specific to the current release AND the current patch series. Bumping
# $FzVersion invalidates it by definition: the new upstream tree hashes differently,
# so expect to re-audit the series and update this value deliberately. The build fails
# loudly rather than quietly accepting an unreviewed tree.
$ExpectedTree = $FzPatchedTree

# Single definition, used by every step that shells out to MSYS2. It used to be
# declared locally inside individual steps, which left step 4 referencing an
# undefined variable - harmless only because step 4 was skipped whenever its
# output already existed, so -Force was the one path that could reach the bug.
$bash = 'C:\msys64\usr\bin\bash.exe'

$script:StepNo = 0

function Banner {
    param([string]$Title)
    $script:StepNo++
    Write-Host ''
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host (" STEP {0}  {1}" -f $script:StepNo, $Title) -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
}

function Info { param([string]$m) Write-Host "   $m" }
function Good { param([string]$m) Write-Host "   $m" -ForegroundColor Green }
function Warn { param([string]$m) Write-Host "   $m" -ForegroundColor Yellow }

function Invoke-Step {
    <#
        Run one build step in a child pwsh process, streaming its output to the
        console and to a log, and stop immediately if it fails.

        A separate process rather than a plain call, because several of these steps
        set environment variables and change directory: done in-process, those would
        leak into later steps and make the run order matter in ways nothing documents.

        ErrorActionPreference=Stop is passed explicitly so a step that throws is
        caught here and reported with its log path, instead of a native exit code
        that PowerShell would otherwise treat as success.
    #>
    param(
        [string]$Script,
        [string[]]$Arguments = @(),
        [string]$LogName
    )

    if (-not (Test-Path -LiteralPath $Script)) { throw "step script not found: $Script" }

    $log = Join-Path $Logs "$LogName.log"
    Info "log: $log"
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }

    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Process -Id $PID).Path }
    if (-not $pwsh) { throw 'could not locate pwsh.exe to run a build step' }

    $argList = @('-NoProfile', '-NonInteractive', '-File', $Script) + $Arguments

    $proc = Start-Process -FilePath $pwsh -ArgumentList $argList -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"

    # Show the user what happened, including a tail of anything on stderr.
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host "   $_" } }

    # Start-Process always creates the .err file, and for a quiet script it is empty,
    # so Get-Content -Raw returns $null. Testing with IsNullOrWhiteSpace rather than
    # .Trim() matters: [string]$null assigned from an if-expression is still $null,
    # and calling a method on it is the "cannot call a method on a null-valued
    # expression" that would otherwise be reported against an unrelated step.
    $errText = ''
    if (Test-Path "$log.err") { $errText = Get-Content "$log.err" -Raw }
    if (-not [string]::IsNullOrWhiteSpace($errText)) {
        Write-Host '   --- stderr ---' -ForegroundColor DarkYellow
        $errText.Trim() -split "`r?`n" | Select-Object -Last 20 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkYellow }
    }

    if ($proc.ExitCode -ne 0) {
        throw "$([System.IO.Path]::GetFileName($Script)) failed with exit code $($proc.ExitCode). Full output: $log"
    }
}

function Test-Toolchain {
    if (-not (Test-Path $bash)) { return $false }
    # Note: -Force deliberately does NOT bypass this. -Force means "rebuild
    # FileZilla", not "reinstall the toolchain" - pacman needs an elevated shell,
    # so forcing it would turn every -Force rebuild into a failure for anyone
    # without admin. The probe below is the real check anyway.
    # A working UCRT64 shell with a compiler is the real test, not a path check.
    $out = & $bash -lc 'export PATH=/ucrt64/bin:/usr/bin:$PATH; g++ --version >/dev/null 2>&1 && echo OK' 2>$null
    return ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq 'OK')
}

function Test-PatchedTree {
    $exe = Join-Path $Install 'bin\filezilla.exe'
    return (Test-Path -LiteralPath $exe) -and -not $Force
}

function Test-Overlay {
      $archive = Join-Path $Root (Join-Path 'out' $OverlayName)
      return (Test-Path -LiteralPath $archive) -and -not $Force
}

Write-Host ''
  Write-Host "FileZilla $Version - build from source with Windows light/dark theme support" -ForegroundColor White
Write-Host "  root: $Root" -ForegroundColor DarkGray

New-Item -ItemType Directory -Force -Path $Root, $Logs | Out-Null

# Arguments every step shares. -Keep is passed down rather than handled here alone:
# an intermediate that one step deletes is often another step's input, so the
# decision has to be uniform from the top. $Root is forwarded for the same reason -
# the scripts default to versions.ps1, but an orchestrator run with an explicit
# -Root must not silently hand its steps a different one.
$stepArgs = @('-Root', $Root)
if ($Keep) { $stepArgs += '-Keep' }

# One memory-aware job count for every compile stage. Two cc1plus failures showed up as
# "out of memory allocating 65536 bytes" as soon as more compilers were resident than
# the VM could back, and the victims were whichever files happened to run at that
# moment rather than the heavy ones. Half of RAM in GB, capped at the core count.
$fzJobs = [Math]::Min([Environment]::ProcessorCount, [Math]::Max(1, [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 2GB)))

# fetch-deps and extract-deps are the one pair that must be told to keep their output
# even when the caller did not ask for it. The archives one downloads are the input to
# the other, so letting either clean up after itself would delete the build's own
# ingredients before they are used. The orchestrator does the removing at the very
# end instead, once nothing else needs them.
$fetchArgs   = @('-Root', $Root, '-Keep')
$extractArgs = @('-Root', $Root, '-Keep')

# What was already cached before this run. Whatever fetch-deps adds on top of this is
# ours to clean up; what was already here is a warm cache belonging to the user and is
# never removed. Recorded as names, not paths, so it survives the run.
$dlDir = Join-Path $Root 'dl'
$dlBefore = @()
if (Test-Path -LiteralPath $dlDir) {
    $dlBefore = @(Get-ChildItem -LiteralPath $dlDir -File -EA SilentlyContinue | ForEach-Object Name)
}

# Trees extract-deps unpacks under src\. wxWidgets is excluded on purpose: it is
# unpacked at the fixed $WxRoot and is effectively a tool installation, not scratch.
$depTrees = @(
    "libfilezilla-$($LibfzVersion)"
    "fzssh-$($FzSshVersion)"
    "boost_$($BoostVersion -replace '\.', '_')"
    "sqlite-amalgamation-$($SqliteVersion)"
)

# Two roots are NOT relocatable, and it is worth saying so once and plainly rather
# than failing later with a linker error:
#   * MSYS2/UCRT64 lives at C:\msys64, the upstream default, and the toolchain
#     shims and build scripts all reference it by that absolute path.
#   * wxWidgets is built in place at $WxRoot (C:\wxWidgets-3.3.3) because
#     build-filezilla_win64.sh puts that tree on PATH to find the import libs.
# Everything else - sources, downloads, intermediate build trees, logs, deps, and
# the final install and overlay - follows -Root.
if ([System.IO.Path]::GetFullPath($Root) -ne [System.IO.Path]::GetFullPath($DefaultRoot)) {
    Warn "using a non-default build root: $Root"
    Warn 'the toolchain at C:\msys64 and wxWidgets at $WxRoot stay where they are'
    if (-not (Test-Path -LiteralPath $WxRoot)) {
        throw "wxWidgets source not found at $WxRoot. -Root moves the build tree, not the wxWidgets source; extract it there or set WxRoot in versions.ps1."
    }
}

# ---------------------------------------------------------------- 1. toolchain

Banner 'MSYS2 / UCRT64 toolchain'
if (Test-Toolchain) {
    Good 'UCRT64 toolchain already present, skipping'
}
else {
    Warn 'installing or repairing the MSYS2 UCRT64 toolchain'
    Invoke-Step -Script (Join-Path $Scripts 'install-toolchain_win64.ps1') -LogName '01-toolchain'
    if (-not (Test-Toolchain)) { throw 'toolchain verification failed after install' }
    Good 'toolchain ready'
}

# ---------------------------------------------------------------- 2. dependencies

Banner 'third-party dependencies'
Invoke-Step -Script (Join-Path $Scripts 'fetch-deps_win64.ps1') -LogName '02-fetch-deps' -Arguments $fetchArgs
Invoke-Step -Script (Join-Path $Scripts 'extract-deps_win64.ps1') -LogName '03-extract-deps' -Arguments $extractArgs
Good 'dependencies staged'

# ---------------------------------------------------------------- 3. wxWidgets

Banner 'wxWidgets 3.3.3'
# wxWidgets is built in place under its own source root and is NOT installed into
# deps\. build-filezilla_win64.sh puts that directory on PATH so the linker finds the
# import libraries, so check the real location rather than deps\bin.
  $wxLibDir = Join-Path $WxRoot 'lib\gcc_dll'
$wxDlls = @(
    'wxbase333u_gcc_custom.dll', 'wxmsw333u_core_gcc_custom.dll',
    'wxmsw333u_aui_gcc_custom.dll', 'wxbase333u_xml_gcc_custom.dll',
    'wxmsw333u_xrc_gcc_custom.dll', 'wxmsw333u_html_gcc_custom.dll'
)
$wxProbe = Join-Path $wxLibDir 'wxbase333u_gcc_custom.dll'
if ((Test-Path -LiteralPath $wxProbe) -and -not $Force) {
    Good "wxWidgets already built ($wxProbe)"
}
else {
    Invoke-Step -Script (Join-Path $Scripts 'build-wx_win64.ps1') -LogName '04-wx' -Arguments $stepArgs
    if (-not (Test-Path -LiteralPath $wxProbe)) { throw "wxWidgets build did not produce $wxProbe" }
    Good 'wxWidgets built'
}

# The overlay ships the xml and html DLLs too. build-wx_win64.ps1 only checks the three
# configure needs, so verify the full set the package depends on.
$wxMissing = @($wxDlls | Where-Object { -not (Test-Path -LiteralPath (Join-Path $wxLibDir $_)) })
if ($wxMissing.Count) {
    throw "wxWidgets build is missing: $($wxMissing -join ', ')"
}
Good "wxWidgets provides all $($wxDlls.Count) DLLs the overlay ships"

# ---------------------------------------------------------------- 4. engine libraries

Banner 'libfilezilla and libfzssh'
# libtool emits either libfilezilla-59.dll or cygfilezilla-59.dll depending on the
# host triple it detects, so look for either spelling.
$lfzBinDir = Join-Path $Root 'deps\bin'
$lfzExisting = Get-ChildItem $lfzBinDir -File -Filter '*filezilla-59.dll' -EA SilentlyContinue | Select-Object -First 1
if ($lfzExisting -and -not $Force) {
    Good 'engine libraries already built'
}
else {
    # .sh has to go through bash explicitly. Windows has no file association for it,
    # so invoking it directly fails with a confusing "not a valid application".
    $lfzScript = Join-Path $Scripts 'build-libfilezilla_win64.sh'
    $lfzLog = Join-Path $Logs '05-libfilezilla.log'
    Info "log: $lfzLog"
    if (Test-Path -LiteralPath $lfzLog) { Remove-Item -LiteralPath $lfzLog -Force }
    $lfzRootMsys = (& $bash -lc "cygpath -u '$Root'").Trim()
    $lfzSrcMsys  = (& $bash -lc "cygpath -u '$Root\src\libfilezilla-$LibfzVersion'").Trim()
    $lfzCmd = "export MSYSTEM=UCRT64; export FZ_ROOT='$lfzRootMsys'; export FZ_LIBFILEZILLA_SRC='$lfzSrcMsys'; export FZ_JOBS='$fzJobs'; bash '$(($lfzScript -replace '\\', '/'))'"
    # Do not use Start-Process here: on native process creation PowerShell does not
    # quote spaced array elements, so "bash -lc <multi-word command>" is delivered
    # as one word per token and bash runs only the first. Same reason step 8 invokes
    # bash through a normal call, whose native-argument quoting is correct.
    & $bash -lc $lfzCmd 2>&1 | Tee-Object -FilePath $lfzLog | Out-Null
    $lfzExit = $LASTEXITCODE
    Get-Content -LiteralPath $lfzLog | ForEach-Object { Write-Host "   $_" }
    if ($lfzExit -ne 0) { throw "build-libfilezilla_win64.sh failed with exit code $lfzExit. See $lfzLog" }

    $lfzDll = Get-ChildItem (Join-Path $Root 'deps\bin') -File -Filter '*filezilla-59.dll' -EA SilentlyContinue | Select-Object -First 1
    if (-not $lfzDll) { throw "libfilezilla build did not produce a filezilla DLL in $(Join-Path $Root 'deps\bin')" }
    $lfz = $lfzDll.FullName
    Invoke-Step -Script (Join-Path $Scripts 'build-fzssh_win64.ps1') -LogName '06-fzssh' -Arguments ($stepArgs + @('-Jobs', $fzJobs))
    if (-not (Test-Path -LiteralPath $lfz)) { throw "libfilezilla build did not produce $lfz" }
    Good 'engine libraries built'
}

# ---------------------------------------------------------------- 5. source

Banner "FileZilla $Version source"
Info 'locating and verifying the upstream source tree'
# 6>&1 merges the information stream: get-filezilla-source_win64.ps1 reports progress with
# Write-Host, which in PS7 goes to the information stream and would otherwise be
# absent from $srcOut entirely, taking the SOURCE_ROOT marker with it.
$srcArgs = @{ Destination = $Src; Root = $Root }
if ($Tarball) { $srcArgs['Tarball'] = $Tarball }
if ($Keep) { $srcArgs['Keep'] = $true }
$srcOut = & (Join-Path $Scripts 'get-filezilla-source_win64.ps1') @srcArgs 6>&1 2>&1 |
    Tee-Object -FilePath (Join-Path $Logs '07-source.log')
$srcOut | ForEach-Object { Write-Host "   $_" }

$marker = $srcOut | ForEach-Object { "$_" } | Where-Object { $_ -match 'SOURCE_ROOT=' } | Select-Object -Last 1
if (-not $marker) { throw 'source acquisition did not report a verified source root; see 07-source.log' }
$sourceRoot = ($marker -split 'SOURCE_ROOT=', 2)[1].Trim()
Good "verified source tree: $sourceRoot"

# ---------------------------------------------------------------- 6. patch

Banner 'apply the patch series'
if (-not (Test-Path $Patches)) { throw "patch directory not found: $Patches" }
$patchFiles = @(Get-ChildItem $Patches -Filter '*.patch' -File | Sort-Object Name)
if ($patchFiles.Count -eq 0) { throw "no patches found in $Patches" }
Info "$($patchFiles.Count) patches: $(($patchFiles.Name) -join ', ')"

$git = (Get-Command git.exe -EA SilentlyContinue).Source
if (-not $git) { $git = 'C:\Program Files\Git\cmd\git.exe' }
if (-not (Test-Path $git)) { throw 'git.exe not found; the patch series is applied with git am' }

# Files autoreconf/gettext regenerate every build. They are tracked in upstream, so
# a completed build always leaves them showing as modified, with only timestamps and
# tool-version differences. Treating that as "someone edited the source" would force
# a full re-patch and rebuild on every single run, which is the opposite of what an
# idempotent installer should do. Anything else that is dirty is a real change.
$ToolRegenerated = @(
    'INSTALL', 'config/config.guess', 'config/config.sub', 'config/ltmain.sh',
    'configure', 'src/fzshellext/configure', 'm4/libtool.m4', 'm4/ltoptions.m4',
    'm4/ltsugar.m4', 'aclocal.m4', 'locales/filezilla.pot'
)

function Get-RealChanges {
    param([string]$TreePath)
    $changed = @()
    foreach ($line in @(& $git -C $TreePath status --porcelain 2>$null)) {
        if ($line.Length -lt 4) { continue }
        $path = $line.Substring(3).Trim().Trim('"')
        # Handle git's rename form "old -> new"; the new path is what matters.
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        if ($ToolRegenerated -contains $path) { continue }
        $changed += $line
    }
    return $changed
}

# Decide whether the work tree has to be (re)built, and do it in one place below.
# An interrupted earlier run leaves a half-patched tree, and treating that as
# "already patched" would either build the wrong thing or skip patching entirely.
# Look at what git actually recorded rather than at the mere existence of the
# directory. Anything not provably clean and committed gets rebuilt.
$needWorkTree = $true
if (Test-Path -LiteralPath $Work) {
    if ($Force) {
        Warn 'removing the existing work tree because -Force was given'
        Remove-Item -LiteralPath $Work -Recurse -Force
    }
    else {
        $head = [string](& $git -C $Work rev-parse --verify -q HEAD 2>$null)
        $realChanges = @(Get-RealChanges -TreePath $Work)
        $midAm = @(& $git -C $Work am --show-current-patch=diff 2>$null).Count

        if (-not $head) {
            Warn 'work tree exists but has no commits; rebuilding it'
            Remove-Item -LiteralPath $Work -Recurse -Force
        }
        elseif ($realChanges.Count -gt 0) {
            Warn "work tree has $($realChanges.Count) uncommitted change(s); rebuilding it from the verified source"
            $realChanges | Select-Object -First 5 | ForEach-Object { Warn "  $_" }
            Remove-Item -LiteralPath $Work -Recurse -Force
        }
        elseif ($midAm -gt 0) {
            # Roll back so the tree can be re-patched cleanly. Resuming a
            # half-applied series is not a state worth trusting.
            Warn 'an interrupted "git am" was found; rolling it back and re-patching'
            & $git -C $Work am --abort
            Remove-Item -LiteralPath $Work -Recurse -Force
        }
        else {
            Info "reusing the already-patched work tree at $Work ($($head.Substring(0, 7)))"
            $needWorkTree = $false
        }
    }
}

if ($needWorkTree) {
    Copy-Item -LiteralPath $sourceRoot -Destination $Work -Recurse

    # Upstream ships no .gitignore. The patch series adds one in its third commit,
    # so the baseline has to contain the exact file that commit expects to extend,
    # or git am fails. It is shipped alongside the patches for that reason.
    $ignore = Join-Path $Patches '.gitignore.baseline'
    if (-not (Test-Path $ignore)) { throw "baseline .gitignore missing: $ignore" }
    Copy-Item -LiteralPath $ignore -Destination (Join-Path $Work '.gitignore') -Force

    & $git -C $Work init -q -b baseline
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }

    # The series was authored with CRLF conversion off. Leaving the machine-wide
    # setting in place rewrites .gitignore and two theme.xml files on checkout, and
    # the tree then no longer matches what the patches expect.
    & $git -C $Work config core.autocrlf false
    & $git -C $Work config user.name 'fzdark build'
    & $git -C $Work config user.email 'build@localhost'

    & $git -C $Work add -A 2>$null
    & $git -C $Work commit -q -m "baseline: verified upstream FileZilla $Version"
    if ($LASTEXITCODE -ne 0) { throw 'baseline commit failed' }
    Good 'baseline committed'

    $amLog = Join-Path $Logs '08-patch.log'
    & $git -C $Work am @($patchFiles.FullName) 2>&1 | Tee-Object -FilePath $amLog
    if ($LASTEXITCODE -ne 0) {
        & $git -C $Work am --abort
        throw "git am failed; the series was rolled back. See $amLog"
    }
    Good 'all patches applied'
}

$tree = (& $git -C $Work rev-parse 'HEAD^{tree}').Trim()
if ($tree -ne $ExpectedTree) {
    throw "patched tree is $tree but the audited tree is $ExpectedTree. Refusing to build from an unexpected source state."
}
Good "patched tree matches the audited tree $tree"

# Same filter as above: on a rerun the tree is reused and already carries autoreconf
# output, so warning about those would fire on every run and mean nothing.
$dirty = @(Get-RealChanges -TreePath $Work)
if ($dirty.Count -gt 0) {
    Warn "$($dirty.Count) uncommitted change(s) in the work tree, which should not happen right after patching:"
    $dirty | Select-Object -First 10 | ForEach-Object { Warn "  $_" }
}

# ---------------------------------------------------------------- 7. icons

Banner 'light-appearance icon variants'
$iconTheme = Join-Path $Work 'src\interface\resources\default'
$iconLog = Join-Path $Logs '09-icons.log'
& (Join-Path $Scripts 'make-dark-icons_win64.ps1') -ThemeDir $iconTheme 2>&1 | Tee-Object -FilePath $iconLog
if ($LASTEXITCODE -ne 0) { throw "icon generation failed; see $iconLog" }

# The patch series already carries the icons as binary blobs, and the audited tree
# hash above pins them. So this is a verification step, not a generation step:
# regenerating and diffing proves the shipped generator still reproduces exactly
# what the series contains, which is what a future maintainer would otherwise have
# to take on trust. Upstream ships 4 further _light files (2 sort arrows, 2 tree
# item glyphs) that this project does not generate, so they are excluded.
$generated = @(
    'auto', 'cancel', 'close', 'disconnect', 'dropdown', 'help', 'leds',
    'processqueue', 'server', 'speedlimits', 'synctransfer', 'upload', 'uploadadd'
)
$iconSizeDir = Join-Path $iconTheme '480x480'

$before = @{}
foreach ($n in $generated) {
    $p = Join-Path $iconSizeDir "${n}_light.png"
    if (-not (Test-Path -LiteralPath $p)) { throw "patch series is missing ${n}_light.png" }
    $before[$n] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
}

& (Join-Path $Scripts 'make-dark-icons_win64.ps1') -ThemeDir $iconTheme -Force 2>&1 |
    Tee-Object -FilePath $iconLog | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icon generation failed; see $iconLog" }

$drifted = @($generated | Where-Object {
    (Get-FileHash -LiteralPath (Join-Path $iconSizeDir "${_}_light.png") -Algorithm SHA256).Hash -ne $before[$_]
})
if ($drifted.Count -gt 0) {
    throw "the icon generator no longer reproduces the icons in the patch series: $($drifted -join ', ')"
}
Good "all $($generated.Count) light icon variants match the patch series byte for byte"

# Regenerating rewrote working-tree files, so restore the audited state before the
# build step runs. The tree hash must describe what actually gets compiled.
& $git -C $Work checkout -- 'src/interface/resources'
$restored = (& $git -C $Work rev-parse 'HEAD^{tree}').Trim()
if ($restored -ne $ExpectedTree) { throw "tree hash drifted to $restored after the icon check" }
Good 'work tree restored to the audited tree'

# ---------------------------------------------------------------- 8. build

Banner 'configure, build and install FileZilla'
$buildLog = Join-Path $Logs '10-build.log'
Info "this is the long step; log: $buildLog"

$buildScript = Join-Path $Scripts 'build-filezilla_win64.sh'
if (-not (Test-Path $bash)) { throw "bash not found at $bash" }

# Paths have to be handed to the shell in MSYS form. cygpath is the reliable way
# to convert, and it matters: a Windows path passed to a script inside MSYS2
# silently resolves to nothing and the build fails far away from the real cause.
$buildScriptMsys = (& $bash -lc "cygpath -u '$buildScript'").Trim()
if (-not $buildScriptMsys) { throw "could not convert $buildScript to an MSYS path" }
Info "build script: $buildScriptMsys"

# Pass the layout in through the environment. build-filezilla_win64.sh reads FZ_ROOT and
# derives everything else, so pointing it at a non-default root is a single setting
# rather than a set of arguments that has to be kept in sync across two languages.
# Versions are passed the same way, so the shell scripts hold no version of their own
# and cannot drift away from versions.ps1.
$rootMsys = (& $bash -lc "cygpath -u '$Root'").Trim()
$srcMsys = (& $bash -lc "cygpath -u '$Work'").Trim()
$prefixMsys = (& $bash -lc "cygpath -u '$Install'").Trim()
$wxPrefixMsys = (& $bash -lc "cygpath -u '$WxRoot'").Trim()
Info "root=$rootMsys  src=$srcMsys  prefix=$prefixMsys  wx=$wxPrefixMsys"

$bashCommand = "export PATH=/ucrt64/bin:/usr/bin:`$PATH" +
    "; export MSYSTEM=UCRT64" +
    "; export FZ_ROOT='$rootMsys'" +
    "; export FZ_SRC='$srcMsys'" +
    "; export FZ_PREFIX='$prefixMsys'" +
    "; export FZ_WX_PREFIX='$wxPrefixMsys'" +
    "; export FZ_JOBS='$fzJobs'" +
    "; export FZ_VERSION='$FzVersion'" +
    "; export FZ_LIBFILEZILLA_VERSION='$LibfzVersion'" +
    "; export FZ_LIBFILEZILLA_SRC='$(& $bash -lc "cygpath -u '$Root\src\libfilezilla-$LibfzVersion'").Trim()'" +
    "; export FZ_FZSSH_SRC='$(& $bash -lc "cygpath -u '$Root\src\fzssh-$FzSshVersion'").Trim()'" +
    "; bash '$buildScriptMsys'"

& $bash -lc $bashCommand 2>&1 | Tee-Object -FilePath $buildLog | Out-Null
if ($LASTEXITCODE -ne 0) { throw "FileZilla build failed; see $buildLog" }

$exe = Join-Path $Install 'bin\filezilla.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "build reported success but $exe is missing" }
Good "built and installed $exe"

# ---------------------------------------------------------------- 9. verify

Banner 'verify the result'
$o = Join-Path $env:TEMP ("fz-{0}.txt" -f [guid]::NewGuid().ToString('n'))
$p = Start-Process -FilePath $exe -ArgumentList '--version' -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $o -RedirectStandardError "$o.err"
$banner = [string]((Get-Content $o -Raw -EA SilentlyContinue) + (Get-Content "$o.err" -Raw -EA SilentlyContinue))
Remove-Item $o, "$o.err" -Force -EA SilentlyContinue

# FileZilla's --version exits nonzero even when it works, so the banner is the test.
if ("$banner".Trim() -notmatch "^FileZilla $Version") {
    throw "the built binary did not report its version; got '$banner'"
}
Good "binary starts and reports: $("$banner".Trim())"

# ---------------------------------------------------------------- 10. overlay

if ($SkipOverlay) {
    Banner 'drop-in overlay (skipped)'
}
else {
    $overlayArgs = @('-InstallDir', $Install, '-OutputDir', (Join-Path $Root 'out'))
    if ($No7z) { $overlayArgs += '-NoArchive' }

    Banner 'stage the overlay payload and build the 7z archive'
    Invoke-Step -Script (Join-Path $Scripts 'build-overlay_win64.ps1') `
        -Arguments $overlayArgs -LogName '11-overlay'

    if ($No7z) {
        Good 'overlay payload staged and verified; the 7z archive was skipped (-NoSevenZipArchive)'
    }
    else {
        $archive = Join-Path $Root (Join-Path 'out' $OverlayName)
        Good ("overlay ready: {0} ({1:N1} MB)" -f $archive, ((Get-Item $archive).Length / 1MB))
    }

    # The distribution form of the overlay: a self-contained installer .exe. Built from the
    # same staged payload the .7z is made from, so the two cannot disagree, and it needs
    # neither 7-Zip nor PowerShell on the machine that installs it.
    Banner 'build the NSIS installer .exe'
    Invoke-Step -Script (Join-Path $Scripts 'get-nsis_win64.ps1') `
        -Arguments @('-Root', $Root) -LogName '12-nsis-toolchain'
    Invoke-Step -Script (Join-Path $Scripts 'build-nsis-installer_win64.ps1') `
        -Arguments @('-StageDir', (Join-Path $Root 'out\stage\overlay'), '-OutputDir', (Join-Path $Root 'out')) `
        -LogName '13-nsis-installer'
    $setupExe = Join-Path $Root (Join-Path 'out' $NsisSetupName)
    Good ("installer ready: {0} ({1:N1} MB)" -f $setupExe, ((Get-Item $setupExe).Length / 1MB))
}

# ---------------------------------------------------------------- done

if ($Keep) {
  Write-Host ''
  Write-Host "Keeping intermediates (-Keep): downloads, extracted trees, logs and $Work"
}
else {
  # The work tree is the big one: a full FileZilla checkout with a patched, built
  # object tree, typically hundreds of megabytes. Nothing after this point reads it.
  # Removed last so a failure earlier leaves it intact for diagnosis.
  if (Test-Path -LiteralPath $Work) {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
  # Collapse the emptied work\ parent too, otherwise every run leaves one empty shell.
  $workParent = Split-Path -Parent -Path $Work
  if ((Test-Path -LiteralPath $workParent) -and `
      -not (Get-ChildItem -LiteralPath $workParent -Force -EA SilentlyContinue)) {
    Remove-Item -LiteralPath $workParent -Force -EA SilentlyContinue
  }
  Write-Host ''
  Write-Host "Removed the intermediate work tree $Work (pass -Keep to retain it)."

  }

  # Now that the build is finished, the dependency trees have no further consumer.
  # $WxRoot is left alone: it is a tool installation at a fixed path, not scratch.
  $removedTrees = 0
  foreach ($t in $depTrees) {
    $p = Join-Path (Join-Path $Root 'src') $t
    if (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
      $removedTrees++
    }
  }
  if ($removedTrees) {
    Write-Host "Removed $removedTrees extracted dependency tree(s) from $(Join-Path $Root 'src')."
  }

  # Only archives this run fetched. Anything already cached when the build started is
  # left alone: a warm cache is the user's, it took 180 MB to populate, and throwing
  # it away would mean re-downloading all of it on the next build for no benefit.
  $fetched = @()
  if (Test-Path -LiteralPath $dlDir) {
    $fetched = @(Get-ChildItem -LiteralPath $dlDir -File -EA SilentlyContinue |
        Where-Object { $_.Name -notin $dlBefore })
  }
  foreach ($f in $fetched) {
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
  }
  if ($fetched) {
    Write-Host "Removed $($fetched.Count) archive(s) this build fetched into $(Split-Path -Leaf $dlDir)\."
  }
  Write-Host 'Pass -Keep to keep them, or pre-seed the cache with -Keep once to avoid re-downloading.'
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host ''
Write-Host "  FileZilla:   $exe"
Write-Host "  Install tree: $Install"
  if (-not $SkipOverlay) {
  if (-not $No7z) { Write-Host "  Overlay 7z:  $(Join-Path $Root (Join-Path 'out' $OverlayName))" }
  Write-Host "  Installer:   $(Join-Path $Root (Join-Path 'out' $NsisSetupName))"
}
Write-Host "  Logs:        $Logs"
Write-Host ''
Write-Host 'FileZilla now follows your Windows light/dark setting by default. To pin it to' -ForegroundColor DarkGray
Write-Host 'one appearance, turn it off in Settings > Interface > "Follow the system' -ForegroundColor DarkGray
Write-Host 'light and dark theme".' -ForegroundColor DarkGray
Write-Host ''
