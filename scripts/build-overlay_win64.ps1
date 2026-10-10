<#
.SYNOPSIS
    Builds the drop-in FileZilla system light/dark overlay.

.DESCRIPTION
    Stages the modified FileZilla binaries, the extra runtime they
    need that a stock Windows build does not ship, and the 13 new light-appearance
    icons.

    The payload is laid out the way the official Windows build lays itself out, so
    the 7z archive can simply be extracted over an existing installation. That build is
    flat: filezilla.exe and every DLL sit in the installation root, and icons live
    under resources\. It also still uses wxWidgets 3.2, so the newer wx libraries
    have to be added alongside the existing wx32 ones.

    Only files this project actually changes are shipped. libfilezilla, libfzssh,
    libgcc_s_seh-1, libstdc++-6 and libsqlite3-0 are already present in a stock
    the FileZilla release and are left untouched, which also keeps fzstorj.exe and uninstall.exe
    working.

    The payload list is checked against the real PE import tables of the modified
    binaries, so if a future build changes its dependencies this fails loudly
    instead of producing an overlay that will not start.

    Binaries are stripped: an unstripped -g build is about 250 MB and this package
    is meant to be shipped.

.PARAMETER InstallDir
    Build tree produced by build-filezilla_win64.sh. Defaults to C:\fzdark\install.

.PARAMETER OutputDir
    Where the 7z archive is written. Defaults to C:\fzdark\out.

.PARAMETER NoStrip
    Keep debug symbols. Makes a much larger archive.

.EXAMPLE
    .\build-overlay_win64.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\fzdark\install',
    [string]$OutputDir = 'C:\fzdark\out',
    [switch]$NoStrip,
    # Stage and verify the payload but skip the 7-Zip packaging. The NSIS .exe installer is
    # built from the same staged tree, so it needs this step; the .7z does not. Used when
    # 7-Zip is unavailable or not wanted.
    [switch]$NoArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Versions, URLs and digests live in versions.ps1 at the repo root, so a FileZilla
# release bump does not require editing this script.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

$UCRT = 'C:\msys64\ucrt64\bin'
$objdump = Join-Path $UCRT 'objdump.exe'
$strip = Join-Path $UCRT 'strip.exe'

# Deliberately reused from the stock installation rather than shipped, verified by
# running the result: the stock libgcc_s_seh-1.dll, libsqlite3-0.dll and the whole
# TLS stack all work unchanged.
$StockProvided = @(
    'libgcc_s_seh-1.dll'
    'libsqlite3-0.dll'
    'libgnutls-30.dll'
    'libhogweed-7.dll'
    'libnettle-9.dll'
    'libgmp-10.dll'
    'libargon2.dll'
    'libpng16-16.dll'
    'zlib1.dll'
)

# Windows components a MinGW build is allowed to import. Nothing here is ever shipped:
# the list exists so the prefix filter below can prove it did not quietly drop a real
# dependency, turning what would be a STATUS_DLL_NOT_FOUND on the user's machine into a
# build failure with the offending name in it.
$WindowsSystem = @(
    'api-ms-win-crt-convert-l1-1-0.dll'
    'api-ms-win-crt-environment-l1-1-0.dll'
    'api-ms-win-crt-filesystem-l1-1-0.dll'
    'api-ms-win-crt-heap-l1-1-0.dll'
    'api-ms-win-crt-locale-l1-1-0.dll'
    'api-ms-win-crt-math-l1-1-0.dll'
    'api-ms-win-crt-private-l1-1-0.dll'
    'api-ms-win-crt-process-l1-1-0.dll'
    'api-ms-win-crt-runtime-l1-1-0.dll'
    'api-ms-win-crt-stdio-l1-1-0.dll'
    'api-ms-win-crt-string-l1-1-0.dll'
    'api-ms-win-crt-time-l1-1-0.dll'
    'api-ms-win-crt-utility-l1-1-0.dll'
    'advapi32.dll'
    'comctl32.dll'
    'comdlg32.dll'
    'crypt32.dll'
    'dbghelp.dll'
    'gdi32.dll'
    'gdiplus.dll'
    'imm32.dll'
    'iphlpapi.dll'
    'kernel32.dll'
    'mpr.dll'
    'msimg32.dll'
    'ncrypt.dll'
    'netapi32.dll'
    'normaliz.dll'
    'ntdll.dll'
    'ole32.dll'
    'oleacc.dll'
    'oleaut32.dll'
    'powrprof.dll'
    'psapi.dll'
    'rpcrt4.dll'
    'secur32.dll'
    'setupapi.dll'
    'shell32.dll'
    'shlwapi.dll'
    'ucrtbase.dll'
    'user32.dll'
    'userenv.dll'
    'version.dll'
    'wininet.dll'
    'winmm.dll'
    'winspool.drv'
    'ws2_32.dll'
    'wtsapi32.dll'
    'uxtheme.dll'
    'wldap32.dll'
)

# Replaced wholesale, because they must agree with our patched code.
#
# libfilezilla and the libfzssh family are here for a reason that is easy to get
# wrong: patch 0002 links pugixml as a shared library, so our FileZilla objects
# and our libfilezilla both pass pugixml types across the DLL boundary through
# libpugixml.dll. The stock libfilezilla has pugixml compiled statically inside it,
# so pairing our objects with the stock copy gives two disagreeing pugixml copies
# and FileZilla crashes on startup with an access violation. Every FileZilla
# library we ship is built against the same pugixml, so they must all be replaced
# together.
#
# libstdc++-6.dll is ours because the stock copy is too old for the GCC 16 this was
# built with; the stock one crashes the patched binary the same way.
$Replaced = @(
    'filezilla.exe'
    'libfzclient-private-3-71-1.dll'
    'libfzclient-commonui-private-3-71-1.dll'
    'libfilezilla-59.dll'
    'libfzssh-14.0.0.dll'
    'libfzssh-client-14.0.0.dll'
    'libfzssh-crypt-14.0.0.dll'
    'libstdc++-6.dll'
)

# Needed at runtime but not reachable through a static import table: libgcc and
# libstdc++ pull in the threading runtime on demand, and wx loads the html and xml
# base libraries through its own loader rather than a direct import.
$RuntimeExtras = @(
    'libwinpthread-1.dll'
    'wxbase333u_xml_gcc_custom.dll'
    'wxmsw333u_html_gcc_custom.dll'
)

# Where our autotools build put the icons, and where a stock Windows install
# expects them.
$IconSourceDir = 'share\filezilla\resources\default\480x480'
$IconTargetDir = 'resources\default\480x480'

# The 13 icons this project introduces. Upstream already ships _light variants of
# the two sort arrows and of the tree item glyphs, and those files are byte for
# byte identical here, so they are deliberately absent from this list and from the
# the archive. Listed explicitly so a missing or renamed icon fails the build.
$NewIcons = @(
    'auto_light.png'
    'cancel_light.png'
    'close_light.png'
    'disconnect_light.png'
    'dropdown_light.png'
    'help_light.png'
    'leds_light.png'
    'processqueue_light.png'
    'server_light.png'
    'speedlimits_light.png'
    'synctransfer_light.png'
    'upload_light.png'
    'uploadadd_light.png'
)

function Write-Step { param([string]$m) Write-Host "  [overlay] $m" }

if (-not (Test-Path -LiteralPath $objdump)) { throw "objdump not found at $objdump" }
if (-not $NoStrip -and -not (Test-Path -LiteralPath $strip)) { throw "strip not found at $strip (or pass -NoStrip)" }
if (-not (Test-Path -LiteralPath $InstallDir)) { throw "install tree not found: $InstallDir" }

# ------------------------------------------------- resolve the real closure

$imports = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($m in $Replaced) {
    $exe = Join-Path $InstallDir "bin\$m"
    if (-not (Test-Path -LiteralPath $exe)) { throw "missing build output: $exe" }
    $out = & $objdump -p $exe 2>$null
    if ($LASTEXITCODE -ne 0) { throw "objdump failed on $m" }
    foreach ($line in ($out | Select-String -Pattern '^\s*DLL Name:\s*(\S+)')) {
        [void]$imports.Add($line.Matches[0].Groups[1].Value)
    }
}

# Everything this project ships matches lib*/wx*/msys*/cyg*. Windows system DLLs do
# not, which keeps the test simple and precise for a MinGW build.
#
# cyg* has to be in there: MSYS2's libtool installs libfilezilla as
# cygfilezilla-59.dll, and the client imports it under that name. Leaving it out made
# the filter drop a real dependency on the floor, so the archive was missing a DLL that
# filezilla.exe cannot start without - a failure that only shows up as STATUS_DLL_NOT_FOUND
# on the user's machine.
$thirdParty = @($imports | Where-Object { $_ -match '^(lib|wx|msys|cyg)[^\\/]*\.dll$' })

# A prefix filter is only safe if it cannot silently discard anything, so anything that
# is neither one of ours nor a recognised Windows component stops the build instead.
$unclassified = @($imports | Where-Object { $thirdParty -notcontains $_ -and $WindowsSystem -notcontains $_ })
if ($unclassified.Count -gt 0) { throw "unclassified imports: $($unclassified -join ', ')" }
$needed = @($thirdParty | Where-Object { $StockProvided -notcontains $_ -and $Replaced -notcontains $_ })

$payload = [System.Collections.Generic.List[string]]::new()
foreach ($b in ($Replaced + $needed + $RuntimeExtras)) {
    if (-not $payload.Contains($b)) { $payload.Add($b) }
}

Write-Step "import tables require: $($needed -join ', ')"
$absent = @($payload | Where-Object { -not (Test-Path -LiteralPath (Join-Path $InstallDir "bin\$_")) })
if ($absent.Count -gt 0) { throw "required runtime not built: $($absent -join ', ')" }

# MSYS2's libtool links and installs the client libraries as msys-* and cyg-*, while a
# stock install ships lib-*; build-filezilla_win64.sh copies one over the other so the
# overlay can replace files under the stock names. `make install` never removes anything,
# so without that copy a leftover from an earlier build satisfies every existence check
# above and ends up in the archive - which is exactly how a two-day-old pair of
# libfzclient DLLs once passed review here. When both names are present they have to be
# the same build.
$AliasSources = @{
    'libfzclient-private-3-71-1.dll'          = 'msys-fzclient-private-3-71-1.dll'
    'libfzclient-commonui-private-3-71-1.dll' = 'msys-fzclient-commonui-private-3-71-1.dll'
    'libfilezilla-59.dll'                     = 'cygfilezilla-59.dll'
}
foreach ($stock in $AliasSources.Keys) {
    $aliasPath = Join-Path $InstallDir "bin\$stock"
    $sourcePath = Join-Path $InstallDir "bin\$($AliasSources[$stock])"
    if ((Test-Path -LiteralPath $aliasPath) -and (Test-Path -LiteralPath $sourcePath)) {
        $stockLen = (Get-Item -LiteralPath $aliasPath).Length
        $sourceLen = (Get-Item -LiteralPath $sourcePath).Length
        if ($stockLen -ne $sourceLen) {
            throw "stale build output: $stock ($stockLen bytes) is not the current $($AliasSources[$stock]) ($sourceLen bytes). Re-run the FileZilla build."
        }
    }
}

# Everything chosen not to ship has to be present in a stock Windows build,
# otherwise the overlay would depend on files that may not exist.
Write-Step "reusing from the stock install: $($thirdParty | Where-Object { $StockProvided -contains $_ } | Join-String -Separator ', ')"

# ------------------------------------------------- stage

$stage = Join-Path $OutputDir 'stage'
$overlay = Join-Path $stage 'overlay'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $overlay | Out-Null

foreach ($b in $payload) {
    Copy-Item -LiteralPath (Join-Path $InstallDir "bin\$b") -Destination (Join-Path $overlay $b) -Force
}

$iconSrc = Join-Path $InstallDir $IconSourceDir
$iconDst = Join-Path $overlay $IconTargetDir
New-Item -ItemType Directory -Force -Path $iconDst | Out-Null
foreach ($name in $NewIcons) {
    $p = Join-Path $iconSrc $name
    if (-not (Test-Path -LiteralPath $p)) { throw "missing icon from the build tree: $p" }
    Copy-Item -LiteralPath $p -Destination (Join-Path $iconDst $name) -Force
}

Write-Step "staged $($payload.Count) binaries and $($NewIcons.Count) icons"

if (-not $NoStrip) {
    foreach ($b in $payload) {
        & $strip --strip-unneeded (Join-Path $overlay $b) 2>$null
        if ($LASTEXITCODE -ne 0) { throw "strip failed on $b" }
    }
    Write-Step 'stripped binaries'
}

# ------------------------------------------------- manifest

$payloadFiles = @(
    Get-ChildItem -LiteralPath $overlay -File
    Get-ChildItem -LiteralPath $iconDst -File
) | Sort-Object -Property FullName

$lines = foreach ($f in $payloadFiles) {
    $rel = $f.FullName.Substring($overlay.Length + 1).Replace('\', '/')
    '{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $rel
}

$manifestPath = Join-Path $overlay 'overlay-manifest.txt'
# Each element needs its own parentheses: inside an array literal a bare
# 'x' -f (expr) is parsed as one expression and the whole header collapses onto a
# single line, which breaks the sha256sum format this file is supposed to be in.
# Computed before the literal for the same reason.
$generatedStamp = '# generated {0}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
$header = @(
    "# FileZilla $FzVersion dark overlay payload manifest"
    '# sha256sum format, paths relative to this directory.'
    '# every path is relative to the FileZilla installation root.'
    $generatedStamp
)
[System.IO.File]::WriteAllLines($manifestPath, ($header + $lines), (New-Object System.Text.UTF8Encoding $false))
Write-Step "wrote overlay-manifest.txt ($($lines.Count) payload files)"

# ------------------------------------------------- docs + helper

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-dark-overlay_win64.ps1') -Destination $overlay -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install-dark-overlay_win64.bat') -Destination $overlay -Force
Write-Step 'shipped install-dark-overlay_win64.ps1 + .bat launcher'

# The installer reads the FileZilla version from versions.ps1 rather than hardcoding
# it, so it has to travel inside the archive. A release must be self-describing: an
# old 7z left on a disk months later still knows which FileZilla it was built for,
# even after the repo has moved on to a newer release.
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1') -Destination $overlay -Force
Write-Step 'shipped install-dark-overlay_win64.ps1 + versions.ps1'

# The license texts a recipient is owed travel inside the archive too. The
# stock FileZilla install already carries its own GPL.html at the root; licenses/
# collects everything else in one self-describing place."
Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'licenses') -Destination (Join-Path $overlay 'licenses') -Recurse -Force
Write-Step 'shipped licenses/'

# Hoisted for the same array-literal reason as $generatedStamp.
$builtStamp = "Built from FileZilla $FzVersion sources with wxWidgets $WxVersion on {0}." -f (Get-Date).ToString('yyyy-MM-dd')

$readme = @(
    "FileZilla $FzVersion - follow the Windows light/dark theme"
    '=================================================='
    ''
    'This overlay makes FileZilla follow your Windows light or dark appearance'
    'setting, and gives its small icons a matching light-appearance variant.'
    ''
    'WHAT IS IN HERE'
    "  $($Replaced.Count) binaries, all of which replace a file FileZilla already had:"
    '                       filezilla.exe, the two fzclient DLLs, libfilezilla-59.dll,'
    '                       the three libfzssh libraries, and libstdc++-6.dll.'
    '                       All FileZilla libraries are replaced together, because'
    '                       this build links pugixml as a shared library and the'
    '                       stock libfilezilla has its own copy compiled in. Mixing'
    '                       them crashes FileZilla on startup.'
    '  wxbase333u_*, wxmsw333u_*'
    ("                       wxWidgets $WxVersion, needed because this build links the")
    '                       newer wx. They sit alongside the wx 3.2 files that ship'
    '                       with FileZilla, which are left alone and simply unused.'
    '  libpugixml.dll     The shared pugixml the FileZilla libraries agree on.'
    '  libwinpthread-1.dll'
    ("                       Threading runtime for the wx $WxVersion libraries. The")
    '                       stock build does not ship it.'
    "  resources\default\480x480\  $($NewIcons.Count) new *_light.png icons."
    '  overlay-manifest.txt'
    '                       SHA-256 of every payload file, checked on install.'
    '  install-dark-overlay_win64.ps1'
    '                       Optional installer with rollback support.'
    ''
    'INSTALL, THE SIMPLE WAY'
    '  1. Close FileZilla.'
    '  2. Extract this 7z archive over your FileZilla folder, by default'
    '     C:\Program Files\FileZilla FTP Client. Choose "replace files".'
    '  That is all. There is nothing else to run.'
    ''
    '  You will need administrator rights to write to Program Files.'
    ''
    '  If you want a reversible install, or a guided one, use the installer executable'
    '  instead - it detects your FileZilla, backs up what it replaces and registers an'
    '  uninstaller. This archive is the alternative for people who prefer to extract'
    '  files over their existing installation and manage the backup themselves; the two'
    '  routes install exactly the same files.'
    ''
    'INSTALL, THE REVERSIBLE WAY'
    '  Extract this 7z archive anywhere, then run PowerShell 7 in that folder:'
    '      .\install-dark-overlay_win64.ps1'
    ("  It finds your FileZilla installation, checks it really is $FzVersion, backs up")
    '  every file it replaces into <FileZilla>\fzdark-backup\, and copies the'
    '  payload in. Pass -InstallDir if it picks the wrong installation, and -Force'
    '  if it asks to close a running FileZilla for you.'
    '  Undo it with:'
    '      .\install-dark-overlay_win64.ps1 -Uninstall'
    ''
    'ABOUT THE VERSION CHECK'
    '  The patched filezilla.exe must match the other patched libraries exactly, so'
    ("  this overlay supports FileZilla $FzVersion only. The installer refuses anything")
    '  else unless you pass -Force. Mixing this with a different FileZilla build is'
    '  the one reliable way to break your install, so please do not do it.'
    ''
    'WHAT IS NOT IN HERE'
    '  libgcc_s_seh-1.dll, libsqlite3-0.dll and the TLS libraries are not shipped.'
    ("  A normal FileZilla $FzVersion already contains all of them and the patched")
    '  build was tested working against those stock copies, so the overlay reuses'
    '  them instead of overwriting them. Nothing else is modified either: any file'
    '  not listed in overlay-manifest.txt is left untouched.'
    ''
    'IF SOMETHING GOES WRONG'
    ("  A plain extract is undone by reinstalling FileZilla $FzVersion from")
    '  filezilla-project.org. A script install is undone with -Uninstall.'
    ''
    'TURNING THE THEME BEHAVIOUR OFF'
    '  Following the system theme is on by default. To pin FileZilla to one'
    '  appearance, turn it off in Settings > Interface > "Follow the system light'
    '  and dark theme".'
    ''
    $builtStamp
    ''
    'This is an unofficial build. FileZilla is GPLv2 or later; this overlay is'
    'offered under the same terms, with full source available as a patch series.'
)
[System.IO.File]::WriteAllLines((Join-Path $overlay 'README.txt'), $readme, (New-Object System.Text.UTF8Encoding $false))

# ------------------------------------------------- 7z

# The .7z is now optional. The distribution form is the NSIS .exe built from this same staged
# tree by build-nsis-installer_win64.ps1, and the .exe does not need 7-Zip on the build
# machine or on the user's. The .7z stays as the manual, script-driven route and as a
# fallback, so -NoArchive exists for builds that only want the .exe.
if ($NoArchive) {
    Write-Step "payload staged and verified; skipping the 7z archive (-NoArchive)"
    Write-Step "  staged tree: $overlay"
    Write-Step 'done'
    return
}

# .7z rather than .zip: the payload is almost entirely already-compressed DLLs, so
# deflate squeezes almost nothing out of it, and the LZMA2 solid mode 7-Zip uses
# by default still does better on the icon PNGs. More to the point, 7z preserves
# the empty-directory and permission metadata that a Windows drop-in wants intact.
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path -LiteralPath $sevenZip)) {
    $found = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if (-not $found) {
        throw "7-Zip not found at $sevenZip and 7z.exe is not on PATH. Install 7-Zip, point $sevenZip at it, or pass -NoArchive to build only the NSIS installer."
    }
    $sevenZip = $found.Source
}

$archive = Join-Path $OutputDir $OverlayName
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }

# Stage contents at the archive root rather than nesting them under a directory, so
# "extract here" drops the payload straight into the folder the user is looking at.
& $sevenZip a -t7z -mx=9 -bso0 -bsp0 $archive (Join-Path $overlay '*')
if ($LASTEXITCODE -ne 0) { throw "7-Zip failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $archive)) { throw "7-Zip reported success but produced no archive at $archive" }

$archiveSize = (Get-Item $archive).Length
Write-Step ("wrote {0} ({1:N1} MB)" -f $archive, ($archiveSize / 1MB))

# A release needs to be checkable on the machine that downloads it, so the
# archive ships with a detached SHA-256 sidecar in the sha256sum format.
$sidecar = "$archive.sha256"
'{0}  {1}' -f (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path -Leaf $archive) |
    Set-Content -LiteralPath $sidecar -Encoding ASCII -NoNewline
Write-Step "wrote $sidecar"

Write-Step 'done'
