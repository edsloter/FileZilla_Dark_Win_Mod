<#
.SYNOPSIS
    Unpacks a portable NSIS into <root>\tools\nsis so the overlay installer .exe can be built.

.DESCRIPTION
    NSIS is only needed to produce FileZilla-<ver>-dark-overlay-setup.exe, and only
    makensis.exe is used, so the setup .exe is extracted rather than installed. That
    keeps this build toolchain-free: nothing is registered, no elevation is needed, and
    it cannot disturb an NSIS the user already has on the machine.

    The fetch uses curl, not Invoke-WebRequest. SourceForge answers a plain
    Invoke-WebRequest for the /download URL with an HTML interstitial, which arrives as
    a ~145 KB "download" that is really a web page; the size and digest checks below are
    what catch that, and curl -L is what actually gets the PE.

    If makensis already reports the pinned version the download is skipped entirely,
    which is the normal case on a rebuild.

.PARAMETER Root
    Build root. Tools land under <root>\tools\nsis.

.PARAMETER Keep
    Retain the downloaded setup .exe. Without it the archive is deleted on success.

.PARAMETER Force
    Re-extract even if makensis is already present.

.EXAMPLE
    .\get-nsis_win64.ps1
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Keep,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Root) { $Root = $BuildRoot }

function Write-Step { param([string]$m) Write-Host "  [nsis] $m" }

function Test-Makensis {
    # Version is compared against the pin so a stale or foreign makensis is never used to
    # build the artefact.
    #
    # The exit code is deliberately not checked. Under Set-StrictMode, $LASTEXITCODE is not
    # even set when a native command's output is piped into Select-Object, so reading it here
    # throws "The variable '$LASTEXITCODE' cannot be retrieved". The version string is enough:
    # makensis -VERSION prints it on success and nothing on failure.
    if (-not (Test-Path -LiteralPath $NsisExe)) { return $null }
    $v = (& $NsisExe -VERSION 2>$null | Select-Object -First 1)
    if (-not $v) { return $null }
    $v = "$v".Trim()
    if ($v -notlike "v$($NsisVersion)*") { return $null }
    return [pscustomobject]@{ Path = $NsisExe; Version = $v }
}

if (-not $Force) {
    $have = Test-Makensis
    if ($have) {
        Write-Step "makensis $($have.Version) already at $($have.Path)"
        return
    }
}

$tools = Join-Path $Root 'tools'
$nsisDir = Join-Path $tools 'nsis'
$dlDir = Join-Path $Root 'downloads'
$archive = Join-Path $dlDir $NsisFile

New-Item -ItemType Directory -Force -Path $tools, $dlDir | Out-Null

# ------------------------------------------------- obtain and verify the archive
#
# Checked after every source, not once at the end: a mirror that answers with something else -
# an HTML interstitial, a truncated file, a re-packed build - must be passed over in favour of
# the next source rather than aborting a run that had a perfectly good third option. The pinned
# digest is the only thing that decides, so no source is trusted for anything but transport.
function Test-NsisArchive {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'no file arrived'
    }

    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -ne $NsisSize) {
        # A plausible name with the wrong size is nearly always an HTML page saved as .exe.
        $looksHtml = ((Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction SilentlyContinue) -match '^\s*<')
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($looksHtml) { return "got an HTML page instead of the installer ($len bytes)" }
        return "wrong size: $len bytes, expected $NsisSize"
    }

    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $NsisSha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return "sha256 mismatch: got $hash"
    }
    return $null
}

if (Test-Path -LiteralPath $archive) {
    Write-Step "using cached $($NsisFile)"
    $why = Test-NsisArchive -Path $archive
    if ($why) { throw "the cached $($NsisFile) in $dlDir is not usable ($why). Delete it to download a fresh copy." }
}
else {
    Write-Step "downloading $($NsisFile) ($([math]::Round($NsisSize / 1MB, 2)) MB)"

    # curl rather than Invoke-WebRequest, and with conservative network settings, because
    # SourceForge is awkward both ways:
    #   * a plain Invoke-WebRequest is answered with an HTML interstitial, which arrives as a
    #     145 KB "download" that is really a web page. curl -L follows the redirect to the PE.
    #   * a VM behind a filtering middlebox fails the TLS handshake outright, with
    #     "curl: (35) ... unexpected eof while reading". Forcing IPv4 avoids the usual IPv6
    #     black hole, --http1.1 sidesteps HTTP/2 negotiation, and --retry-all-errors makes curl
    #     retry on that failure rather than only on HTTP errors.
    $part = "$archive.part"
    $errors = @()
    foreach ($url in $NsisUrls) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Write-Step "  trying $url"
        & $MsysCurl -sSL --fail -4 --http1.1 `
            --retry 3 --retry-delay 3 --retry-connrefused --retry-all-errors `
            --connect-timeout 30 --max-time 900 `
            -o $part $url
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            $errors += "$url (curl exit $rc)"
            Write-Step "  unreachable or failing (curl exit $rc)"
            continue
        }
        Move-Item -LiteralPath $part -Destination $archive -Force
        $why = Test-NsisArchive -Path $archive
        if (-not $why) {
            Write-Step "  downloaded and verified from $url"
            break
        }
        $errors += "$url ($why)"
        Write-Step "  rejected: $why"
    }
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $archive)) {
        throw ("could not obtain $($NsisFile). Tried:" +
            "`n  " + ($errors -join "`n  ") +
            "`nThis is normally a network or TLS filtering problem reaching SourceForge, not a wrong" +
            "`npin - the digest is only ever checked against bytes that actually arrived." +
            "`n`nWorkaround: download $($NsisFile) in a browser and drop it in" +
            "`n  $dlDir`nIt is verified against the pinned SHA-256 before anything is unpacked.")
    }
}
Write-Step "verified $($NsisFile) sha256"

# --------------------------------------------------------------- extract

Remove-Item -LiteralPath $nsisDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $nsisDir | Out-Null

# 7-Zip unpacks an NSIS setup fine. It is the one hard dependency of this script, and
# bootstrap_win64.ps1 already installs it.
if (-not (Test-Path -LiteralPath $SevenZipExe)) {
    throw "7-Zip not found at $SevenZipExe - needed to unpack $($NsisFile). Run bootstrap_win64.ps1, or pass -SevenZipExe."
}
& $SevenZipExe x $archive "-o$nsisDir" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to unpack $($NsisFile) (exit $LASTEXITCODE)" }

if (-not (Test-Path -LiteralPath $NsisExe)) {
    throw "unpack succeeded but makensis.exe is not at $NsisExe"
}

$have = Test-Makensis
if (-not $have) {
    throw "makensis.exe unpacked but -VERSION did not report v$($NsisVersion)"
}
Write-Step "makensis $($have.Version) ready at $($have.Path)"

if (-not $Keep) {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
}
