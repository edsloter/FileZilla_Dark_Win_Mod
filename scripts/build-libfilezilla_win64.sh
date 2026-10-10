#!/bin/sh
# ---------------------------------------------------------------------------
# Build and install libfilezilla 0.57.0 into C:\fzdark\deps.
#
# FileZilla 3.71.1's configure.ac:191 requires libfilezilla >= 0.57.0 to be
# installed already, and the 3.71.1 client tarball does not ship it.
#
# Dependencies (all satisfied by the MSYS2 UCRT64 packages):
#   gmp, nettle, hogweed, gnutls  (configure.ac:180-210, all mandatory)
#
# Toolchain mixing: this script runs under the MSYS2 POSIX shell (autotools and
# libtool need it) but puts /ucrt64/bin first on PATH so gcc/g++/ar/windres all
# come from the UCRT64 toolchain - the same one used for wxWidgets and FileZilla.
#
# pkgconf is a native Windows binary and emits Windows-style paths, which is what
# the native g++ needs.
#
# --disable-locales: libfilezilla has no --disable-nls; its locales/ stage is a
# hand-rolled subdir (configure's --enable-locales) and it is not optional. The MSYS2
# gettext binaries are native Windows programs, and the header xgettext writes into the
# generated libfilezilla.pot comes out with a real line break inside a quoted string
# instead of the \n escape. gettext 0.23 then rejects it ("end-of-line within string",
# charset parsed as "UTF-8Content-Transfer-Encoding:") and every locales/*.po.new target
# fails. libfilezilla is a library and FileZilla ships its own translations, so the only
# thing its message catalogs buy here is a broken locale stage.
#
# --prefix uses a Windows path so the generated libfilezilla.pc carries
# C:/fzdark/deps rather than /c/fzdark/deps.
# ---------------------------------------------------------------------------
set -e

export MSYSTEM=UCRT64
# /ucrt64 on MSYS2's side is set up by its login-shell machinery; in the WDAG-style
# cold-start run (bash invoked directly, non-interactive, side-by-side with a
# default MSYSTEM profile), that mount can be absent and /ucrt64/bin silently drops
# out of PATH, turning `make` into "command not found" with exit code 127.
export PATH="/ucrt64/bin:/usr/bin:$PATH"
export PKG_CONFIG="/ucrt64/bin/pkgconf.exe"

SRC=${FZ_LIBFILEZILLA_SRC:?FZ_LIBFILEZILLA_SRC must be set by install-filezilla-dark_win64.ps1}

# FZ_ROOT is exported by the orchestrator, in MSYS form; it is what relocates the
# build when install-filezilla-dark_win64.ps1 runs with a non-default -Root.
FZ_ROOT=${FZ_ROOT:-/c/fzdark}

BUILD="$FZ_ROOT/build/libfilezilla"
# Windows-style, so the generated libfilezilla.pc records C:/... rather than /c/....
PREFIX="$(cygpath -w "$FZ_ROOT" | tr '\\' '/')/deps"
JOBS=${FZ_JOBS:-16}
MAKE=${MAKE:-/ucrt64/bin/mingw32-make.exe}
export MAKE

mkdir -p "$BUILD"
cd "$BUILD"

echo "=== toolchain ==="
g++ --version | head -1
echo "pkgconf : $("$PKG_CONFIG" --version)"
echo "prefix  : $PREFIX"

echo
echo "=== dependency modules ==="
for m in gmp nettle hogweed gnutls; do
    printf '  %-8s %s\n' "$m" "$("$PKG_CONFIG" --modversion "$m")"
done

# GNU make's VPATH refresh rules (Makefile.in : Makefile.am, and Makefile.in :
# config/config.hpp.in) fire whenever an input looks newer than its output. The
# release tarball ships inputs whose timestamps sit within seconds of Makefile.in's
# own, so park every input at Makefile.in's timestamp first: make then never has to
# re-run automake in the middle of the build.
for f in "$SRC/Makefile.am" "$SRC/configure" "$SRC/config/config.guess" "$SRC/aclocal.m4" "$SRC/config/config.hpp.in"; do
    [ -f "$f" ] && touch -r "$SRC/Makefile.in" "$f"
done
touch "$SRC/Makefile.in"

# Tell configure where the sources are in a form native mingw32-make can use. $SRC is
# an MSYS path (/c/fzdark/src/...) and mingw32-make is a Windows program: it reads that
# as C:\c\fzdark\src\..., concludes every source file is missing, and stops with
# "No rule to make target ... Makefile.am, needed by ... Makefile.in". Autoconf bakes
# whatever is passed here straight into srcdir/top_srcdir in every generated Makefile,
# so a relative path is what keeps the MSYS form out of them.
REL_SRC=$(realpath --relative-to="$BUILD" "$SRC")

echo
echo "srcdir  : $REL_SRC"
echo "=== configure ==="
cfg_log="$BUILD/configure.log"
if MAKE="$MAKE" "$SRC/configure" \
    --prefix="$PREFIX" \
    --srcdir="$REL_SRC" \
    --disable-static \
    --disable-locales \
    --disable-silent-rules \
    "$@" >"$cfg_log" 2>&1
then
    tail -25 "$cfg_log"
else
    status=$?
    tail -40 "$cfg_log"
    rm -f "$cfg_log"
    echo "configure failed with exit code $status" >&2
    exit $status
fi
rm -f "$cfg_log"

echo
echo "=== make -j$JOBS ==="
"$MAKE" -j"$JOBS"

echo
echo "=== "$MAKE" install ==="
"$MAKE" install

echo
echo "=== installed ==="
ls -1 "$PREFIX/lib" | grep -i filezilla || true
ls -1 "$PREFIX/lib/pkgconfig" || true