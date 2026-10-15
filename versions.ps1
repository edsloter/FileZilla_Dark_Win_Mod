<#
    Single source of truth for every pinned version, URL and digest in this project.

    Dot-source this file; do not execute it:

        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

    Why it exists
    -------------
    FileZilla ships a new release every few months, and porting the dark-theme patch
    series to it should be a matter of editing a handful of values in ONE file.
    Versions used to be hardcoded in eight different scripts, which meant a release
    bump meant hunting for the string "3.71.1" and hoping nothing was missed.

    To port to a new FileZilla, change $FzVersion and the values in the
    "FileZilla" block, then re-verify. Everything else derives from those.

    Digest provenance
    -----------------
    Every digest here was verified against bytes actually downloaded and built from,
    not copied from a website:

      upstream   the project publishes a .sha512 next to the download, and the
                 downloaded file matched it.
      mirror     not published upstream; pinned after confirming two independent
                 mirrors serve byte-identical copies (SHA-512 equality).
      recorded   no upstream digest and no second mirror; pinned from the local
                 download after building against it. Weaker - re-verify on a bump.

    Builds are reproducible against these digests, so a digest change is a signal
    that upstream republished or a mirror went bad, and must be investigated rather
    than blindly re-pinned.
#>

# ------------------------------------------------------------------ FileZilla ---

$FzVersion    = '3.71.1'
$FzSourceFile = "FileZilla_$($FzVersion)_src.tar.xz"
$FzPage       = 'https://filezilla-project.org/download.php?type=source'
$FzFallbackPage = 'https://filezilla-project.org/download.php'
$FzSourceSize = 3583056
$FzSourceSha512 = '44c9c9db88053a1b01ee27ebc9968eabff57d2ba6b23ac44ab080e3def9d5206cb4391dd7e0742bbd6189657a48525cfd5347d34ae87b69ccbd78b29e0101fda'
$FzSourceSha512Provenance = 'upstream'

# The filezilla-project CDN serves signed URLs that expire in about a day, so
# download.php is scraped on every run. These mirrors are unsigned and stable, and
# are tried in order once the CDN has been scraped successfully.
#
# The filename is interpolated from $FzSourceFile rather than typed out. A mirror
# list that still names the old release would silently fetch the previous tarball,
# and the digest check would then fail with a confusing "wrong hash" instead of an
# obvious "that mirror does not carry this release".
$FzSourceMirrors = @(
    "https://mirror.math.princeton.edu/pub/redcorelinux/amd64/distfiles/$($FzSourceFile)"
    "https://distfiles.gentoo.org/distfiles/7f/$($FzSourceFile)"
    "http://www.mirrorservice.org/pub/pkgsrc/distfiles/$($FzSourceFile)"
    "https://ftp.netbsd.org/pub/pkgsrc/distfiles/$($FzSourceFile)"
    "https://mirror.yandex.ru/mirrors/redcorelinux/amd64/distfiles-next/$($FzSourceFile)"
    "http://mirrors.redcorelinux.org/redcorelinux/amd64/distfiles-next/$($FzSourceFile)"
)

# The per-file manifest of the audited upstream tree. Regenerate deliberately with
# source-manifest_win64.ps1; never regenerate it just to make a build pass.
$FzManifestFile = "filezilla-$($FzVersion).sources.sha256"

# The tree the 9-patch series must produce. The build refuses to continue if the
# patched tree does not hash to this.
$FzPatchedTree = 'dc392be8ae789225c6ae7647ad9e3b0ed8fa5cbe'

# ---------------------------------------------------------------- libfilezilla ---
# Not shipped inside the client tarball: configure.ac requires it already installed.

$LibfzVersion = '0.57.0'
$LibfzFile    = "libfilezilla-$($LibfzVersion).tar.xz"
$LibfzPage    = 'https://lib.filezilla-project.org/download.php'
$LibfzSize    = 586896
$LibfzSha512  = '5cc5d87fa756ae7e74bfb7667653936b5d34fa922c00b492756bf0795afd3747835c6460f804d75121cd26f8fc8965e3dcbd2fefc2a0ca9c4d9180ecd3cf5a51'
$LibfzSha512Provenance = 'upstream'
$LibfzMinVersionForFz = '0.57.0'
# Same expiring signed-CDN scheme as FileZilla itself. Verified byte-identical
# (SHA-512 equality against the official download) on both.
$LibfzMirrors = @(
    "https://ftp.netbsd.org/pub/pkgsrc/distfiles/$($LibfzFile)"
    "http://www.mirrorservice.org/pub/pkgsrc/distfiles/$($LibfzFile)"
)

# ---------------------------------------------------------------------- fzssh ---

$FzSshVersion = '1.4.0'
$FzSshFile    = "fzssh-$($FzSshVersion).tar.xz"
$FzSshPage    = 'https://fzssh.filezilla-project.org/download.php'
$FzSshSize    = 138464
$FzSshSha512  = '51e80e97182d7cca0a8c27f3c33bf17ece35b4d2b69235024a9915cfaf9c49af83a642dd77554c6b2d21b913e9d8889bdbd18859647f560c9473a79555ed932d'
$FzSshSha512Provenance = 'upstream'
$FzSshMinVersionForFz = '1.4.0'
$FzSshMirrors = @(
    "https://ftp.netbsd.org/pub/pkgsrc/distfiles/$($FzSshFile)"
    "http://www.mirrorservice.org/pub/pkgsrc/distfiles/$($FzSshFile)"
)

# ----------------------------------------------------------------- wxWidgets ---
# Not optional: configure.ac rejects wx 3.2 outright, and 3.3 is what implements the
# system light/dark appearance this project exists to enable.

$WxVersion = '3.3.3'
$WxFile    = "wxWidgets-$($WxVersion).tar.bz2"
$WxUrl     = "https://github.com/wxWidgets/wxWidgets/releases/download/v$WxVersion/$WxFile"
$WxSize    = 32358881
$WxSha512  = '70915be3478b05f008ba50b376d0f076093bb5000aa2101f1268e1f452f6b2d33e77a31788dff232ea4dc21703c52cb2725402026ec8267aa575a74b5ed8fe45'
$WxSha512Provenance = 'upstream'
$WxRoot    = "C:\wxWidgets-$WxVersion"

# ---------------------------------------------------------------------- Boost ---
# Boost.Regex only. m4/check_regex.m4 demands it on any libstdc++ build, so
# std::regex is not an option.

$BoostVersion = '1.88.0'
$BoostFile    = "boost_$($BoostVersion -replace '\.', '_').tar.bz2"
$BoostUrl     = "https://archives.boost.io/release/$BoostVersion/source/$BoostFile"
$BoostSize    = 143894119
$BoostSha512  = 'c3a6a70e1e7d826882745ff92ac8fe7cb2a69b5974ba2275d8e130955f91163cbc4e6ccfbae19a7a92d478a8cb9de2458f73324b183596b3a2a69b1d5a75b3e9'
$BoostSha512Provenance = 'upstream'

# --------------------------------------------------------------------- SQLite ---
# configure.ac:630 requires sqlite3 >= 3.7. Only the amalgamation is used.
# NOTE: sqlite.org serves each year from a year-specific path, so $SqliteYear is a
# separate pin - bumping the version alone will 404.

$SqliteVersion = '3530400'
$SqliteYear    = '2026'
$SqliteFile    = "sqlite-amalgamation-$($SqliteVersion).zip"
$SqliteUrl     = "https://sqlite.org/$($SqliteYear)/$SqliteFile"
$SqliteSize    = 2946650
$SqliteSha512  = 'fb0cc705e5eb4c690c9eb3b5a98652895b87745bcc2c379f044a315b6b79dda520c643f7c4e5a0fdeab63c79d5cbf40ff321d67bc7c4800b840d8003cb6686be'
$SqliteSha512Provenance = 'recorded'

# ------------------------------------------------------- bootstrap toolchain ---
# PowerShell is not here any more: the scripts run on Windows PowerShell 5.1, which
# every supported Windows already has, so there is nothing to fetch and nothing to
# pin. That is the reason it can be absent rather than merely unpinned.
#
# Git is pinned, and the reason is narrower than it might look. It is NOT pinned
# because a newer Git might break the patch series - that would be speculation.
# The build leans on four commands, all stable for close to twenty years: `git am
# -3` for the 3-way merge that lets a hunk survive upstream moving its context,
# `git format-patch` to export, `git diff` to inspect, and rev-parse and friends
# for plumbing. The only output parsed back is a 40-character hash.
#
# It is pinned because bootstrap downloads a Git installer and runs it unprompted
# with administrator rights. The pin records which bytes that was: a supply-chain
# guarantee about software this kit executes as admin, not a compatibility claim.
# The same reasoning applies to wxWidgets below, where the version is additionally
# mandatory rather than merely audited.
$GitVersion = '2.56.0'
$GitFile    = "Git-$($GitVersion)-64-bit.exe"
$GitUrl     = "https://github.com/git-for-windows/git/releases/download/v$($GitVersion).windows.1/$GitFile"
$GitSize    = 66697744
$GitSha256  = 'bfe94e7b419b16eee9fecbd1253a98e3d4f49ba8f029630549052278ffe286a6'

# 7-Zip is not installed. It comes from the MSYS2 toolchain
# (mingw-w64-ucrt-x86_64-7zip), which is already a build requirement, and
# install-toolchain_win64.ps1 puts it on PATH.
#
# The msys/p7zip package is deliberately NOT used: it is the old 9.x-line
# fork, which has no PE or NSIS format handlers and answers
# "Can not open the file as archive" for an NSIS setup .exe. The ucrt64
# package is current 7-Zip and does open one.
$SevenZipExe = 'C:\msys64\ucrt64\bin\7z.exe'
$SevenZipPacmanPackage = 'mingw-w64-ucrt-x86_64-7zip'

# NSIS builds the .exe installer for the overlay. Only needed for that one artefact, so it
# is unpacked rather than installed: the setup .exe is extracted with 7-Zip, which yields a
# self-contained makensis.exe under the build root. That avoids registering anything, needs
# no elevation, and cannot collide with an NSIS the user already has.
# makensis links its own liblzma, so solid LZMA2 inside the installer costs no extra package -
# the MSYS2 'xz' package is for unpacking .tar.xz dependency tarballs and is unrelated.
#
# SourceForge is also awkward to fetch from: a plain Invoke-WebRequest is answered with an HTML
# interstitial rather than the file, which is why get-nsis_win64.ps1 uses curl and checks the
# size and digest afterwards.
#
# SourceForge is tried first, then two third-party mirrors.
#
# The mirrors are not canonical - they are ordinary file hosts, not an NSIS or SourceForge
# mirror - and they are safe to use only because of the pinned digest below: whatever they
# serve is accepted if and only if its SHA-256 equals the value taken from the upstream winget
# manifest for NSIS.NSIS 3.13. Untrusted transport, verified content, which is the same model
# every package manager uses for its mirrors. A mirror that has been re-packed, truncated or
# swapped cannot get past that check; it just fails and the next source is tried.
#
# Both mirrors were confirmed to serve the identical artifact before being listed here.
$NsisVersion = '3.13'
$NsisFile    = "nsis-$($NsisVersion)-setup.exe"
$NsisUrls    = @(
    # SourceForge, canonical.
    "https://sourceforge.net/projects/nsis/files/NSIS%203/$($NsisVersion)/$($NsisFile)/download",
    "https://downloads.sourceforge.net/project/nsis/NSIS%203/$($NsisVersion)/$($NsisFile)",
    # Third-party mirrors, used only when SourceForge is unreachable.
    "https://softaro.online/files/n/$($NsisFile)",
    "https://delivery2.filecroco.com/kits_a/$($NsisFile)"
)
$NsisSize    = 1567985
$NsisSha256  = 'db9a1038bbc0e53fef24f423fd609979bd578e942f1be1198db186d1c42652a3'

# Plain .tar.xz is used in preference to the .sfx.exe so there are no self-extractor
# flags to guess at. It unpacks to a single msys64/ directory, which is exactly the
# layout wanted under C:\.
$Msys2Stamp = '20260927'
$Msys2File  = "msys2-base-x86_64-$($Msys2Stamp).tar.xz"
$Msys2Url   = "https://repo.msys2.org/distrib/x86_64/$($Msys2File)"
$Msys2Size  = 42860696
$Msys2Sha256 = 'ea2f31a0b6ade63914ce441ffb022f0f6aa96982bfefa2326460a26d5fb01322'
$Msys2Root  = 'C:\msys64'

# ------------------------------------------------------------- fixed locations ---
# Not user-configurable: build-wx_win64.ps1 and install-toolchain_win64.ps1 both
# look here, and MSYS2 and wxWidgets both unpack to fixed paths under C:\.

$BuildRoot  = 'C:\fzdark'
$NsisRoot    = 'C:\fzdark\tools\nsis'
$NsisExe     = 'C:\fzdark\tools\nsis\makensis.exe'
$MsysBash   = 'C:\msys64\usr\bin\bash.exe'
$MsysPacman = 'C:\msys64\usr\bin\pacman.exe'
$MsysCurl   = 'C:\msys64\usr\bin\curl.exe'
$WxMakefileGcc = Join-Path $WxRoot 'build\msw\makefile.gcc'

# ------------------------------------------------------- tarball drop directory ---
# Users who would rather fetch archives themselves can drop them in here, named
# exactly as pinned. Every fetcher checks this directory FIRST, verifies against the
# pinned SHA-512, and only reaches for the network when a file is genuinely absent.
# That makes an offline or metered build possible, and it makes the pinned digest the
# single authority: bytes that arrive by either route must match the same value.
#
# Resolved from this file's own location rather than the caller's, so it is correct no
# matter which script dot-sourced versions.ps1 or from where it was run.
$TarballDir = Join-Path (Split-Path -Parent $PSCommandPath) 'tarballs'

# ---------------------------------------------------------- release artefacts ---

# Both overlay artefacts are shipped, and they install byte-identical payloads - both are
# built from the same staged, stripped tree.
#
#   .exe  the distribution form. Detects the FileZilla directory, backs up what it replaces,
#         registers an uninstaller, and needs neither 7-Zip nor PowerShell to run.
#   .7z   the manual route: extract it over an existing installation and manage the backup
#         yourself. Also carries the PowerShell installer for a guided, reversible install.
#
# The .7z is the only thing that needs 7-Zip, and only at build time; -No7z on the
# orchestrator drops it.
$OverlayName   = "FileZilla-$($FzVersion)-dark-overlay.7z"
$NsisSetupName = "FileZilla-$($FzVersion)-dark-overlay-setup.exe"

# --------------------------------------------------------------------- TLS ---
#
# The scripts run under Windows PowerShell 5.1, which is what Windows ships, so
# every download goes through .NET Framework's HttpWebRequest rather than the
# .NET Core stack PowerShell 7 uses. On .NET Framework the default
# ServicePointManager.SecurityProtocol depends on the OS and the registry, and on
# an older or hardened machine it can still be Tls12 off - or Ssl3/Tls10, both of
# which GitHub and SourceForge refuse outright. The failure looks nothing like a
# TLS problem: "The underlying connection was closed" or "Could not create SSL/TLS
# secure channel".
#
# Windows 11 with a current .NET reports SystemDefault, which already negotiates
# fine - which is exactly why this bites on one machine and not another. The -bor
# keeps whatever was already enabled and adds Tls12 beside it, so nothing that
# worked before is taken away.
#
# Done here because every script dot-sources this file, so the download paths in
# bootstrap, fetch-deps and get-filezilla-source cannot drift apart on it.
if (-not ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12)) {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# ------------------------------------------------------- native command output ---
#
# Windows PowerShell 5.1 turns a native command's stderr into a terminating error
# when ErrorActionPreference is Stop - the 2>$null redirect does NOT prevent it,
# because PowerShell wraps the native stderr in an ErrorRecord first. PowerShell 7
# does not do this, so the difference only shows up on the edition the kit targets,
# and it looks like a script bug rather than an engine difference: the reported
# failure is RemoteException with the tool's own error text as its message.
#
# That matters here because several scripts deliberately probe with commands that
# are allowed to fail - "is this patch applied", "is this package installed", "does
# this flag exist". Each of those prints to stderr and exits non-zero when the
# answer is no, which under 5.1 aborts the caller instead of yielding an empty
# result.
#
# Invoke-Native captures stdout, discards stderr, and returns the exit code
# instead of throwing, so a probe can ask its question without being able to take
# the script down. Callers that want to fail on error check $LASTEXITCODE or the
# returned code themselves.
function Invoke-Native {
    <#
        Run a native command, returning its standard output as an array of LINES.
        Standard error is discarded and a non-zero exit does NOT throw.

        Lines, not one joined string, because callers parse the output: git status
        --porcelain is one record per line and the caller does Substring on each. A
        joined blob would silently collapse every record into one, and an empty
        result would come back as an array of one empty string rather than an empty
        array, breaking .Count and every foreach over it.

        .PARAMETER File
            Executable to run.

        .PARAMETER ArgumentList
            Arguments, passed as separate items.

        .PARAMETER IgnoreExitCode
            Present so the intent is explicit at call sites that probe. A probe
            expects failure to be possible; everywhere else the caller should
            test the result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$File,

        [string[]]$ArgumentList = @(),

        [switch]$IgnoreExitCode
    )

    $stdout = @()
    $previous = $ErrorActionPreference
    try {
        # Scoped: this is the whole point. Without it, a native command writing to
        # stderr aborts the caller under 5.1.
        $ErrorActionPreference = 'Continue'
        $stdout = @(& $File @ArgumentList 2>$null)
    }
    finally {
        $ErrorActionPreference = $previous
    }

    # PowerShell hands back $null for a command with no output; normalise that to
    # an empty array so callers can rely on .Count and enumeration.
    if ($null -eq $stdout) { $stdout = @() }

    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "$File exited with code $code"
    }

    return $stdout
}

function Invoke-NativeLogged {
    <#
        Run a native command, merging its stderr into stdout so a build's warnings
        end up in the log, and return every output line. A non-zero exit does NOT
        throw - the caller decides, by testing $LASTEXITCODE or the result.

        This exists because of a Windows PowerShell 5.1 behaviour that has no
        equivalent in PowerShell 7. With ErrorActionPreference Stop, a native
        command's stderr becomes a terminating error even when merged into the
        success stream with 2>&1 and even when the command exits 0. Measured on
        both editions with a command that prints a warning to stderr and exits 0:

            pwsh 7:  captured, no throw
            5.1:     throws RemoteException, message = the warning text

        So a compiler emitting one ordinary warning aborted the build it was part
        of, and the failure named a warning rather than anything real. The
        preference is scoped to the pipeline and restored afterwards, which
        contains the change to the one call: everything outside still behaves as
        if the script had been written for 7.

        .PARAMETER File
            Executable to run.

        .PARAMETER ArgumentList
            Arguments, passed as separate items.

        .PARAMETER LogPath
            When given, all output is also written there, so the log keeps the
            interleaved stdout and stderr exactly as the tool produced it.

        .PARAMETER PassThru
            Return the output lines. Without it nothing is returned, which suits a
            long build whose output is only wanted in the log and on screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$File,

        [string[]]$ArgumentList = @(),

        [string]$LogPath,

        [switch]$PassThru,

        # Accepted for symmetry with Invoke-Native so a call site can be switched
        # between the two without thinking. This function never throws on exit code.
        [switch]$IgnoreExitCode
    )

    $output = @()
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if ($LogPath) {
            # Tee-Object keeps one stream: what the tool wrote, in the order it
            # wrote it, on screen and in the log.
            $output = @(& $File @ArgumentList 2>&1 | Tee-Object -FilePath $LogPath)
        }
        else {
            $output = @(& $File @ArgumentList 2>&1)
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($null -eq $output) { $output = @() }
    if ($PassThru) { return $output }
    return
}
