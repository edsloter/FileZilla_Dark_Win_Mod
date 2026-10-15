<#
.SYNOPSIS
    Builds wxWidgets 3.3.3 for MSW with the MSYS2 UCRT64 toolchain.

.DESCRIPTION
    Why rebuild rather than reuse the earlier C:\mingw64 build:
      FileZilla, libfilezilla and libfzssh are all compiled by the UCRT64
      GCC 16.1.0, so wx must come from the same compiler. Mixing the
      x86_64-ucrt-posix GCC 14.2.0 build with GCC 16 risks libstdc++ ABI
      mismatches.

    Why not use MSYS2's wxwidgets3.3-msw package:
      ucrt64 only ships wxWidgets 3.3.2. FileZilla needs 3.3.3 because
      src/interface/msgbox.cpp uses wxMessageBox, which only became
      dark-mode aware in 3.3.3.

    Why not the MSYS2 'make': the mingw-w64 make package installs itself as
      mingw32-make.exe. Either that or the MSYS2 usr/bin make works; we use
      ucrt64's mingw32-make so the whole build stays inside the UCRT64 toolchain.

    SHELL=C:/Windows/System32/cmd.exe is mandatory. Without it make auto-detects
      MSYS2's sh.exe, which cannot execute wx's CMD-style build recipes, and
      the build dies immediately.

.PARAMETER Jobs
    Parallel make jobs. Defaults to the number of logical processors.

.PARAMETER Keep
    Reuse whatever is already in build\msw instead of cleaning it first, and
    keep the log afterwards. Without it the tree is cleaned before building -
    never wiped, because it holds pristine sources - and the log is removed on
    success. Pass this when a build fails and you want the log, or to make an
    incremental rebuild much faster.
    Skip wiping build\msw. Only safe when rebuilding with the same compiler.
#>
[CmdletBinding()]
param(
    # ~2 GB per g++ instance for wx's monstrous translation units is a safe bound;
    # otherwise cc1plus.exe dies with "out of memory" mid-build on constrained VMs.
    [int]$Jobs = [Math]::Min([Environment]::ProcessorCount, [Math]::Max(1, [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 2GB))),
    # Retain the intermediate build directory and logs. Without it they are removed
    # on the way out, which matters when a build fails and you want to read the log:
    # pass -Keep, or -Keep on the orchestrator, to keep them.
    [Alias('KeepBuildDir')]
    [switch]$Keep,
    # Override the build root, for the log directory only. The wxWidgets source and
    # build directories live under $WxRoot and are not relocatable; see versions.ps1.
    [string]$Root
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Root) { $Root = $BuildRoot }
$wxRoot = $WxRoot
$buildDir = Join-Path $wxRoot 'build\msw'
$ucrt = 'C:\msys64\ucrt64'
$logDir = Join-Path $Root 'logs'

if (-not (Test-Path (Join-Path $wxRoot 'Makefile.in'))) {
    throw "wxWidgets source not found at $wxRoot"
}
if (-not (Test-Path (Join-Path $buildDir 'makefile.gcc'))) {
    throw "makefile.gcc not found in $buildDir"
}
foreach ($t in @('g++.exe', 'mingw32-make.exe', 'gcc.exe', 'windres.exe')) {
    if (-not (Test-Path (Join-Path $ucrt "bin\$t"))) { throw "missing UCRT64 tool: $t" }
}

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# UCRT64 first so gcc/windres/ar/windres all come from one toolchain.
$env:PATH = "$ucrt\bin;$env:PATH"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

if (-not $Keep) {
    # NEVER wipe build\msw wholesale: it holds pristine sources such as
    # makefile.gcc, config.gcc and the vcxproj files.
    #
    # wxWidgets' makefile.gcc has NO distclean target - asking make for it answers
    # "No rule to make target 'distclean'", which is a hard failure. It does have
    # clean, and clean knows the object and library paths better than this script
    # does, so clean is used and its non-zero exit is ignored: it returns 2 on a
    # tree with nothing built, which is not an error here.
    #
    # clean does not cover everything, because it only deletes files that exist.
    # gcc_mswudll\ holds the compiled objects, and lib\gcc_dll holds the generated
    # setup.h and mswu\wx\ headers, so both are removed by name afterwards.
    Write-Host 'Cleaning previous build outputs (keeping makefile.gcc and friends)...'
    Push-Location $buildDir
    try {
        $null = Invoke-Native -File (Join-Path $ucrt 'bin\mingw32-make.exe') `
            -ArgumentList @('-f', 'makefile.gcc', 'clean', 'SHELL=C:/Windows/System32/cmd.exe') `
            -IgnoreExitCode
    }
    finally { Pop-Location }

    # Object and generated-header directories. gcc_mswudll is the one makefile.gcc
    # builds into; the others cover other build flavours so a tree reused after
    # switching settings is not left with a mix.
    foreach ($d in @('gcc_mswudll', 'obj', 'wx', 'lib', 'bin')) {
        $p = Join-Path $buildDir $d
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # lib\gcc_dll and lib\gcc_lib sit beside build\, not under it, and hold the
    # generated setup.h that must not survive a change of compiler or settings.
    foreach ($d in @('lib\gcc_dll', 'lib\gcc_lib')) {
        $p = Join-Path $wxRoot $d
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (-not (Test-Path (Join-Path $buildDir 'makefile.gcc'))) {
        throw "makefile.gcc vanished during clean - aborting. Restore it from wxWidgets-$WxVersion.tar.bz2 (build/msw/)."
    }
}

Write-Host "wxWidgets 3.3.3 / MSW / shared / release"
Write-Host "compiler : $(& (Join-Path $ucrt 'bin\g++.exe') --version | Select-Object -First 1)"
Write-Host "make     : $(& (Join-Path $ucrt 'bin\mingw32-make.exe') --version | Select-Object -First 1)"
Write-Host "jobs     : $Jobs"
Write-Host "log      : $logDir\wx-build.log`n"

# USE_WEBVIEW/USE_MEDIA off: FileZilla needs neither, and webview2 headers are
# not present in ucrt64. The remaining modules (core, base, xml, adv, xrc,
# aui, html, stc, propgrid, ribbon, richtext, gl) are all built.
$args = @(
    '-f', 'makefile.gcc',
    "-j$Jobs",
    'SHELL=C:/Windows/System32/cmd.exe',
    'BUILD=release',
    'DEBUG_FLAG=0',
    'DEBUG_INFO=0',
    'SHARED=1',
    'MONOLITHIC=0',
    'USE_WEBVIEW=0',
    'USE_MEDIA=0'
)

# Precreate the mswu\wx output dir and seed setup.h from its canonical location.
# makefile.gcc has only an `if not exist <dir> mkdir <dir>` guard for
# lib\gcc_dll and immediately asks for ..\..\lib\gcc_dll\mswu\wx\setup.h - with
# no guard for the intermediate directory - so on a pristine C:\wxWidgets-3.3.3
# it errors with "The system cannot find the path specified." and compilation
# cascades with "wx/setup.h: No such file or directory". Copying this file by
# hand makes the make rule's timestamp check pass, so every subsequent invocation
# is a no-op here unless setup.h indeed changes.
$mswuDir   = Join-Path $wxRoot 'lib\gcc_dll\mswu\wx'
New-Item -ItemType Directory -Force -Path $mswuDir | Out-Null
$setupSrc  = Join-Path $wxRoot 'include\wx\msw\setup.h'
$setupDest = Join-Path $mswuDir 'setup.h'
if ((Test-Path -LiteralPath $setupSrc) -and
    (-not (Test-Path -LiteralPath $setupDest) -or
     ((Get-Item -LiteralPath $setupSrc).LastWriteTime -gt (Get-Item -LiteralPath $setupDest).LastWriteTime))) {
    Copy-Item -LiteralPath $setupSrc -Destination $setupDest -Force
}

Push-Location $buildDir
try {
    & (Join-Path $ucrt 'bin\mingw32-make.exe') @args 2>&1 |
        Tee-Object -FilePath (Join-Path $logDir 'wx-build.log')
    $rc = $LASTEXITCODE
}
finally { Pop-Location }

if ($rc -ne 0) {
    Write-Host "`nwxWidgets build FAILED (exit $rc). Tail of log:"
    Get-Content (Join-Path $logDir 'wx-build.log') -Tail 30
    exit $rc
}

# Sanity check the libraries FileZilla actually links (configure.ac:213 asks for
# aui,xrc,adv,core,xml,base).
$libDir = Join-Path $wxRoot 'lib\gcc_dll'
$needed = @(
    'libwxbase33u.a', 'libwxbase33u_xml.a',
    'libwxmsw33u_core.a', 'libwxmsw33u_adv.a',
    'libwxmsw33u_xrc.a', 'libwxmsw33u_aui.a'
)
$missing = @()
foreach ($l in $needed) {
    if (Test-Path (Join-Path $libDir $l)) { Write-Host "  [ok]   $l" }
    else { Write-Host "  [MISS] $l"; $missing += $l }
}
foreach ($d in @('wxbase333u_gcc_custom.dll', 'wxmsw333u_core_gcc_custom.dll', 'wxmsw333u_aui_gcc_custom.dll')) {
    if (Test-Path (Join-Path $libDir $d)) { Write-Host "  [ok]   $d" } else { Write-Host "  [MISS] $d"; $missing += $d }
}

if ($missing.Count) { Write-Host "`nFAILED: $($missing.Count) artefact(s) missing"; exit 1 }

if (-not (Test-Path (Join-Path $libDir 'mswu\wx\setup.h'))) {
    Write-Host "`nFAILED: generated setup.h not found"; exit 1
}

Write-Host "`nwxWidgets 3.3.3 built successfully -> $libDir"

if (-not $Keep) {
    # The build tree itself stays: it is a persistent tool installation under
    # $WxRoot and holds pristine sources, so wiping it would be both slow and
    # destructive. Only the log goes, and only because the build succeeded - a
    # failed run returns before this point, keeping its log for inspection.
    Remove-Item (Join-Path $logDir 'wx-build.log') -Force -ErrorAction SilentlyContinue
}
