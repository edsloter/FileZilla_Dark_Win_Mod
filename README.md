# FileZilla 3.71.1 — Windows light/dark theme build kit

![FileZilla 3.71.1 in Windows dark mode, rebuilt to follow the system appearance setting](screenshots/filezilla-dark-theme.png)

A source-and-scripts kit that builds FileZilla 3.71.1 for Windows x64 with working
system light/dark theme support, plus two ways to apply the result as a drop-in overlay
to a machine that already has FileZilla installed.

Upstream FileZilla does not follow the Windows light/dark setting. This builds it against
wxWidgets 3.3, which does, so FileZilla follows the system appearance by default and
switches live when you change it in Settings → Interface → *Follow the system light and
dark theme*.

**Windows x64 only.** Every script carries a `_win64` suffix for a reason: they drive
MSYS2/UCRT64, autotools and Meson against a Windows-native layout. Nothing here is
portable, and nothing is tested anywhere else.

## The two artefacts

Both are built by default, from the same staged payload, and install **byte-identical
files** — 32 of them: 8 that replace existing files, 24 that are added, none deleted.

| Artefact | Size | Use it when |
|---|---|---|
| `FileZilla-3.71.1-dark-overlay-setup.exe` | ~7.2 MB | Normally. Self-contained installer: detects your FileZilla, backs up what it replaces, installs, and registers an uninstaller. Nothing has to be installed on the machine that installs it. |
| `FileZilla-3.71.1-dark-overlay.7z` | ~6.3 MB | You would rather extract files over your existing installation and manage the backup yourself. Also carries the PowerShell installer for a guided, reversible install. |

Each ships with a `.sha256` sidecar in `sha256sum` format so it can be checked after
download.

The overlay must be applied as a unit: the patched `filezilla.exe` needs the exact
wxWidgets 3.3 and libfilezilla build it was compiled against, and mixing it with stock
wx 3.2 fails at load time.

## Layout

    manifests/    SHA-256 of every file in the upstream source tree
    patches/      the 9-patch series, plus .gitignore.baseline
    licenses/     licence texts for the components built here
    screenshots/  the screenshot at the top of this file
    scripts/      everything that fetches, patches, builds, packages and tests
    scripts/nsis/ templates for the .exe installer and its removal tool
    tarballs/     offline drop box (see below)
    versions.ps1  every version, URL, pinned digest and fixed path

## Quick start

**1. Bootstrap**, from an elevated PowerShell:

    powershell -File .\scripts\bootstrap_win64.ps1

Installs and hash-verifies Git, MSYS2 and wxWidgets 3.3.3. Re-running is safe;
finished steps are skipped. `-Plan` prints what is missing without installing
anything, and needs no admin.

**2. Build**, in the same shell:

    powershell -File .\scripts\install-filezilla-dark_win64.ps1

Eleven steps: toolchain, dependencies, wxWidgets, libfilezilla/libfzssh, upstream
source, patch series, icon variants, FileZilla, verification, overlay, NSIS installer.
Re-running is cheap — completed steps are detected and skipped.

Or combine them:

    powershell -File .\scripts\bootstrap_win64.ps1 -ThenBuild

| Flag | Effect |
|---|---|
| `-Root <path>` | Put builds, extracts and intermediates somewhere other than `C:\fzdark`. |
| `-Keep` | Keep downloaded archives, extracted trees, build intermediates, logs and the patched work tree. Without it each stage deletes what it fetched once done with it. |
| `-Force` | Rebuild FileZilla and the overlay from scratch. Deliberately does *not* reinstall the MSYS2 toolchain, which needs an elevated shell. |
| `-No7z` | Build only the `.exe`, skipping the `.7z`. The `.exe` is always built either way. |
| `-SkipOverlay` | Skip both overlay artefacts; stop after the FileZilla build. |

Both artefacts are built by default and neither needs anything installed on the
machine that receives it.

Fixed paths, not configurable: `C:\msys64` (toolchain), `C:\wxWidgets-3.3.3` (built in
place), `C:\fzdark\tools\nsis` (portable NSIS, unpacked on demand for the `.exe` build).
NSIS is *unpacked, not installed*: nothing is registered and no elevation is needed.

`C:\fzdark` is only the default, not a requirement — but it is the shortest path that is
free of spaces, so it dodges MAX_PATH trouble in the autotools and MSYS2 layers, and being
outside OneDrive it avoids file-on-demand placeholders turning into phantom build
failures. Any writable path works; `-Root` moves everything except the two fixed tool
installations above.

## Install the overlay

### Route 1 — the installer `.exe`

Run it. It finds your FileZilla, checks the version really is 3.71.1, backs up every
file it replaces into `<FileZilla>\fzdark-backup\`, installs, and adds an entry to
**Add/Remove Programs**. Remove it from there to undo.

It requires administrator rights and will not run without them.

### Route 2 — the `.7z`

**Extract-over**, the simple way: close FileZilla, extract the archive over
`C:\Program Files\FileZilla FTP Client`, choose *replace files*. Nothing else to run.

**With rollback**, extract it anywhere and run:

    .\install-dark-overlay_win64.ps1

Same checks and backup, driven from PowerShell. Undo with the same script plus
`-Uninstall`, which restores the installation byte for byte.

## Things worth knowing before you ship or automate

- **The `.exe` is unsigned.** A browser-downloaded copy gets SmartScreen's blue *Windows
  protected your PC* wall; *More info → Run anyway* gets through. A code-signing
  certificate removes it. The installed binaries were checked against Defender with
  current signatures, marked and unmarked as internet downloads, and are clean.
- **Do not trust the exit code of an elevated `.exe`.** When the shell has to spawn an
  elevated child, the child's exit code does not come back through `$LASTEXITCODE` —
  measured, `0` after a refusal that had in fact worked. Use `Start-Process -Wait`, or
  read `%TEMP%\fzdark-overlay-setup.log`, which records what every run did or refused to
  do. Run from an already-elevated prompt and the exit code is reliable.
- **The removal tool is kept, deliberately.** It lives in `%LOCALAPPDATA%\fzdark`
  because a running executable cannot delete itself, so anything left inside the FileZilla
  folder would stop the installation being restored byte for byte. It is about 54 KB and
  can be deleted at any time.
- **The two installers are not interchangeable on the same tree.** An `.exe`-installed
  overlay is removed by the tool that `.exe` placed; a PowerShell-installed one by
  `install-dark-overlay_win64.ps1 -Uninstall`. Each understands only its own backup.
- **Which FileZilla gets picked** follows: a target this kit installed to before, then
  Program Files, Program Files (x86), `%LOCALAPPDATA%`, `%LOCALAPPDATA%\Programs`. The
  directory page lets you override it. An empty `/D=` is indistinguishable from passing
  none, so a script with an unset variable silently gets auto-detection.

## Elevation

**Nothing here re-launches itself with `RunAs`**, except the `.exe` installer, which asks
for admin via its manifest and simply does not run if you decline. Everything else either
needs admin for a specific reason or none at all.

| Step | Command | Admin? | Why |
|---|---|---|---|
| See what is missing | `bootstrap_win64.ps1 -Plan` | **No** | Read-only probes. |
| Install missing tools | `bootstrap_win64.ps1` | **Yes** | Installs under `Program Files`, unpacks MSYS2 and wxWidgets. |
| MSYS2 packages | `install-toolchain_win64.ps1` | **Yes** | `pacman` refuses to install packages unelevated. |
| Fetch + verify archives | `fetch-deps_win64.ps1` | No | Writes under the build root. |
| Extract dependencies | `extract-deps_win64.ps1` | No | Writes under the build root. |
| Build wxWidgets / libfilezilla / fzssh | `build-wx_win64.ps1`, `build-libfilezilla_win64.sh`, `build-fzssh_win64.ps1` | No | Writes under the build root and `C:\wxWidgets-3.3.3`. |
| Patch + build FileZilla | `install-filezilla-dark_win64.ps1` | **Yes** only while the toolchain needs installing | With the toolchain present it needs no admin. |
| Get a portable NSIS | `get-nsis_win64.ps1` | No | Only for the `.exe` build. Unpacks, never installs. |
| Build the overlay payloads | `build-overlay_win64.ps1`, `build-nsis-installer_win64.ps1` | No | Reads the install tree, writes the build root. |
| **Run the overlay `.exe`** | `FileZilla-...-setup.exe` | **Yes** | Writes into the FileZilla folder. Declines to start without it. |
| Install overlay to `Program Files` | `install-dark-overlay_win64.ps1` | **Yes** | Same. |
| Install overlay to a user-owned copy | `install-dark-overlay_win64.ps1 -InstallDir <path>` | No | Same script, different target. Useful for testing. |

The build root must exist and be writable by your account; creating it needs admin once.

## Source archives: the `tarballs\` drop box

`tarballs\` is an offline drop box. Fetch scripts check it before the network: anything you
put there is used instead of downloading, and is still verified against the pinned
SHA-512 — an archive that does not match is refused, never overwritten. Delete the file to
go back to the network, or use `-Force`. Names and sizes are pinned in `versions.ps1`.

## Test it

    powershell -File .\scripts\test-overlay_win64.ps1
    powershell -File .\scripts\test-nsis-installer_win64.ps1

The first runs four phases against real copies of an actual FileZilla 3.71.1
installation: payload extraction, script install, uninstall-and-restore, and a round trip
of the released `.7z`. It asserts the install is restored byte for byte and that nothing
outside the payload is disturbed, `fzstorj.exe` included.

The second builds a user-elevation copy of both `.exe` artefacts and round-trips them
against a scratch copy: install, refuse to overwrite a wrong version, refuse cleanly
while FileZilla is running, and removal restoring the whole tree byte for byte. Both need
a stock FileZilla install to copy from; pass `-StockDir` if it is not in
`C:\Program Files\FileZilla FTP Client`.

## Provenance

The upstream source is fetched by hash, never trusted by filename:

| | |
|---|---|
| Archive | `FileZilla_3.71.1_src.tar.xz`, 3,583,056 bytes |
| SHA-512 | `44c9c9db88053a1b01ee27ebc9968eabff57d2ba6b23ac44ab080e3def9d5206cb4391dd7e0742bbd6189657a48525cfd5347d34ae87b69ccbd78b29e0101fda` |
| Tree | 1320 files, SHA-256 in `manifests/` |

FileZilla's own download page hands out short-lived signed links and returns HTTP 403 from
some networks, so mirrors are tried and the pinned SHA-512 decides which bytes are
acceptable; anything that fails is deleted and the next mirror tried.

NSIS, used only to build the `.exe`, is fetched the same way: pinned to 3.13 by SHA-256,
tried across SourceForge and two third-party mirrors, and unpacked with 7-Zip rather than
installed.

The patch series is checked against a known tree hash, `dc392be8...`, so a silently
mis-applied patch cannot turn into a shipped binary.

## Licensing

This is a modified build. The complete corresponding source is the upstream FileZilla
3.71.1 tarball plus the patch series in `patches\`, which is exactly what the build
scripts consume.

**The combined work is licensed AGPL-3.0**, because `filezilla.exe` links `libfzssh`,
which is AGPL-3.0-only. AGPL-3.0 section 13 permits that linking, and it makes the AGPL
the governing licence for the combined binary. FileZilla's own `COPYING` says GPLv3; that
is not the whole answer for this particular build.

| Component | Version | Licence |
|---|---|---|
| FileZilla | 3.71.1 | GPL-3.0-or-later |
| libfilezilla | 0.57.0 | GPL-2.0-or-later |
| libfzssh | 1.4.0 | **AGPL-3.0-only** |
| wxWidgets | 3.3.3 | wxWindows Library Licence |
| Boost | 1.88.0 | BSL-1.0 |
| SQLite (amalgamation) | 3530400 | public domain |

Licence texts covering the components built here are in `licenses\` and ship inside the
`.7z`. If you redistribute a binary built from this kit, offer the corresponding source as
described above.

## When FileZilla releases a new version

Two pins are specific to one release and cannot be carried across by editing a number: the
per-file manifest under `manifests\`, and `$FzPatchedTree` in `versions.ps1`. The tree hash
changes whenever upstream moves *and* whenever any patch is edited, so it has to be
recomputed rather than guessed.

```powershell
# against an extracted upstream tree for the new version:
.\scripts\update-version_win64.ps1 -Version 3.72.0
```

That hashes the new tree into `manifests\filezilla-3.72.0.sources.sha256`, applies the whole
series to a scratch work tree with `git am -3`, and prints the new values. It does **not**
edit `versions.ps1`, because that file is the audited record of what was verified; it should
only change once someone has read the diff.

Read the output in this order:

1. **Any patch reported as `FAILED`.** The script stops at the first one, so later patches
   are untested. Resolve it in the work tree it leaves behind:
   ```
   git -C C:\fzdark\work\port-3.72.0 am --show-current-patch=diff
   ```
   Most often upstream edited the code the patch touches, or fixed the problem itself and
   the patch should be dropped. Then `git am --continue`, or `--abort` to start over.

2. **`git diff <baseline>..HEAD --stat`.** Patches can apply cleanly and still be wrong —
   a 3-way merge resolves context drift without anyone noticing the logic no longer fits.

3. **Paste the printed values** into `versions.ps1`: `$FzVersion`, `$FzManifestFile` and
   `$FzPatchedTree`, plus `$FzSourceFile`, `$FzSourceSize` and `$FzSourceSha512`, which come
   from the download page and cannot be derived.

4. **Rebuild.** Step 6 compares the patched tree against `$FzPatchedTree` and refuses to
   continue on a mismatch, so a stale pin fails loudly rather than shipping silently.

The `-3` flag is what makes most bumps routine: every patch carries git blob hashes, so a hunk
whose surrounding lines merely *moved* merges instead of failing. The version that breaks this
way is one where upstream rewrote the lines a patch depends on, which is exactly when you
should look.

## What the patches do

| | |
|---|---|
| 0001, 0002 | let `configure.ac` accept wxWidgets 3.3 and link system pugixml |
| 0003, 0006 | keep MSYS2 and autoreconf scratch output out of the tree |
| 0004 | build against wxWidgets 3.3 |
| 0005 | fix a `std::wstring` narrowing bug that wx 3.3 exposes |
| 0007 | follow the system light/dark theme |
| 0008 | add the 13 light-appearance icon variants |
| 0009 | give the already-connected dialog's options distinct IDs, so dark mode can draw them |
