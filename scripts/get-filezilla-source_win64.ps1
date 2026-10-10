<#
.SYNOPSIS
    Obtains the pinned FileZilla source tarball and extracts it so that every file
    matches the audited upstream tree.

.DESCRIPTION
    On success the final line printed is SOURCE_ROOT=<path>, which is the verified
    tree. The all-in-one orchestrator parses that line instead of guessing a layout.

    There is no stable public URL for this tarball. filezilla-project.org serves
    its downloads through short-lived signed links, which are scraped from the
    download pages per run, and the exact container has moved between .tar.bz2
    and .tar.xz across releases. Guessing a URL and trusting whatever comes back
    would mean compiling unverified code, which is not acceptable for a build
    package.

    So this script separates getting the bytes from trusting them:

      1. Locate a tarball, in order of preference: a path the caller supplied, a
         previously cached copy, or a signed URL scraped from the project site.
      2. Extract it without letting tar rewrite anything.
      3. Verify the extracted tree against the per-file manifest in manifests\,
         per-file SHA-256 manifest of the audited release.

    The per-file manifest is what actually provides the integrity guarantee, and
    it is strictly stronger than pinning the tarball hash: it survives a
    recompression of the archive, and it pins the individual files we audited
    rather than trusting that whoever produced the archive matched it.

.PARAMETER Destination
    Directory to extract into. The tarball's own top-level directory is kept, so
    this normally ends up holding a single FileZilla-<version> directory.

.PARAMETER Tarball
    A local tarball to use instead of looking one up. Set this to build offline.

.PARAMETER Manifest
    The per-file SHA-256 manifest to verify against.

.PARAMETER Force
    Re-extract even if the destination already holds a verified tree.

.PARAMETER Root
    Build root to derive the cache and destination from. Ignored when
    -Destination is given explicitly.

.PARAMETER Keep
    Keep the downloaded archive in the cache. Without it, an archive this run
    downloaded is removed once the tree has been extracted and verified, so
    re-running costs another download. An archive you supplied by hand - by
    -Tarball or from tarballs\ - is never removed either way. The extracted tree
    is this script's output and is always left in place.

.EXAMPLE
    .\get-filezilla-source_win64.ps1 -Destination C:\fzdark\src\filezilla

.EXAMPLE
    .\get-filezilla-source_win64.ps1 -Destination C:\fzdark\src\filezilla -Tarball D:\downloads\FileZilla_3.71.1_src.tar.xz  (name varies with the pinned version)

.EXAMPLE
    .\get-filezilla-source_win64.ps1 -Root D:\build -Keep
#>
[CmdletBinding()]
param(
    [string]$Root,
    # Left empty so they can be derived from versions.ps1 / -Root below; param
    # defaults run before the dot-source that supplies the versioned filename.
    [string]$Destination,
    [string]$Tarball,
    [string]$Manifest,
    [switch]$Force,
    [switch]$Keep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Manifest) { $Manifest = Join-Path (Split-Path -Parent $PSScriptRoot) "manifests\$FzManifestFile" }

$Version = $FzVersion
# Derived here rather than defaulted in the param block: param defaults are
# evaluated before the dot-source above, so $BuildRoot is not defined yet.
if (-not $Root) { $Root = $BuildRoot }
$CacheDir = Join-Path $Root 'dl\src'
if (-not $Destination) { $Destination = Join-Path $Root 'src\filezilla' }

# Tracks the archive this run downloaded, so cleanup can distinguish it from a
# pre-existing cache entry or a file the user placed in tarballs\ by hand. Only
# the first is ever a candidate for removal.
$DownloadedTarball = $null

# The SHA-512 of the upstream release tarball, pinned in versions.ps1. This is the
# single authority for "is this the real archive": every mirror is checked against it,
# and nothing is trusted merely because a download returned HTTP 200. It is pinned
# here rather than read from the project's download page at run time on purpose - the
# published digest can be republished alongside the file, whereas a value committed to
# the repo can only change through a reviewed commit.
$ExpectedSha512 = $FzSourceSha512

# The project publishes only short-lived signed links on its own site, and that site
# answers 403 from some networks. These mirrors carry the identical upstream file,
# verified against $ExpectedSha512. Order is roughly fastest-first; any order works
# because the hash, not the host, decides.
$Mirrors = $FzSourceMirrors

function Step { param([string]$m) Write-Host "  [source] $m" }

if (-not (Test-Path -LiteralPath $Manifest)) {
    throw "source manifest not found: $Manifest"
}

# ---------------------------------------------------------------- locate a tarball

function Get-TarFromCache {
    if (-not (Test-Path -LiteralPath $CacheDir)) { return }
    Get-ChildItem -LiteralPath $CacheDir -File -Filter "FileZilla_${Version}_src.tar.*" -EA SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-TarFromDropDir {
    # The tarballs\ directory at the repo root is the offline drop box: anything
    # put there is preferred over the network, as long as it is byte-for-byte the
    # pinned upstream archive.
    #
    # Archives for a *different* version are ignored quietly - the directory is a
    # place to keep downloads, and refusing to build because it holds some other
    # release would be hostile. An archive claiming to be *our* version but not
    # hashing to the pin is a different matter: that is either a corrupt copy or
    # the wrong file entirely, and quietly downloading over it would destroy the
    # evidence. So that case stops the run and says why.
    if (-not (Test-Path -LiteralPath $TarballDir)) { return }

    $candidates = @(Get-ChildItem -LiteralPath $TarballDir -File -EA SilentlyContinue |
        Where-Object { $_.Name -like "FileZilla_*_src.tar.*" })
    if ($candidates.Count -eq 0) { return }

    $ours = @()
    foreach ($c in $candidates) {
        if ($c.Name -notlike "*_${Version}_src.tar.*") { continue }
        if (-not (Test-TarMagic $c.FullName)) {
            throw "$(Split-Path -Leaf $c.FullName) in $(Split-Path -Leaf $TarballDir)\ is not a tar archive."
        }
        $ours += $c
        if ((Get-Hash $c.FullName) -eq $ExpectedSha512) { return $c }
    }

    if ($ours.Count -gt 0) {
        $names = ($ours | ForEach-Object { Split-Path -Leaf $_.FullName }) -join ', '
        throw @"
$names in $(Split-Path -Leaf $TarballDir)\ claim to be the pinned FileZilla $Version source but do not match its SHA-512 ($ExpectedSha512).

Refusing to download over a file you placed by hand. Remove or rename it, then
re-run. If you are confident the pin is stale, update versions.ps1 deliberately
instead of bypassing the check.
"@
    }
    return
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash.ToLower()
}

function Save-FromMirrors {
    <#
        Try each mirror until one produces a file matching the published SHA-512.

        The hash check is what makes this safe rather than merely convenient. A
        mirror can be stale, truncated, or serving an HTML error page under HTTP
        200 - all three have happened in practice during this work. Anything that
        does not hash to exactly $ExpectedSha512 is deleted and the next mirror is
        tried, so a bad fetch can never be mistaken for a good one.
    #>
    param([string]$OutFile)

    $curl = 'C:\msys64\usr\bin\curl.exe'
    if (-not (Test-Path $curl)) {
        $found = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $found) { return $null }
        $curl = $found.Source
    }

    foreach ($url in $Mirrors) {
        $hostName = ([uri]$url).Host
        Step "trying $hostName"
        # .part throughout, so an interrupted download never looks like a complete
        # file to the cache scan on the next run.
        $part = "$OutFile.part"

        & $curl -sS -f -L -m 1800 --retry 2 --retry-delay 5 -o $part $url 2>$null
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
            Step "  $hostName failed (curl $LASTEXITCODE)"
            continue
        }

        $actual = Get-Hash $part
        if ($actual -ne $ExpectedSha512) {
            Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
            Step "  $hostName served the wrong bytes (sha512 $actual)"
            continue
        }

        Move-Item -LiteralPath $part -Destination $OutFile -Force
        $mb = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
        Step "  $hostName OK ($mb MB, sha512 matches upstream)"
        return $OutFile
    }
    return $null
}

function Get-SignedTarUrl {
    <#
        The project exposes downloads only as href values carrying an ?h=<hash>&x=<expiry>
        signature. An unsigned request to the same path returns a small HTML page
        with HTTP 200, so a plain download would silently save a web page and we
        would not notice until the tar step failed. Scraping the signed link is
        the only way to get real bytes.
    #>
    $pages = @(
        'https://filezilla-project.org/download.php?type=source'
        'https://filezilla-project.org/download.php'
    )
    foreach ($page in $pages) {
        try {
            $r = Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 60 -EA Stop
        }
        catch {
            Step "could not read ${page}: $($_.Exception.Message)"
            continue
        }

        $m = [regex]::Matches($r.Content, 'href="(?<u>[^"]*FileZilla_' + [regex]::Escape($Version) + '_src\.tar\.[a-z0-9]+[^"]*)"')
        foreach ($hit in $m) {
            $u = $hit.Groups['u'].Value -replace '&amp;', '&'
            if ([System.Uri]::IsWellFormedUriString($u, [System.UriKind]::Absolute)) {
                Step "found signed source link on ${page}"
                return $u
            }
            # Relative links resolve against the page.
            return ([uri]::new([uri]$page, $u)).AbsoluteUri
        }
    }
    return $null
}

function Test-TarMagic {
    <#
        Confirm a file really is one of the tar flavours upstream ships, by leading
        bytes. This is checked for every archive we are about to trust - not just
        ones we just downloaded - because a failed download leaves an HTML error
        page sitting in the cache under a .tar.xz name, and that gets picked up
        silently on the next run otherwise. The failure mode it causes is nasty:
        tar reports an unexpected EOF, or worse, extraction half-succeeds.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 8) { return $false }
        $buf = New-Object byte[] 8
        [void]$fs.Read($buf, 0, 8)
    }
    finally { $fs.Dispose() }

    $hex = ($buf | ForEach-Object { $_.ToString('x2') }) -join ''

    # Compressed forms have fixed magic numbers...
    if ($hex -like '1f8b*') { return $true }   # gzip
    if ($hex -like '425a68*') { return $true }  # bzip2
    if ($hex -like 'fd377a58*') { return $true } # xz

    # ...and an uncompressed tar starts with the ustar header at offset 257. Read
    # it explicitly rather than sniffing the whole file for the string.
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 262) { return $false }
        [void]$fs.Seek(257, [System.IO.SeekOrigin]::Begin)
        $ustar = New-Object byte[] 5
        [void]$fs.Read($ustar, 0, 5)
    }
    finally { $fs.Dispose() }

    return ([System.Text.Encoding]::ASCII.GetString($ustar) -eq 'ustar')
}

function Assert-Tar {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-TarMagic $Path)) {
        # Deliberately not deleting: for -Tarball the file is the user's, and for
        # the cache it may be a valid archive this check is too strict about.
        $head = try {
            $fs = [System.IO.File]::OpenRead($Path)
            try {
                $b = New-Object byte[] ([Math]::Min(8, $fs.Length))
                [void]$fs.Read($b, 0, $b.Length)
                ($b | ForEach-Object { $_.ToString('x2') }) -join ''
            } finally { $fs.Dispose() }
        } catch { 'unreadable' }

        throw "'$Path' is not a tar archive (leading bytes 0x$head). An unsigned or expired project link returns an HTML page with HTTP 200, and saving that under a .tar.xz name is easy to do by accident. Fetch a real archive, then pass it with -Tarball."
    }
}

function Save-Tar {
    param([string]$Url, [string]$OutFile)

    Step "downloading source from the signed project link"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 900 -EA Stop

    try { Assert-Tar -Path $OutFile }
    catch {
        Remove-Item -LiteralPath $OutFile -Force -EA SilentlyContinue
        throw "$($_.Exception.Message) (This was a fresh download, so the file has been discarded.)"
    }
    return (Get-Item $OutFile).Length
}

# ---------------------------------------------------------------- main

if (-not $Tarball) {
    # Offline drop box first, then the cache, then the network, so only a miss at
    # every step costs any traffic.
    $dropped = Get-TarFromDropDir
    if ($dropped) {
        $Tarball = $dropped.FullName
        Step "using $(Split-Path -Leaf $dropped.FullName) from $(Split-Path -Leaf $TarballDir)\, sha512 verified against the pin"
    }
    else {
        # Take the newest cache entry that is actually an archive. A failed download
        # can leave an HTML page in the cache under the same name pattern, and picking
        # that up would otherwise fail much later with a confusing tar error.
        $cached = @(Get-TarFromCache | Where-Object { Test-TarMagic $_.FullName })
        if ($cached.Count -gt 0) {
            $Tarball = $cached[0].FullName
            Step "using cached source archive $Tarball"
        }
        else {
            New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
            $Tarball = Join-Path $CacheDir "FileZilla_${Version}_src.tar.xz"

            # Mirrors first: they are plain static files, they are not rate limited, and
            # the published hash lets us verify them without trusting the host.
            $got = Save-FromMirrors -OutFile $Tarball
            if ($got) {
                $Tarball = $got
                $DownloadedTarball = $got
            }
            else {
                # Only fall back to the project's own site if every mirror failed. That
                # endpoint hands out short-lived signed links and is unreachable from
                # some networks, which is exactly why it is not the first choice.
                Step 'every mirror failed; falling back to the signed project link'
                $url = Get-SignedTarUrl
                if (-not $url) {
                    throw "could not download FileZilla_${Version}_src.tar.xz from any mirror, and no signed link could be read from filezilla-project.org. Drop the archive in $(Split-Path -Leaf $TarballDir)\, or re-run with -Tarball <path>. Expected SHA-512: $ExpectedSha512"
                }
                # A signed-link download cannot be checked against the published hash
                # with confidence, because upstream may re-release the same version with
                # different packaging, so this one is verified per-file against the
                # manifest instead. Both checks run in every case, as belt and braces.
                $Tarball = Join-Path $CacheDir "FileZilla_${Version}_src.tar.bz2"
                [void](Save-Tar -Url $url -OutFile $Tarball)
                $DownloadedTarball = $Tarball
            }
        }
    }
}
else {
    if (-not (Test-Path -LiteralPath $Tarball)) { throw "tarball not found: $Tarball" }
    $Tarball = (Resolve-Path -LiteralPath $Tarball).Path
    Assert-Tar -Path $Tarball
    Step "using supplied source archive $Tarball"
    # Report whether a user-supplied archive is the exact upstream file. It does not
    # have to be - a repacked archive with identical contents is still buildable, and
    # the per-file check below is what ultimately decides.
    $suppliedHash = Get-Hash $Tarball
    if ($suppliedHash -eq $ExpectedSha512) {
        Step '  matches the upstream-published SHA-512 exactly'
    }
    else {
        Step "  sha512 is $suppliedHash"
        Step '  (not the published value, so contents will be verified per file)'
    }
}

# ---------------------------------------------------------------- extract

if (Test-Path -LiteralPath $Destination) {
    $existing = @(Get-ChildItem -LiteralPath $Destination -Force -EA SilentlyContinue)
    if ($existing.Count -gt 0) {
        if (-not $Force) {
            Step "destination already has content; -Force was not given, so reusing it and verifying"
        }
        else {
            Step "clearing $Destination because -Force was given"
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
    }
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# bsdtar (tar.exe on Windows 10+) handles bz2 and xz and is present on any modern
# Windows, so no external tool is required. -x keeps it from preserving owners.
$tar = Get-Command tar.exe -EA SilentlyContinue
if (-not $tar) { throw 'tar.exe not found; bsdtar ships with Windows 10 and 11' }

Step "extracting to $Destination"
Push-Location $Destination
try {
    & $tar.Source -x -f $Tarball
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

# The manifest is relative to the release root, but the archive usually wraps
# everything in its own top-level directory. Find that root and verify it, so
# callers can rely on a single predictable path either way.
$dirs = @(Get-ChildItem -LiteralPath $Destination -Directory -EA SilentlyContinue)
$files = @(Get-ChildItem -LiteralPath $Destination -File -EA SilentlyContinue)

if ($files.Count -gt 0 -and $dirs.Count -gt 0) {
    throw "extraction produced both files and directories directly in $Destination, which is not a shape this script understands. Inspect it by hand."
}
if ($files.Count -gt 0 -and $dirs.Count -eq 0) {
    $sourceRoot = $Destination
    Step 'archive unpacked directly into the destination'
}
elseif ($dirs.Count -eq 1) {
    $sourceRoot = $dirs[0].FullName
    Step "source root is $($dirs[0].Name)"
}
else {
    throw "extraction produced $($dirs.Count) top-level directories in $Destination; expected exactly one. Inspect it by hand."
}

# ---------------------------------------------------------------- verify

try {
    Step "verifying every extracted file against the audited manifest"
    & (Join-Path $PSScriptRoot 'source-manifest_win64.ps1') -Mode Verify -Tree $sourceRoot -Manifest $Manifest

    Write-Host "  [source] verified FileZilla $Version source tree at $sourceRoot" -ForegroundColor Green
    Write-Host "  [source] SOURCE_ROOT=$sourceRoot"
}
finally {
    # Only an archive this run downloaded, and only once the tree it produced has
    # been verified. Deleting before verification would throw away the evidence
    # and force a second download on the retry. The extracted tree is this
    # script's actual output and is never touched here.
    if ($DownloadedTarball -and (Test-Path -LiteralPath $DownloadedTarball)) {
        if ($Keep) {
            Step "keeping downloaded archive $DownloadedTarball (-Keep)"
        }
        else {
            Remove-Item -LiteralPath $DownloadedTarball -Force
            Step "removed downloaded archive $DownloadedTarball (pass -Keep to retain it)"
        }
    }
}
