Third-party software used to build and run this FileZilla dark-theme build.

## What ships in the overlay (C:\fzdark\install payload + this directory)

Each entry names the project, where its license text lives in this directory or
the machine, and where the code lives upstream.

- FileZilla (GPL-2.0): `GPL-2.0.txt` — actually the LICENSE text already built
  into this directory was extracted from `libfilezilla-0.57.0/COPYING` which is
  the full GPLv2 text; the stock FileZilla installation also carries the same
  license as `GPL.html` at its root.
- libfilezilla (GPL-2.0): same `GPL-2.0.txt`.
- libfzssh-client / libfzssh / libfzssh-crypt (AGPL-3.0+, with Section-7
  additional terms): `AGPL-3.0.txt` plus `fzssh-README.txt` for the copyright
  section and the Section-7 note in the library's README.
- wxWidgets 3.3.3 (LGPL-2.1-or-later with the wxWindows Library Exception):
  `wxWidgets-LGPL-2.1.txt`.
- Boost 1.88.0 (Boost Software License 1.0): `Boost-LICENSE.txt`.
- SQLite 3.53.4 amalgamation (public domain): `SQLite-PublicDomain.txt`; see the
  header comment inside `sqlite3.c` for authority.
- glu, expat, pcre and zlib sources bundled inside wxWidgets: see
    the COPYING entries inside their source trees in `wxWidgets-3.3.3/` and the
    stock MSYS2 packages under `C:\msys64\ucrt64\share\licenses\<package>\`.

## Packages supplied by the toolchain (MSYS2 UCRT64, in `C:\msys64\ucrt64`)

Dynamic libraries the overlay deliberately reuses from the stock FileZilla
install on the same machine (libgcc_s_seh, libsqlite3, libstdc++, TLS stack,
brotli, gmp) are covered by their own licenses; the authoritative copies are in
`C:\msys64\ucrt64\share\licenses\<package>\`.

## Build tools

None of these ship in the overlay; they are needed to build it, and the kit
redistributes none of them.

- MSYS2 packages (bash, make, meson, ninja, gdb, libtool, 7-Zip): see
    `C:\msys64\usr\share\licenses\<package>\` and
    `C:\msys64\ucrt64\share\licenses\<package>\`.
- NSIS, unpacked to `C:\fzdark\tools\nsis`: `COPYING` in that directory,
    shipped in the archive itself. zlib/libpng for NSIS itself; note that the
    LZMA compression module - the one makensis uses for our installer - is
    CPL-1.0, and bzip2 is bzip2-licensed.
- Git for Windows: GPLv2, `C:\Program Files\Git\LICENSE.md`.

PowerShell is not listed: the scripts run on the Windows PowerShell 5.1 that
ships with Windows, so the kit neither installs nor redistributes a shell.

## About the license of this kit itself

The source, scripts and patches in this tree are derivative work over GPL and
AGPL source. As with any work built from those sources, the GPL-2.0 terms apply
to the FileZilla linkage, and the AGPL-3.0 terms cover the libfzssh linkage;
see `AGPL-3.0.txt` Section 7 note in `fzssh-README.txt`.
