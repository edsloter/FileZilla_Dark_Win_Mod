<#
.SYNOPSIS
    Creates or verifies a per-file SHA-256 manifest of a FileZilla source tree.

.DESCRIPTION
    The upstream release tarball cannot be pinned by a single hash from our side,
    because the filezilla-project CDN only serves files through short-lived signed
    URLs that are scraped per run, and the container format is not stable enough to
    rely on. Hashing the extracted tree instead is both stronger and portable: it
    proves we are compiling exactly the sources that were audited, and it does not
    care whether the tarball was .tar.bz2 or .tar.xz, nor which tar implementation
    produced it.

    Manifest format is the sha256sum convention, one "<sha256>  <path>" per line,
    LF terminated, paths relative to the tree root with forward slashes and sorted
    ordinally. That means `sha256sum -c` works on it too, on any platform.

.PARAMETER Mode
    Create or Verify.

.PARAMETER Tree
    Root of the tree to hash or check.

.PARAMETER Manifest
    Manifest file to write (Create) or read (Verify).

.EXAMPLE
    .\source-manifest_win64.ps1 -Mode Create -Tree C:\fzdark\src\FileZilla-<version> `
        -Manifest C:\fzdark\repo\manifests\filezilla-<version>.sources.sha256

.EXAMPLE
    .\source-manifest_win64.ps1 -Mode Verify -Tree C:\fzdark\src\FileZilla-<version> `
        -Manifest C:\fzdark\repo\manifests\filezilla-<version>.sources.sha256
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Create', 'Verify')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$Tree,

    [Parameter(Mandatory)]
    [string]$Manifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Tree -PathType Container)) {
    throw "tree not found: $Tree"
}
$Tree = (Resolve-Path -LiteralPath $Tree).Path

function Get-TreeHashes {
    param([string]$Root)

    $prefixLen = $Root.Length + 1
    $result = [System.Collections.Generic.List[object]]::new()

    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($prefixLen).Replace('\', '/')
        # A git work tree or an in-tree build would make the manifest depend on
        # local state, so refuse rather than silently produce a useless file.
        if ($rel -match '(^|/)\.git(/|$)') { continue }
        $result.Add([pscustomobject]@{
            Path = $rel
            Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        })
    }

    return $result
}

$entries = Get-TreeHashes -Root $Tree

# Ordinal sort so the manifest is byte-stable regardless of locale.
$sorted = $entries | Sort-Object -Property Path -CaseSensitive

switch ($Mode) {

    'Create' {
        $lines = $sorted | ForEach-Object { "$($_.Hash)  $($_.Path)" }
        # Write LF explicitly. Set-Content would emit CRLF on Windows, which makes
        # the manifest itself differ between machines.
        $text = ($lines -join "`n") + "`n"
        $dir = Split-Path -Parent $Manifest
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($Manifest, $text, (New-Object System.Text.UTF8Encoding $false))

        Write-Host ("  [manifest] {0} files, {1} bytes of tree" -f $entries.Count, ((Get-ChildItem -LiteralPath $Tree -Recurse -File -Force | Measure-Object Length -Sum).Sum))
        Write-Host ("  [manifest] written to {0}" -f $Manifest)
    }

    'Verify' {
        if (-not (Test-Path -LiteralPath $Manifest)) {
            throw "manifest not found: $Manifest"
        }

        $expected = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($Manifest)) {
            if (-not $line.Trim()) { continue }
            # "<sha256>  <path>"
            $m = [regex]::Match($line, '^([0-9a-f]{64})\s\s(.*)$')
            if (-not $m.Success) { throw "malformed manifest line: $line" }
            $expected[$m.Groups[2].Value] = $m.Groups[1].Value
        }

        $missing = [System.Collections.Generic.List[string]]::new()
        $mismatch = [System.Collections.Generic.List[string]]::new()
        $extra = [System.Collections.Generic.List[string]]::new()

        $actualPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($e in $entries) {
            [void]$actualPaths.Add($e.Path)
            if (-not $expected.ContainsKey($e.Path)) {
                $extra.Add($e.Path)
            }
            elseif ($expected[$e.Path] -ne $e.Hash) {
                $mismatch.Add($e.Path)
            }
        }
        $gone = @($expected.Keys | Where-Object { -not $actualPaths.Contains($_) })

        foreach ($g in ($gone | Sort-Object)) { $missing.Add($g) }

        $ok = ($missing.Count -eq 0 -and $mismatch.Count -eq 0 -and $extra.Count -eq 0)

        Write-Host ("  [manifest] expected {0} files" -f $expected.Count)
        Write-Host ("  [manifest] found    {0} files" -f $entries.Count)
        Write-Host ("  [manifest] missing  {0}" -f $missing.Count)
        Write-Host ("  [manifest] modified {0}" -f $mismatch.Count)
        Write-Host ("  [manifest] extra    {0}" -f $extra.Count)

        if (-not $ok) {
            foreach ($p in ($mismatch | Sort-Object | Select-Object -First 15)) { Write-Host "    modified: $p" -ForegroundColor Yellow }
            foreach ($p in ($missing | Sort-Object | Select-Object -First 15)) { Write-Host "    missing : $p" -ForegroundColor Yellow }
            foreach ($p in ($extra | Sort-Object | Select-Object -First 15)) { Write-Host "    extra   : $p" -ForegroundColor Yellow }
            if ($mismatch.Count -gt 15 -or $missing.Count -gt 15 -or $extra.Count -gt 15) {
                Write-Host '    ... output truncated'
            }
            throw "source tree does not match the manifest; refusing to build"
        }

        Write-Host '  [manifest] every file matches the audited upstream tree' -ForegroundColor Green
    }
}
