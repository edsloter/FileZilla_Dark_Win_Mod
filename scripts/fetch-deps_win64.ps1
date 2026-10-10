<#
.SYNOPSIS
    Downloads and verifies every external dependency needed to build FileZilla.

.DESCRIPTION
    Versions, URLs and digests all come from versions.ps1 at the repo root - nothing
    is pinned here, so a FileZilla release bump is a one-file change.

    FileZilla's own stack (libfilezilla, fzssh) is not part of the client tarball -
    configure.ac requires both to be already installed. This script fetches them
    plus the remaining external prerequisites:

      * Boost.Regex  - m4/check_regex.m4 unconditionally demands it on any
                       libstdc++ build, so we cannot use std::regex.
      * SQLite3      - configure.ac requires sqlite3 >= 3.7
      * wxWidgets    - configure.ac rejects 3.2 outright; 3.3 is what implements the
                       system light/dark appearance this project exists to provide.

    libfilezilla, fzssh and FileZilla itself are all published as signed CDN URLs
    that expire in about a day, so a fresh URL is scraped from the relevant
    download.php page on every run. Each falls back to unsiged mirrors when the
    scrape fails; those mirrors were verified to serve byte-identical files, and the
    pinned SHA-512 is what makes the fallback safe.

      Every artefact is verified against a pinned SHA-512 from versions.ps1. A digest
      change is therefore a signal to investigate, not something to re-pin blindly.
      The pin is authoritative even when the project publishes a digest of its own:
      a published value can be republished alongside the file, the pin can only
      change through a reviewed commit here.
  
      Archives placed by hand in the tarballs\ directory at the repo root are used in
      preference to downloading, provided they match the pin. A file there that does
      NOT match is reported and the run stops, rather than being overwritten - see
      tarballs\README.md.
  
      Only missing artefacts are downloaded. Anything already present and verified
      costs no network traffic at all.
  
  .PARAMETER Keep
      Retain the archives after fetching. Without it, archives this run downloaded are
      removed again on the way out, so a build leaves nothing behind. Archives supplied
      by hand are never removed either way.
  
  .OUTPUTS
      <build root>\dl\<artefact>
      <build root>\dl\SHA512SUMS.txt
  #>

[CmdletBinding()]
param(
    # Re-download and re-verify artefacts even if already present.
    [switch]$Force,
    # Override the build root. Must match the orchestrator's -Root.
    [string]$Root = 'C:\fzdark',
    # Keep the downloaded archives. Without this they are removed on the way out, so
    # a build leaves nothing behind. Archives you placed in the drop directory are
    # never touched either way - they are yours, not ours.
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

# Every version, URL and digest lives in one file so a release bump is one edit.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

$dl = Join-Path $Root 'dl'
$curl = $MsysCurl
$sums = Join-Path $dl 'SHA512SUMS.txt'

New-Item -ItemType Directory -Force -Path $dl | Out-Null

# Archives this run fetched itself, and may therefore delete again. User-supplied
# files from the drop directory are deliberately absent from this list.
$script:Downloaded = [System.Collections.Generic.List[string]]::new()


# ---------------------------------------------------------------- helpers ---

function Get-RecordedHash {
    param([string]$Name)
    if (-not (Test-Path $sums)) { return $null }
    # Multiline is required, not cosmetic. Without it ^ and $ anchor to the start and
    # end of the whole file, so only the first entry was ever found and every
    # recorded digest silently read back as $null - which made verification a no-op
    # and let a changed archive be re-recorded as trusted.
    $text = [System.IO.File]::ReadAllText($sums)
    $m = [regex]::Match($text, ('^' + [regex]::Escape($Name) + '\s+(\S+)$'),
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Set-RecordedHash {
    param([string]$Name, [string]$Hash)

    $entries = [ordered]@{}
    if (Test-Path $sums) {
        foreach ($line in [System.IO.File]::ReadAllLines($sums)) {
            if (-not $line.Trim()) { continue }
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2) { $entries[$parts[0]] = $parts[1].Trim() }
        }
    }
    $entries[$Name] = $Hash

    # Explicit LF and a single trailing newline: the reader above needs one entry
    # per line, and Set-Content's default encoding/line endings have bitten this
    # file before.
    $body = (@($entries.Keys | Sort-Object | ForEach-Object { "$_ $($entries[$_])" }) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($sums, $body, [System.Text.UTF8Encoding]::new($false))
}

# Some projects publish a <file>.sha512 sitting next to the download.
function Get-RemoteHashFile {
    param([string]$Url)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # Not every project publishes a .sha512 next to the download, so a 404 here
        # is an expected outcome and not an error. curl's stderr is captured rather
        # than shown, because printing "error 404" for a normal case reads like the
        # run has gone wrong.
        & $curl -s -f -m 60 -L -o $tmp "$Url.sha512" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $m = [regex]::Match((Get-Content $tmp -Raw), '([0-9a-fA-F]{128})')
        if ($m.Success) { return $m.Value.ToLower() }
        return $null
    }
    catch { return $null }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# Scrape the currently valid (signed) CDN URL for a file from a download.php page.
function Get-SignedUrl {
    param([string]$Page, [string]$FileName)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # stderr is discarded because a failure here is handled by falling back to a
        # mirror, and curl's raw "Could not resolve host" noise would otherwise be
        # printed alongside the warning that already explains what happened.
        & $curl -sS -m 60 -L -o $tmp $Page 2>$null
        if ($LASTEXITCODE -ne 0) { throw "curl failed ($LASTEXITCODE) fetching $Page" }
        $html = Get-Content $tmp -Raw
        $pattern = 'https://[^"''<> ]*' + [regex]::Escape($FileName) + '\?[^"''<> ]*'
        $m = [regex]::Match($html, $pattern)
        if (-not $m.Success) { throw "no signed URL for $FileName found on $Page" }
        return $m.Value
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# Pull the SHA-512 that the project publishes next to the download page.
function Get-PublishedHash {
    param([string]$Page, [string]$FileName)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & $curl -sS -m 60 -L -o $tmp $Page
        $html = Get-Content $tmp -Raw
        $m = [regex]::Match($html, [regex]::Escape($FileName) + '</a>.*?SHA-512 hash:</strong>\s*([0-9a-f]{128})', 'Singleline')
        if ($m.Success) { return $m.Groups[1].Value }
        return $null
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------- drop directory ---

# Look for an archive the user placed in tarballs/ by hand.
#
# Returns the verified path, or $null if none of the acceptable names are there.
#
# A file that is present but WRONG is a hard error rather than a re-download. Two
# reasons: the user may have grabbed the wrong release and needs to be told, and
# quietly overwriting a file someone placed by hand is how a plausible-looking but
# unaudited archive reaches a build.
function Get-DroppedArtifact {
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Sha512,
        [long]$Size = 0
    )

    $found = @()
    foreach ($n in $Names) {
        $p = Join-Path $TarballDir $n
        if (Test-Path -LiteralPath $p -PathType Leaf) { $found += $p }
    }
    if ($found.Count -eq 0) { return $null }

    foreach ($p in $found) {
        $len = (Get-Item -LiteralPath $p).Length
        $actual = (Get-FileHash -LiteralPath $p -Algorithm SHA512).Hash.ToLower()
        $want = $Sha512.ToLower()

        if ($actual -eq $want -and ($Size -le 0 -or $len -eq $Size)) {
            Write-Host ("  [drop]  {0} (from tarballs\, sha512 verified)" -f (Split-Path -Leaf $p))
            return $p
        }

        $why = if ($actual -ne $want) { "has sha512 $actual but $want is pinned" }
               else { "is $len bytes but $Size are pinned" }
        throw @"
$(Split-Path -Leaf $p) is present in tarballs\ but is not the pinned artefact: it $why.

Refusing to download over a file you placed by hand. Remove or rename it, then
re-run. If you are confident the pin is stale, update versions.ps1 deliberately
instead of bypassing the check.
"@
    }

    return $null
}

# Adopt a user-supplied archive into the build's own cache, so the later extract and
# build steps read it from one predictable place.
function Import-DroppedArtifact {
    param([string]$Path)
    $dest = Join-Path $dl (Split-Path -Leaf $Path)
    if ([System.IO.Path]::GetFullPath($Path) -ne [System.IO.Path]::GetFullPath($dest)) {
        Copy-Item -LiteralPath $Path -Destination $dest -Force
    }
    return $dest
}

function Get-Artifact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [string]$Sha512,
        [long]$Size = 0
    )

    $dest = Join-Path $dl $Name

    if ((Test-Path $dest) -and -not $Force) {
        $actual = (Get-FileHash -Path $dest -Algorithm SHA512).Hash.ToLower()
        $expect = if ($Sha512) { $Sha512.ToLower() } else { Get-RecordedHash $Name }
        if ($expect -and $actual -eq $expect) {
            Write-Host "  [ok]    $Name (already present, sha512 verified)"
            return $dest
        }
        Write-Host "  [stale] $Name (hash mismatch) - re-downloading"
        Remove-Item $dest -Force
    }

    Write-Host "  [get]   $Name"
    Write-Host "         $Url"
    # -L is not optional. GitHub's release downloads answer 302 to a
    # release-assets.githubusercontent.com URL; without -L curl writes the empty
    # redirect body and the download "succeeds" with zero bytes. -f likewise
    # matters: without it a 404 HTML page is happily written to the .part.
    & $curl -sS -f -L -m 1800 --retry 3 --retry-delay 5 -o "$dest.part" $Url
    if ($LASTEXITCODE -ne 0) { throw "curl failed ($LASTEXITCODE) downloading $Name" }

    # Size is checked BEFORE the digest, and the .part is only promoted once it
    # passes. A truncated transfer - a dropped connection, an expired redirect, a
    # proxy returning an empty 200 - otherwise surfaces as a SHA-512 mismatch
    # against the hash of a zero-byte file, which reads like tampering rather than
    # the boring network problem it almost always is.
    $part = "$dest.part"
    $len = (Get-Item -LiteralPath $part).Length
    if ($len -eq 0) {
        Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
        throw "$Name : the download produced an empty file (the URL most likely expired mid-transfer). Re-run to try again."
    }
    if ($Size -gt 0 -and $len -ne $Size) {
        Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
        throw "$Name : truncated download, got $len bytes but $Size were expected. Re-run to try again."
    }

    Move-Item -Force $part $dest

    $actual = (Get-FileHash -Path $dest -Algorithm SHA512).Hash.ToLower()

    if ($Sha512) {
        if ($actual -ne $Sha512.ToLower()) {
            Remove-Item $dest -Force
            throw "SHA-512 MISMATCH for $Name`n  expected $($Sha512.ToLower())`n  actual   $actual`n  The transfer completed but the bytes are not the pinned artefact. If you did not`n  put this file in tarballs\, treat it as a corrupted or substituted download."
        }
        Write-Host "  [hash]  sha512 verified against upstream"
    }
    else {
        if (-not (Get-RecordedHash $Name)) {
            Set-RecordedHash $Name $actual
            Write-Host "  [hash]  sha512 recorded (no upstream digest published): $actual"
        }
        elseif ((Get-RecordedHash $Name) -ne $actual) {
            Remove-Item $dest -Force
            throw "SHA-512 MISMATCH for $Name vs recorded dl\SHA512SUMS.txt entry"
        }
    }

    if ($Size -gt 0 -and $len -ne $Size) {
        throw "size mismatch for $Name : expected $Size, got $len"
    }
    Write-Host ("  [done]  {0}  ({1:N0} bytes)" -f $Name, $len)
    # Ours, so a run without -Keep may remove it again.
    if (-not $script:Downloaded.Contains($dest)) { $script:Downloaded.Add($dest) }
    return $dest
}

# ------------------------------------------------------------------ fetch ---

Write-Host "Fetching dependencies into $dl`n"

# Check the cache BEFORE touching the network. Scraping a signed URL costs two HTTP
# round-trips, and doing that for artefacts already on disk and verified is pure
# waste - it is also what made every re-run of the build hit the network.
function Test-Cached {
    param([string]$Name, [string]$Sha512, [long]$Size = 0)
    $dest = Join-Path $dl $Name
    if (-not (Test-Path -LiteralPath $dest)) { return $false }
    if ($Size -gt 0 -and (Get-Item -LiteralPath $dest).Length -ne $Size) { return $false }
    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA512).Hash.ToLower() -ne $Sha512.ToLower()) { return $false }
    return $true
}

# FileZilla, libfilezilla and fzssh are all published the same way: a signed CDN
# link scraped from a download.php page, expiring in about a day. If the scrape
# fails - page moved, CDN blocked, rate limited - fall back to unsiged mirrors,
# which are stable and were verified to serve byte-identical files. The pinned
# SHA-512 is what makes that fallback safe.
function Get-CdnArtifact {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Page,
        [Parameter(Mandatory)][string[]]$Mirrors,
        [Parameter(Mandatory)][string]$Sha512,
        [long]$Size = 0
    )

    if (-not $Force) {
        if (Test-Cached -Name $Name -Sha512 $Sha512 -Size $Size) {
            Write-Host "  [ok]    $Name (already present, sha512 verified)"
            return
        }
        $dropped = Get-DroppedArtifact -Names @($Name) -Sha512 $Sha512 -Size $Size
        if ($dropped) {
            Import-DroppedArtifact -Path $dropped | Out-Null
            return
        }
    }

    $via = 'signed CDN'
    $url = $null
    try {
        $url = Get-SignedUrl -Page $Page -FileName $Name
    }
    catch {
        Write-Warning "$Name : could not scrape a signed URL from $Page"
        Write-Warning "$Name : $($_.Exception.Message)"
    }

    if ($url) {
        try {
            # Get-Artifact already prints "[get] <name>" and the URL it used, so
            # nothing is echoed here.
            #
            # The PINNED digest is what the bytes are checked against. The digest
            # published on the download page is only used to notice that upstream has
            # moved on: it is never allowed to replace the pin, because the published
            # value can be republished alongside the file, whereas the pin only
            # changes through a reviewed commit in this repo.
            $pub = Get-PublishedHash $Page $Name
            if ($pub -and $pub -ne $Sha512.ToLower()) {
                Write-Warning "$Name : upstream now publishes sha512 $pub, but this repo pins $($Sha512.ToLower())."
                Write-Warning "$Name : keeping the pin. If this is a genuine new release, update versions.ps1 deliberately."
            }
            Get-Artifact -Name $Name -Url $url -Size $Size -Sha512 $Sha512 | Out-Null
            return
        }
        catch {
            Write-Warning "$Name : signed CDN download failed - $($_.Exception.Message)"
        }
    }

    if (-not $Mirrors -or $Mirrors.Count -eq 0) {
        throw "could not obtain $Name from the signed CDN and no mirror is configured"
    }
    Write-Warning "$Name : falling back to $($Mirrors.Count) unsiged mirror(s)"
    foreach ($m in $Mirrors) {
        try {
            Get-Artifact -Name $Name -Url $m -Size $Size -Sha512 $Sha512 | Out-Null
            return
        }
        catch {
            Write-Warning "$Name : mirror failed - $($_.Exception.Message)"
        }
    }
    throw "could not obtain $Name from the signed CDN or any of $($Mirrors.Count) mirrors"
}

function Get-SimpleArtifact {
    # A plain stable URL: no signed CDN, no mirror list. Still drop-dir first.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Sha512,
        [long]$Size = 0
    )

    if (-not $Force) {
        if (Test-Cached -Name $Name -Sha512 $Sha512 -Size $Size) {
            Write-Host "  [ok]    $Name (already present, sha512 verified)"
            return
        }
        $dropped = Get-DroppedArtifact -Names @($Name) -Sha512 $Sha512 -Size $Size
        if ($dropped) {
            Import-DroppedArtifact -Path $dropped | Out-Null
            return
        }
    }
    Get-Artifact -Name $Name -Url $Url -Size $Size -Sha512 $Sha512 | Out-Null
}

try {
    # 1. libfilezilla >= $LibfzMinVersionForFz   (configure.ac requires it preinstalled)
    Get-CdnArtifact -Name $LibfzFile -Page $LibfzPage -Mirrors $LibfzMirrors `
        -Sha512 $LibfzSha512 -Size $LibfzSize

    # 2. libfzssh-client >= $FzSshMinVersionForFz  (as above)
    Get-CdnArtifact -Name $FzSshFile -Page $FzSshPage -Mirrors $FzSshMirrors `
        -Sha512 $FzSshSha512 -Size $FzSshSize

    # 3. Boost headers, for building libboost_regex.a (see test-boost-regex_win64.ps1)
    Get-SimpleArtifact -Name $BoostFile -Url $BoostUrl -Sha512 $BoostSha512 -Size $BoostSize

    # 4. SQLite3 amalgamation  (configure.ac requires sqlite3 >= 3.7)
    Get-SimpleArtifact -Name $SqliteFile -Url $SqliteUrl -Sha512 $SqliteSha512 -Size $SqliteSize

    # 5. wxWidgets.  Not an optional nicety: configure.ac rejects wx 3.2 outright and
    # FileZilla will not build against it, because 3.3 is what implements the system
    # light/dark appearance this whole project exists to enable.
    Get-SimpleArtifact -Name $WxFile -Url $WxUrl -Sha512 $WxSha512 -Size $WxSize

    $script:Ok = $true
}
finally {
    # Cleanup runs on the failure path too. A half-finished fetch that leaves a
    # verified 138 KB archive behind is untidy, and worse, it makes the next run
    # report "[ok] already present" for something the previous run only just
    # managed to fetch - which reads as though the download had succeeded.
    if ($Keep) {
        Write-Host "`nKeeping downloaded archives in $dl (-Keep)."
    }
    else {
        $removed = 0
        foreach ($f in $script:Downloaded) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $removed++ }
        }
        Write-Host "`nRemoved $removed downloaded archive(s). Pass -Keep to retain them."
        Write-Host "Archives you supplied in $(Split-Path -Leaf $TarballDir)\ were left untouched."
    }
}

Write-Host "`nAll dependencies present and verified."
Get-ChildItem $dl -File | Select-Object Name, @{n='Bytes';e={'{0:N0}' -f $_.Length}} | Format-Table -AutoSize | Out-String -Width 100 | Write-Host
