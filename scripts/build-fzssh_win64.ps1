<#
.SYNOPSIS
    Builds and installs libfzssh-client into <root>\deps with Meson. Version from versions.ps1.

.DESCRIPTION
    fzssh is a Meson project - unlike libfilezilla there is no autotools
    `configure` in the tarball - so Meson plus Ninja are mandatory.

    Dependencies (meson.build:12-17), all from the MSYS2 UCRT64 packages:
      libfilezilla (minimum pinned in versions.ps1)  our own build in <root>\deps
      nettle/hogweed >= 3.10  ucrt64 ships 4.0
      gmp >= 6.2              ucrt64 ships 6.3.0
      libargon2               mingw-w64-ucrt-x86_64-argon2

    Unlike libfilezilla, this runs entirely from PowerShell rather than the MSYS2
    shell: meson.exe and ninja.exe are native Windows binaries, so POSIX path
    translation only adds a way for things to go wrong. C:\msys64\usr\bin is kept
    at the END of PATH as a fallback, purely so Meson can find sh for compiler
    sanity checks.

    with_server defaults to false and stays that way - it is only available under
    a proprietary licence.
#>
[CmdletBinding()]
param(
    # Discard any existing Meson build directory and configure from scratch.
    [switch]$Wipe,
    # Retain the intermediate Meson build directory and logs. Without it they are
    # removed on the way out; the installed prefix under deps\ is the output and is
    # always kept.
    [switch]$Keep,
    # Override the build root for src\, build\ and deps\. Left empty so it can be
    # defaulted from versions.ps1 after the dot-source.
    [string]$Root,
    # Parallel compile jobs. 0 means "derive from RAM", which is the default because
    # the VM this kit targets is small and cc1plus dies with "out of memory
    # allocating 65536 bytes" once too many g++ processes are resident at once.
    [int]$Jobs = 0
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Root) { $Root = $BuildRoot }

$ucrt = 'C:\msys64\ucrt64'
$src = Join-Path $Root "src\fzssh-$FzSshVersion"
$build = Join-Path $Root 'build\fzssh'
$prefix = (Join-Path $Root 'deps') -replace '\\', '/'
$logDir = Join-Path $Root 'logs'

foreach ($t in @('meson.exe', 'ninja.exe', 'g++.exe')) {
    if (-not (Test-Path (Join-Path $ucrt "bin\$t"))) { throw "missing UCRT64 tool: $t" }
}
if (-not (Test-Path $src)) { throw "fzssh source missing at $src" }

# Same memory-aware cap the bash builds get through FZ_JOBS. Ninja's own default is
# CPU count + 2, and fzssh compiles libssh-sized translation units (userauth.cpp,
# crypt/bcrypt.cpp) at -O0 -g, so the default oversubscribes a small VM and the
# failures show up as cc1plus OOM in whatever files happen to run concurrently.
if ($Jobs -le 0) {
    $Jobs = [Math]::Min([Environment]::ProcessorCount, [Math]::Max(1, [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 2GB)))
}

# UCRT64 toolchain first; MSYS2 only as a fallback for sh.
$env:PATH = "$ucrt\bin;C:\msys64\usr\bin;$env:PATH"
# Our own libfilezilla install has to be visible to Meson's dependency() calls.
$env:PKG_CONFIG_PATH = Join-Path $Root 'deps\lib\pkgconfig'

Write-Host "meson    : $(& (Join-Path $ucrt 'bin\meson.exe') --version)"
Write-Host "ninja    : $(& (Join-Path $ucrt 'bin\ninja.exe') --version)"
Write-Host "compiler : $(& (Join-Path $ucrt 'bin\g++.exe') --version | Select-Object -First 1)"
Write-Host "prefix   : $prefix"
Write-Host "jobs     : $Jobs"
Write-Host "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH`n"

# Confirm every module Meson will ask for resolves, before starting a build.
Write-Host '=== dependency modules ==='
$pkgconf = Join-Path $ucrt 'bin\pkgconf.exe'
$failed = $false
    # Invoke-Native, not a bare `& $pkgconf ... 2>&1`: pkgconf reports a missing
    # module on stderr and exits 1, which is the case this loop exists to report,
    # and under Windows PowerShell 5.1 that stderr would raise a terminating error
    # instead. See Invoke-Native in versions.ps1.
    foreach ($m in @('libfilezilla', 'nettle', 'hogweed', 'gmp', 'libargon2')) {
        $v = @(Invoke-Native -File $pkgconf -ArgumentList @('--modversion', $m) -IgnoreExitCode) -join ' '
        if ($LASTEXITCODE -eq 0) { Write-Host ("  {0,-14} {1}" -f $m, $v) }
        else { Write-Host ("  {0,-14} FAILED: {1}" -f $m, $v); $failed = $true }
    }
if ($failed) { throw 'one or more Meson dependencies could not be resolved' }

if ($Wipe -and (Test-Path $build)) {
    Write-Host "`nWiping $build"
    Remove-Item $build -Recurse -Force
}

if (Test-Path (Join-Path $build 'build.ninja')) {
    Write-Host "`n=== meson setup (reconfigure) ==="
    $null = Invoke-NativeLogged -File (Join-Path $ucrt 'bin\meson.exe') `
        -ArgumentList @('setup', $build, $src, '--reconfigure', "--prefix=$prefix") `
        -PassThru | Select-Object -Last 20
}
else {
    Write-Host "`n=== meson setup ==="
    $null = Invoke-NativeLogged -File (Join-Path $ucrt 'bin\meson.exe') `
        -ArgumentList @('setup', $build, $src, "--prefix=$prefix", '--libdir=lib') `
        -PassThru | Select-Object -Last 25
}
if ($LASTEXITCODE -ne 0) { throw "meson setup failed (exit $LASTEXITCODE)" }

Write-Host "`n=== ninja ==="
$null = Invoke-NativeLogged -File (Join-Path $ucrt 'bin\ninja.exe') `
    -ArgumentList @('-C', $build, '-j', $Jobs) -PassThru | Select-Object -Last 25
if ($LASTEXITCODE -ne 0) { throw "ninja build failed (exit $LASTEXITCODE)" }

Write-Host "`n=== ninja install ==="
$null = Invoke-NativeLogged -File (Join-Path $ucrt 'bin\ninja.exe') `
    -ArgumentList @('-C', $build, 'install') -PassThru | Select-Object -Last 15
if ($LASTEXITCODE -ne 0) { throw "ninja install failed (exit $LASTEXITCODE)" }

Write-Host "`n=== installed ==="
Get-ChildItem "$prefix\lib\pkgconfig" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

# libfzssh-client.pc is what FileZilla's configure.ac:199 looks for.
$pc = Join-Path $prefix 'lib\pkgconfig\libfzssh-client.pc'
if (-not (Test-Path $pc)) {
    $found = Get-ChildItem "$prefix\lib\pkgconfig" -Filter '*.pc' -ErrorAction SilentlyContinue
    Write-Host "`nWARNING: libfzssh-client.pc not found. Installed .pc files:"
    $found | ForEach-Object { "  $($_.Name)" }
    exit 1
}

Write-Host "`n=== FileZilla's view of it ==="
"  modversion : " + ((& $pkgconf --modversion libfzssh-client) -join '')
"  cflags     : " + ((& $pkgconf --cflags libfzssh-client) -join '')
"  libs       : " + ((& $pkgconf --libs libfzssh-client) -join '')

# The Meson build tree is an intermediate; the installed prefix under deps\ is the
# output that configure.ac consumes. Reclaiming the build tree on success keeps a
# normal build from leaving tens of megabytes behind, and -Keep holds on to it for
# incremental rebuilds or post-mortem. Only reached when the install succeeded, so a
# failed build always leaves its tree for inspection.
if (-not $Keep) {
    Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "`nremoved intermediate build tree $build (pass -Keep to retain it)"
}
