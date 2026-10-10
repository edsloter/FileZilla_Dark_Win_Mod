#!/bin/sh
# ---------------------------------------------------------------------------
# Build and install FileZilla 3.71.1 into C:\fzdark\install.
#
# Run against the patched work tree created by init-patch-worktree_win64.ps1, NOT
# against the pristine upstream tree.
#
# Prerequisite: build-wx_win64.ps1, build-libfilezilla_win64.sh and build-fzssh_win64.ps1 have all
# been run, so that wxWidgets 3.3.3, libfilezilla 0.57.0 and libfzssh-client
# 1.4.0 are present.
#
# Toolchain mixing: same arrangement as build-libfilezilla.sh. This runs under
# the MSYS2 POSIX shell because autotools and libtool need it, but /ucrt64/bin
# comes first on PATH so gcc/g++/ar/windres are the UCRT64 ones - the identical
# compiler that built wxWidgets and both libraries, which matters because
# FileZilla includes their headers and links their import libraries.
#
# LIBS=-lregex
#   configure.ac on a libstdc++ toolchain always selects Boost.Regex instead of
#   std::regex: m4/check_regex.m4 deliberately fails its <regex> probe unless
#   _MSC_VER or _LIBCPP_VERSION is defined, so USE_BOOST_REGEX ends up defined
#   as 1 and src/commonui/filter.cpp includes <boost/regex.hpp>.
#
#   The macro only ever runs AC_COMPILE_IFELSE, never AC_LINK_IFELSE, so
#   configure happily reports success having never resolved a single Boost
#   symbol - the link only fails much later. MSYS2's Boost.Regex is built as
#   "regex" (libregex.a / libregex.dll.a), not "boost_regex", so it has to be
#   spelled -lregex. Passing it via LIBS puts it on every automake link rule,
#   which keeps this a build-time flag instead of a source patch.
#
# wxWidgets 3.3.3
#   configure.ac refuses wxWidgets 3.3 outright. Patch 1 in the series turns
#   that into a warning. Only configure.ac is patched: autoreconf below
#   regenerates configure, so the copy shipped in the release tarball is never
#   edited by hand.
# ---------------------------------------------------------------------------
set -e

export MSYSTEM=UCRT64
export PATH=/ucrt64/bin:/usr/bin:$PATH
export PKG_CONFIG=/ucrt64/bin/pkgconf.exe

FZ_ROOT=${FZ_ROOT:-C:/fzdark}

# The hand-written wx-config shim ships with this repo under scripts\bin, so it is
# where FileZilla's configure will find it regardless of -Root. See the header of
# that file for the exact command surface m4/wxwin.m4 requires.
# Invoked as `bash '<script>'` by the orchestrator, so $0 resolves to the script
# itself and xargs dirname gives the scripts\ dir containing bin\.
export PATH="$(cd "$(dirname "$0")" && pwd)/bin:$PATH"

# data/dllcopy.sh builds its search path from $PATH plus any "-L/" flags it finds
# in $(WX_LIBS). It only recognises the POSIX "-L/" spelling, while the wx-config
# shim emits a Windows "-LC:/wxWidgets-3.3.3/lib/gcc_dll", so the wxWidgets
# directory never reaches the search path. filezilla.exe then imports
# wxmsw333u_core_gcc_custom.dll with nothing able to locate it, and dies with
# STATUS_DLL_NOT_FOUND. Putting the directories on $PATH sidesteps the mismatch
# and also supplies the libfilezilla/libfzssh DLLs for the recursive walk.
export PATH="$(cygpath -u "${FZ_WX_PREFIX:?FZ_WX_PREFIX must be set by install-filezilla-dark_win64.ps1}")/lib/gcc_dll:$(cygpath -u "$FZ_ROOT")/deps/bin:$PATH"

# Our own libfilezilla and libfzssh installs. System packages come from the
# default ucrt64 pkg-config search path.
export PKG_CONFIG_PATH="$FZ_ROOT/deps/lib/pkgconfig"

SRC=${FZ_SRC:?FZ_SRC must be set by install-filezilla-dark_win64.ps1}
PREFIX=${FZ_PREFIX:?FZ_PREFIX must be set by install-filezilla-dark_win64.ps1}
JOBS=${FZ_JOBS:-16}

# This stage needs the MSYS make, not mingw32-make. FileZilla's nested
# src/fzshellext package puts an absolute MSYS srcdir (/c/fzdark/work/.../src/fzshellext)
# into its generated Makefiles, and native mingw32-make reads that as C:\c\fzdark\...,
# decides the sources are missing and stops with "No rule to make target
# .../Makefile.am, needed by .../Makefile.in". MSYS make resolves /c/ paths, so name it
# explicitly instead of relying on `make` being found - a stock MSYS2 has no /usr/bin/make
# at all (mingw-w64-ucrt-x86_64-make ships only mingw32-make.exe), and when it is absent
# config.status's dependency tracking bootstrap fails first, reporting the much less
# obvious "Something went wrong bootstrapping makefile fragments".
MAKE=${MAKE:-/usr/bin/make}
export MAKE

export LIBS=-lregex

cd "$SRC"

# Regenerate the generated files from the patched .ac/.am sources. This is what
# lets the patch series stay source-only: configure and every Makefile.in are
# always rebuilt from configure.ac and Makefile.am, so neither they nor the
# copies shipped in the release tarball are ever patched by hand.
#
# -f is required, not just an optimisation. The tarball ships a prebuilt
# configure that was generated from an older m4/wxwin.m4 containing a hard
# "You must use wxWidgets 3.2.x, development versions of wxWidgets are not
# supported" gate, and that would override the 3.3 acceptance added in
# configure.ac. Plain `autoreconf -i` only replaces files that look out of
# date, and a configure that was restored from git has a fresh timestamp, so it
# silently survives and the build fails at configure time. Forcing regeneration
# keeps this tree authoritative and makes the source-only patch series sufficient
# on its own.
#
# -f also rewrites the vendored config/config.guess, config/config.sub,
# config/ltmain.sh, m4/libtool.m4 and src/fzshellext/configure in place, which is
# why those show up as modified in git status.
autoreconf -f -i

echo "=== toolchain ==="
g++ --version | head -1
echo "wx-config : $(wx-config --version)   ($(command -v wx-config))"
echo "prefix    : $PREFIX"

echo
echo "=== dependency modules ==="
for m in libfilezilla libfzssh-client sqlite3; do
    printf '  %-16s %s\n' "$m" "$("$PKG_CONFIG" --modversion "$m")"
done

echo
echo "=== configure ==="
# Not `configure ... | tail -40`: under `set -e` a pipeline reports tail's status, so a
# configure that died in config.status would be mistaken for success and the run would
# carry on into make, which then failed with an unrelated-looking error.
cfg_log="$SRC/configure.log"
if MAKE="$MAKE" ./configure \
    --prefix="$PREFIX" \
    --enable-gui \
    --enable-locales \
    --disable-silent-rules \
    "$@" >"$cfg_log" 2>&1
then
    tail -40 "$cfg_log"
else
    status=$?
    tail -60 "$cfg_log"
    rm -f "$cfg_log"
    echo "configure failed with exit code $status" >&2
    exit $status
fi
rm -f "$cfg_log"

echo
echo "=== make -j$JOBS ==="
# dllcopy.sh skips any DLL that already has an entry under dlls_gui/, and that
# includes the ".processed" markers it writes for DLLs it could not find. An
# earlier run against a shorter PATH therefore poisons every later run, so the
# collection always has to start from an empty directory.
rm -rf data/dlls_gui data/dll_gui_install.nsh data/dll_gui_uninstall.nsh
"$MAKE" -j"$JOBS"

echo
echo "=== make install ==="
"$MAKE" install

echo
echo "=== stage runtime DLLs next to filezilla.exe ==="
# make install only installs FileZilla's own binaries. The wxWidgets,
# libfilezilla and libfzssh DLLs they import are bundled by the NSIS installer
# from data/dlls_gui, which is not part of this build, so copy them in by hand
# and leave bin/filezilla.exe self-contained.
mkdir -p "$PREFIX/bin"
if [ -d data/dlls_gui ]; then
    cp -f data/dlls_gui/*.dll "$PREFIX/bin/" 2>/dev/null || true
fi
cp -f "$(cygpath -u "$FZ_ROOT")"/deps/bin/*.dll "$PREFIX/bin/" 2>/dev/null || true

# The overlay replaces files in a stock FileZilla install, which names these libraries
# libfzclient-private-3-71-1.dll, libfzclient-commonui-private-3-71-1.dll and
# libfilezilla-59.dll. MSYS2's libtool, though, links and installs them as
# msys-fzclient-* and cygfilezilla-* - so the stock names have to be produced here.
#
# This is not cosmetic: `make install` never removes anything, so an install tree that
# already holds the lib- names keeps serving whatever an earlier build left in them.
# Overwriting from the DLLs built a moment ago is what guarantees the overlay is never
# assembled from stale binaries.
echo
echo "=== stock-named aliases ==="
for d in "$PREFIX/bin"/msys-fzclient-*.dll "$PREFIX/bin"/cygfilezilla-*.dll; do
    [ -f "$d" ] || continue
    base=${d##*/}
    case "$base" in
        msys-fzclient-*) stock="lib${base#msys-}" ;;
        cygfilezilla-*)  stock="lib${base#cyg}" ;;
        *) continue ;;
    esac
    cp -f "$d" "$PREFIX/bin/$stock"
    printf '  %-42s <- %s\n' "$stock" "$base"
done

echo
echo "=== installed ==="
ls -1 "$PREFIX/bin" 2>/dev/null || true
ls -1 "$PREFIX/share/filezilla" 2>/dev/null | head -20 || true