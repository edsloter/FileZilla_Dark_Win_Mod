<#
.SYNOPSIS
    Extracts the dependency archives fetched by fetch-deps_win64.ps1.

.DESCRIPTION
    Keeps the pristine, digest-verified archives in <root>\dl and works on copies in
    <root>\src, so re-extracting is always cheap and the verified originals are never
    touched.

    Each archive unpacks into its own src\<name> directory. The .tar.* archives are
    unpacked with GNU tar using --strip-components 1 so the payload lands directly in
    src\<name> rather than src\<name>\<name>.

    The SQLite zip needs bsdtar - MSYS2's default `tar` is GNU tar, which cannot read
    zip archives (there is no unzip on this machine). bsdtar handles the zip natively
    and it already contains its own top-level directory, so no stripping is needed.

    Versions and filenames all come from versions.ps1, so a FileZilla release bump
    needs no edit here.

.NOTES
    Boost is large (~700 MB unpacked). Pass -Only to extract a subset while
    iterating on the FileZilla build.
#>
[CmdletBinding()]
param(
    # Restrict extraction to named artefacts (libfilezilla, fzssh, boost, sqlite, wx).
    [string[]]$Only,
    # Re-extract even if the target directory already exists.
    [switch]$Force,
    # Retain the extracted source trees. Without it the trees unpacked by this run
    # are removed again; trees that already existed are never touched.
    [switch]$Keep,
    # Override the build root. Must match fetch-deps_win64.ps1's -Root.
    # Left empty so it can be defaulted from versions.ps1 after the dot-source.
    [string]$Root
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')
if (-not $Root) { $Root = $BuildRoot }

# Normalise the -Only list against two common operator mistakes: passing the list
# as a single comma-joined string ('a,b' stays ONE array element in PowerShell
# argument binding), or leaving it empty. Both would silently skip everything.
if ($Only) {
    $Only = $Only | ForEach-Object { $_ -split ',' }
}


# Source trees this run creates from scratch, so cleanup can spare anything that was
# already present.
$script:CreatedTrees = @()

$dl = Join-Path $Root 'dl'
$src = Join-Path $Root 'src'
# Windows' built-in tar is bsdtar: it reads tar.gz/tar.bz2/tar.xz/zip out of the
# box, whereas MSYS2's /usr/bin/tar decompresses via an external helper (lbzip2,
# bzip2, xz) that a fresh MSYS2 does not have. No such helpers means zero external
# packages are needed to unpack the pinned archives, which keeps the wx unpack
# step inside bootstrap working before install-toolchain has run pacman.
$archiver = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $archiver)) { throw 'bsdtar not found at %SystemRoot%\System32\tar.exe; this kit requires Windows 10 1803+' }

New-Item -ItemType Directory -Force -Path $src | Out-Null

$artefacts = @(

    @{ Key = 'libfilezilla'; File = $LibfzFile; Dir = "libfilezilla-$($LibfzVersion)"; Kind = 'tar'; Root = $src }
    @{ Key = 'fzssh';        File = $FzSshFile; Dir = "fzssh-$($FzSshVersion)";     Kind = 'tar'; Root = $src }
    @{ Key = 'boost';        File = $BoostFile; Dir = "boost_$($BoostVersion -replace '\.', '_')"; Kind = 'tar'; Root = $src }
    @{ Key = 'sqlite';       File = $SqliteFile; Dir = "sqlite-amalgamation-$($SqliteVersion)"; Kind = 'zip'; Root = $src }
    # wxWidgets is deliberately NOT unpacked into src\. build-wx_win64.ps1, and the
    # MSYS2 build recipes underneath it, both assume the wxWidgets tree sits at the
    # fixed path from versions.ps1 ($WxRoot) - its own makefiles and setup.h look for
    # lib/ and include/ relative to that root. It also carries build/msw/makefile.gcc,
    # which the build needs and which must not be buried among other dependencies.
    @{ Key = 'wx';          File = $WxFile; Dir = "wxWidgets-$($WxVersion)"; Kind = 'tar'; Root = (Split-Path -Qualifier $WxRoot) }
)


foreach ($a in $artefacts) {
    if ($Only -and ($Only -notcontains $a.Key)) { continue }

    $archive = Join-Path $dl $a.File
    if (-not (Test-Path $archive)) { throw "$archive missing - run fetch-deps_win64.ps1 first" }

      $target = Join-Path $a.Root $a.Dir
      
      if (Test-Path $target) {
          if (-not $Force) { Write-Host "  [skip]  $($a.Dir) (already extracted)"; continue }
          Write-Host "  [clean] $($a.Dir)"
          Remove-Item $target -Recurse -Force
      }
      else {
          # Only trees this run creates are candidates for cleanup later. A tree
          # that was already here belongs to the user, or to an earlier run that
          # used -Keep, and removing it would punish them for our housekeeping.
          $script:CreatedTrees += $target
      }
      New-Item -ItemType Directory -Force -Path $target | Out-Null


    Write-Host "  [x]     $($a.File) -> $($target)"
    if ($a.Kind -eq 'zip') {
        # The zip already contains its own top-level directory.
        & $archiver -xf $archive -C $target --strip-components 1
    }
    else {
        & $archiver -xf $archive -C $target --strip-components 1 $a.Dir
    }
    if ($LASTEXITCODE -ne 0) { throw "$($a.File) extraction failed (exit $LASTEXITCODE)" }

    # build-wx_win64.ps1 needs this exact file to exist before it will touch
    # anything, and it is the makefile that drives the whole wx build.
    if ($a.Key -eq 'wx') {
        $mk = Join-Path $target 'build\msw\makefile.gcc'
        if (-not (Test-Path $mk)) { throw "wxWidgets extracted but build\msw\makefile.gcc is missing from $target" }
        $setup = Join-Path $target 'Makefile.in'
        if (-not (Test-Path $setup)) { throw "wxWidgets extracted but Makefile.in is missing from $target" }
        Write-Host "         verified build\msw\makefile.gcc and Makefile.in present"
    }
}

Write-Host "`nExtracted into $src :"
Get-ChildItem $src -Directory | Sort-Object Name | ForEach-Object {
    "  {0,-32} {1,9:N0} files" -f $_.Name, (Get-ChildItem $_.FullName -Recurse -File).Count
}
# wxWidgets went to a fixed root outside src\, so it would otherwise never appear in
# the summary and a failed extraction there would look like nothing had happened.
  if (Test-Path $WxRoot) {
      Write-Host "`nExtracted to a fixed root (build-wx_win64.ps1 expects this path):"
      "  {0,-32} {1,9:N0} files" -f $WxRoot, (Get-ChildItem $WxRoot -Recurse -File).Count
  }
  
  if ($Keep) {
      Write-Host "`nKeeping the trees extracted by this run (-Keep)."
  }
  elseif ($script:CreatedTrees.Count -eq 0) {
      Write-Host "`nNothing to clean up: every requested tree already existed."
  }
  else {
      foreach ($t in $script:CreatedTrees) {
          Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue
      }
      Write-Host "`nRemoved $($script:CreatedTrees.Count) tree(s) this run extracted. Pass -Keep to retain them."
  }

