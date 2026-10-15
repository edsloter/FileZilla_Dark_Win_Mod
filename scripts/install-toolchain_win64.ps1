<#
.SYNOPSIS
    Installs the MSYS2 UCRT64 toolchain and every FileZilla build dependency.

.DESCRIPTION
    Needs to run in an ELEVATED terminal - pacman writes to C:\msys64.

    Why MSYS2 rather than building everything from source:
      libfilezilla hard-requires gmp, nettle, hogweed and gnutls, and
      libfzssh is Meson-only (no autotools `configure`), so a from-source
      route also needs a Python + Meson. MSYS2 provides all of it prebuilt and
      keeps the whole toolchain consistent - which matters because we build
      wxWidgets, libfilezilla, libfzssh and FileZilla with the SAME compiler.

    wxWidgets is deliberately NOT taken from MSYS2: ucrt64 only offers 3.3.2,
      and FileZilla needs 3.3.3 for the dark-mode aware wxMessageBox.
      We build 3.3.3 ourselves (see build-wx_win64.ps1).

    hogweed is deliberately NOT in the list: MSYS2's ucrt64 repo has no hogweed
      package (only the MSYS/Cygwin libhogweed, unusable from a MinGW build), so
      it is built from source - see build-hogweed.ps1.

.NOTES
    Fully qualified package names are used, so this works from any MSYS2 shell;
    only bare names like "gcc" are context dependent.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw @'
pacman needs an elevated terminal.

Right-click "Windows Terminal" (or PowerShell) -> Run as administrator, then:

  & C:\fzdark\repo\scripts\install-toolchain_win64.ps1
'@
}

$pacman = 'C:\msys64\usr\bin\pacman.exe'
if (-not (Test-Path $pacman)) { throw "pacman not found at $pacman" }

$packages = @(
    # toolchain
    'mingw-w64-ucrt-x86_64-gcc'          # gcc/g++/ar/windres/dlltool + binutils
    'mingw-w64-ucrt-x86_64-make'
    'mingw-w64-ucrt-x86_64-ninja'
    'mingw-w64-ucrt-x86_64-meson'        # fzssh is a Meson project
    'mingw-w64-ucrt-x86_64-python'       # Meson's interpreter
    'mingw-w64-ucrt-x86_64-pkgconf'      # FileZilla's configure.ac requires it
    # 7-Zip, for the .7z overlay archive and for unpacking the NSIS installer.
    # This is current 7-Zip and has the PE/NSIS handlers; the msys/p7zip package
    # is an older fork without them and cannot open an NSIS setup .exe.
    'mingw-w64-ucrt-x86_64-7zip'

    # archive decoders: /usr/bin/tar shells out to the compressor's helper program
    # (bzip2/xz), so a fresh MSYS2 without these dies with
    # "tar (child): lbzip2: Cannot exec" the first time extract-deps sees a .tar.bz2.
    # These are the /usr versions MSYS2's tar actually spawns; the ucrt-prefixed
    # equivalents provide them under /ucrt64 for downstream projects.
    'bzip2'      # .tar.bz2 / -j
    'xz'         # .tar.xz / -J

    # The MSYS make, i.e. /usr/bin/make, which mingw-w64-ucrt-x86_64-make does NOT
    # provide (it ships only /ucrt64/bin/mingw32-make.exe) and a stock MSYS2 does not
    # install by default. FileZilla's nested src/fzshellext package bakes an absolute
    # MSYS srcdir (/c/fzdark/work/.../src/fzshellext) into its generated Makefiles;
    # native mingw32-make resolves that as C:\c\fzdark\... and reports every source file
    # missing. MSYS make understands /c/ paths, so the client stage needs this one even
    # though the compilers are still the UCRT64 ones.
    'make'

    # FileZilla client dependencies
    'mingw-w64-ucrt-x86_64-sqlite3'      # configure.ac:630  sqlite3 >= 3.7
    'mingw-w64-ucrt-x86_64-boost'        # Boost.Regex, m4/check_regex.m4

    # libfzssh-client 1.4.0 dependencies (meson.build:12-17)
    'mingw-w64-ucrt-x86_64-argon2'      # dependency('libargon2') - ssh-ed25519 key encryption
    'mingw-w64-ucrt-x86_64-pugixml'      # FileZilla XML backend (--with-pugixml).
                                          # The system library keeps one pugixml ABI
                                          # and avoids rebuilding the vendored copy;
                                          # --with-pugixml=builtin is the
                                          # no-elevation fallback.
    'mingw-w64-ucrt-x86_64-cppunit'      # only for --enable-tests, unused by the release build
    'mingw-w64-ucrt-x86_64-gmp'
    'mingw-w64-ucrt-x86_64-nettle'       # needs >= 3.10, ucrt64 ships 4.0
    'mingw-w64-ucrt-x86_64-gnutls'

    # locales: msgfmt / msgmerge / xgettext (configure.ac:702-714)
    'mingw-w64-ucrt-x86_64-gettext-tools'

    # build-filezilla_win64.sh runs `autoreconf -i` to regenerate configure and every
    # Makefile.in from configure.ac, and libfilezilla's VPATH refresh rules shell out
    # to automake-1.17. A fresh MSYS2 has none of these, and autoreconf without
    # libtool's m4 macros silently keeps a stale configure, which then fails much
    # later at configure time.
    'autoconf'
    'automake'
    'libtool'
)

Write-Host "Installing $($packages.Count) UCRT64 packages via pacman...`n"
& $pacman -S --needed --noconfirm @packages
if ($LASTEXITCODE -ne 0) { throw "pacman failed with exit code $LASTEXITCODE" }

Write-Host "`nDone. Toolchain versions:"
$ucrt = 'C:\msys64\ucrt64'
$gcc  = Join-Path $ucrt 'bin\g++.exe'
if (Test-Path $gcc) { & $gcc --version | Select-Object -First 1 }
foreach ($f in @('bin\pkgconf.exe', 'bin\meson.exe', 'bin\ninja.exe', 'bin\mingw32-make.exe')) {
    $p = Join-Path $ucrt $f
    "{0,-34} {1}" -f $p, $(if (Test-Path $p) { 'present' } else { 'MISSING' })
}

Write-Host "`nStill to be built from source:"
Write-Host "  - wxWidgets $WxVersion       (MSYS2 only has an older one)"
Write-Host "  - libhogweed              (no ucrt64 package)"
Write-Host "  - libfilezilla $LibfzVersion"
Write-Host "  - libfzssh-client $FzSshVersion"
Write-Host "  - FileZilla $FzVersion"