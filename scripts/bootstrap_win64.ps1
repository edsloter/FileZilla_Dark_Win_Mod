<#
.SYNOPSIS
    Prepares a clean Windows 11 x64 machine to build FileZilla with system
    light/dark theme support.

.DESCRIPTION
    A fresh Windows 11 install has none of what this build needs, and no build
    script can install any of it:

      PowerShell 7   Windows 11 ships only Windows PowerShell 5.1. The build scripts
                     need pwsh, so this script runs under 5.1 and then installs 7.
      Git            Needed for the patch series. Not present on a fresh install.
      7-Zip          Only needed to build the optional 7z overlay archive; the NSIS
                installer .exe needs neither 7-Zip nor PowerShell. Not present.
      MSYS2          install-toolchain_win64.ps1 installs pacman packages *into*
                     MSYS2 and throws if C:\msys64 is missing. It does not install
                     MSYS2 itself.
      wxWidgets      build-wx_win64.ps1 throws unless C:\wxWidgets-<ver> is already
                     unpacked. 3.3 is mandatory, not a preference: configure.ac
                     rejects 3.2, and 3.3 is what implements the system light/dark
                     appearance this project exists to provide.

    Nothing is installed unless it is genuinely absent.

    Every component is probed first, and a probe only counts as satisfied if the
    tool actually RUNS. Existence of a file is not evidence of a working install:
    a half-finished MSI, a stale PATH, or a broken MSYS2 first-run all look fine to
    Test-Path. Probes also check the standard install locations, not just PATH,
    because a tool installed after the current terminal was opened is missing from
    PATH even though it works fine in a new terminal - reinstalling in that case
    would be pure waste.

    If a component is present but older than the pinned version it is KEPT, not
    replaced: PowerShell 7.5 builds this project perfectly well, and downgrading a
    user's machine to match a pin would be rude and pointless.

.PARAMETER Root
    Build tree. Defaults to C:\fzdark. Must match the orchestrator's -Root.

.PARAMETER Plan
    Report what would be installed and exit. Changes nothing, downloads nothing.
    Run this first if you are unsure.

.PARAMETER Skip
    Components to skip entirely. Valid: Pwsh, Git, SevenZip, Msys2, WxWidgets.

.PARAMETER ThenBuild
    After a successful bootstrap, launch install-filezilla-dark_win64.ps1 under pwsh.

.PARAMETER Force
    Reinstall components even if the probe found a working copy.

.NOTES
    Requires administrator rights: pacman needs them, and MSYS2 and wxWidgets both
    unpack to fixed paths under C:\.

    Runs under Windows PowerShell 5.1 on purpose - see .DESCRIPTION. That rules out
    7.3+ syntax: no ternary, no null-coalescing, no -Parallel.
#>
[CmdletBinding()]
param(
    # Left empty so it can be defaulted from versions.ps1 after the dot-source;
    # a param default here would run before $BuildRoot exists.
    [string]$Root,
    [switch]$Plan,
    [string[]]$Skip = @(),
    [switch]$ThenBuild,
    [switch]$Force,
    # Keep the downloaded installers afterwards. Without it, installers this run
    # downloaded are removed once they have been installed, so a successful
    # bootstrap leaves no multi-hundred-megabyte cache behind. Installers supplied
    # by hand in tarballs\ are never removed.
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Versions, URLs and digests live in one file so a release bump is a single edit.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'versions.ps1')

if (-not $Root) { $Root = $BuildRoot }

$DownloadDir = Join-Path $Root 'dl\bootstrap'
$ScriptsDir  = $PSScriptRoot

# Installer files fetched by this run, as opposed to pre-existing cache entries or
# hand-supplied drops. Only the former are candidates for cleanup.
$script:DownloadedInstallers = @()

function Step  { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Info  { param([string]$m) Write-Host "    $m" }
function Good  { param([string]$m) Write-Host "    OK  $m" -ForegroundColor Green }
function Warn2 { param([string]$m) Write-Host "    !!  $m" -ForegroundColor Yellow }

$script:Failures = New-Object System.Collections.ArrayList
function Add-Failure { param([string]$Step, [string]$Message) [void]$script:Failures.Add("$Step : $Message") }

# --------------------------------------------------------------------- probes
#
# Each probe returns $null when the component is unusable, or a hashtable
# describing what was found. "Usable" means the tool was executed and answered.

function Probe-Pwsh {
    # Standard install location first, then PATH. Get-Command alone misses a pwsh
    # installed after this terminal opened.
    $candidates = @()
    $std = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $std) { $candidates += $std }
    $onPath = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        try {
            $v = (& $c -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Out-String).Trim()
            if ($v) { return @{ Path = $c; Version = $v } }
        }
        catch { }
    }
    return $null
}

function Probe-Git {
    $candidates = @()
    foreach ($p in @(
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { $candidates += $p }
    }
    $onPath = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        try {
            $v = (& $c --version 2>$null | Out-String).Trim()
            if ($v) { return @{ Path = $c; Version = $v } }
        }
        catch { }
    }
    return $null
}

function Probe-SevenZip {
    $candidates = @()
    if (Test-Path -LiteralPath $SevenZipExe) { $candidates += $SevenZipExe }
    $onPath = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        try {
            # 7z prints a blank line before its banner, so the first line is not the
            # version - filter empties out rather than trusting position 1.
            $v = (& $c 2>$null | Where-Object { "$_".Trim() } | Select-Object -First 1 | Out-String).Trim()
            if ($v) { return @{ Path = $c; Version = $v } }
        }
        catch { }
    }
    return $null
}

function Probe-Msys2 {
    # Both halves must work: a missing pacman means install-toolchain cannot run,
    # and pacman present but uninitialised fails in confusing ways.
    if (-not (Test-Path -LiteralPath $MsysBash)) { return $null }
    if (-not (Test-Path -LiteralPath $MsysPacman)) { return $null }
    try {
        # Probe through cmd's NUL redirection: native stderr from a cold
        # /usr/bin/bash (fresh /etc/passwd, missing HOME dir) must not be shaped
        # into a terminating error by the parent's $ErrorActionPreference='Stop'.
        $v = & cmd.exe /c ('"' + $MsysBash + '" -lc "uname -sr" 2>NUL')
        if ($v -and $v -notmatch 'MSYS2 is starting') { return @{ Path = $Msys2Root; Version = $v } }
    }
    # A throw here is usually a strict-mode error on a typo'd variable, not a broken
    # MSYS2, so surface it rather than silently reporting "not installed" - that
    # would send the user off to reinstall a perfectly good toolchain.
    catch { Warn2 "probe of $Msys2Root failed: $($_.Exception.Message)" }
    return $null
}

function Probe-WxWidgets {
    # Both files are needed: Makefile.in is what configure looks for, and
    # build\msw\makefile.gcc is what build-wx_win64.ps1 checks before building.
    $mk = Join-Path $WxRoot 'build\msw\makefile.gcc'
    $setup = Join-Path $WxRoot 'Makefile.in'
    if (-not (Test-Path -LiteralPath $mk)) { return $null }
    if (-not (Test-Path -LiteralPath $setup)) { return $null }
    return @{ Path = $WxRoot; Version = "wxWidgets $WxVersion (unpacked)" }
}

$Components = @(
    @{ Key = 'Pwsh';     Name = 'PowerShell 7';  Want = $PwshVersion;     Probe = { Probe-Pwsh } }
    @{ Key = 'Git';      Name = 'Git';           Want = $GitVersion;      Probe = { Probe-Git } }
    @{ Key = 'SevenZip'; Name = '7-Zip';         Want = $SevenZipVersion; Probe = { Probe-SevenZip } }
    @{ Key = 'Msys2';    Name = 'MSYS2 / UCRT64'; Want = $Msys2Stamp;     Probe = { Probe-Msys2 } }
    @{ Key = 'WxWidgets';Name = "wxWidgets $WxVersion"; Want = $WxVersion; Probe = { Probe-WxWidgets } }
)

# ---------------------------------------------------------------- preflight

Write-Host ''
Write-Host 'FileZilla dark-theme build - machine bootstrap' -ForegroundColor White
Write-Host "  host PowerShell : $($PSVersionTable.PSVersion)  edition $($PSVersionTable.PSEdition)"
Write-Host "  FileZilla       : $FzVersion"
Write-Host "  root            : $Root"
Write-Host ''

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    ([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ------------------------------------------------------- probe everything first
#
# Probing runs before the elevation check on purpose. Probing is read-only - it only
# inspects and executes already-installed tools - so -Plan must work from an
# unelevated shell, otherwise there is no way to find out what is needed without
# first becoming an administrator.

Step 'Checking what is already installed'
$results = [ordered]@{}
foreach ($c in $Components) {
    if ($Skip -contains $c.Key) {
        $results[$c.Key] = @{ State = 'skipped'; Name = $c.Name; Want = $c.Want }
        Info ("{0,-16} skipped by -Skip" -f $c.Name)
        continue
    }
    $found = & $c.Probe
    if ($found -and -not $Force) {
        $results[$c.Key] = @{ State = 'present'; Name = $c.Name; Want = $c.Want } + $found
        Good ("{0,-16} {1}" -f $c.Name, $found.Version)
        Info ("{0,-16} at {1}" -f '', $found.Path)
    }
    elseif ($found -and $Force) {
        $results[$c.Key] = @{ State = 'install'; Name = $c.Name; Want = $c.Want; Force = $true } + $found
        Warn2 ("{0,-16} present but -Force given" -f $c.Name)
    }
    else {
        $results[$c.Key] = @{ State = 'install'; Name = $c.Name; Want = $c.Want }
        Warn2 ("{0,-16} {1}" -f $c.Name, $(if ($found) { 'found, but -Force was given' } else { 'not found or not working' }))
    }
}

$toInstall = @($Components | Where-Object { $results[$_.Key].State -eq 'install' })

Write-Host ''
Write-Host '  Component           Status    Wanted    Action'
Write-Host '  ------------------ --------- --------- ----------------------------'
foreach ($c in $Components) {
    $r = $results[$c.Key]
    $action = switch ($r.State) {
        'present' { 'keep, nothing to do' }
        'skipped' { 'skipped' }
        default   { 'download + install' }
    }
    "  {0,-18} {1,-9} {2,-9} {3}" -f $r.Name, $r.State, $r.Want, $action | Write-Host
}

Write-Host ''
if ($toInstall.Count -eq 0) {
    Good 'Everything is already installed. Nothing to download.'
}
else {
    Info "$($toInstall.Count) of $($Components.Count) components need installing:"
    foreach ($c in $toInstall) { Info "  - $($c.Name) $($c.Want)" }
}

# Nothing has been downloaded or installed up to this point.
if ($Plan) {
    Write-Host ''
    Write-Host '-Plan was given: stopping before any change. Re-run without -Plan to proceed.' -ForegroundColor Cyan
    exit 0
}

# ------------------------------------------------------- elevation, if needed

if ($toInstall.Count -eq 0) {
    Write-Host ''
    Good 'running elevated (not needed - nothing to install, but harmless)'
}
elseif (-not $isAdmin) {
    Write-Host ''
    Write-Host @'
Installing the components above needs administrator rights.

Right-click "Windows Terminal" or "PowerShell" -> Run as administrator, then re-run
the same command. Add -Plan to see this table without installing anything.

Rationale: pacman refuses to install packages unelevated, and MSYS2 and wxWidgets
both unpack to fixed paths directly under C:\.
'@ -ForegroundColor Red
    exit 1
}
else {
    Good 'running elevated'
}


# ------------------------------------------------------------------ installers

function Get-Artifact {
    param([Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][string]$Url,
          [Parameter(Mandatory)][string]$Sha256,
          [Parameter(Mandatory)][long]$Size)

    if (-not (Test-Path -LiteralPath $DownloadDir)) {
        New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    }
    $dest = Join-Path $DownloadDir $Name

    # Offline drop box first. The toolchain installers are third-party downloads
    # like the source archives, so they honour the same convention: put the file in
    # tarballs\ and it is used instead of the network, provided it matches the pin.
    # A file there that does not match stops the run rather than being overwritten.
    $dropped = Join-Path $TarballDir $Name
    if (Test-Path -LiteralPath $dropped) {
        $dh = (Get-FileHash -LiteralPath $dropped -Algorithm SHA256).Hash.ToLower()
        if ($dh -ne $Sha256) {
            throw @"
$Name in $(Split-Path -Leaf $TarballDir)\, has sha256 $dh but $Sha256 is pinned.

Refusing to download over a file you placed by hand. Remove or rename it, then
re-run. If you are confident the pin is stale, update versions.ps1 deliberately
instead of bypassing the check.
"@
        }
        Info "$Name supplied in $(Split-Path -Leaf $TarballDir)\, sha256 verified"
        return $dropped
    }

    if (Test-Path -LiteralPath $dest) {
        $h = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $Sha256) {
            Info "$Name already downloaded and verified"
            return $dest
        }
        Warn2 "$Name is corrupt (sha256 $h); re-downloading"
        Remove-Item -LiteralPath $dest -Force
    }

    Info "downloading $Name ($([math]::Round($Size / 1MB, 1)) MB)"
    # Download to .part so an interrupted transfer is never mistaken for a good file
    # on a later run.
    $part = "$dest.part"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing -TimeoutSec 1800
    $ProgressPreference = 'Continue'

    $len = (Get-Item -LiteralPath $part).Length
    if ($len -ne $Size) {
        Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
        throw "$Name : expected $Size bytes, got $len. The pinned version may have been replaced upstream - update versions.ps1 deliberately rather than removing the check."
    }
    $h = (Get-Item -LiteralPath $part | Get-FileHash -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $Sha256) {
        Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
        throw "$Name : sha256 is $h but $Sha256 was expected. Discarded."
    }
    Move-Item -LiteralPath $part -Destination $dest -Force
    $script:DownloadedInstallers += $dest
    Good "$Name verified ($([math]::Round($len / 1MB, 1)) MB)"
    return $dest
}

# Refresh PATH from the registry so a component installed a moment ago is visible
# to later steps in this same run.
function Sync-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

if ($toInstall | Where-Object { $_.Key -eq 'Pwsh' }) {
    Step 'PowerShell 7'
    try {
        $msi = Get-Artifact -Name $PwshFile -Url $PwshUrl -Sha256 $PwshSha256 -Size $PwshSize
        $log = Join-Path $DownloadDir 'pwsh-install.log'
        Info 'installing (msiexec, silent)'
        $p = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$log`"") -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            Add-Failure 'PowerShell 7' "msiexec exited $($p.ExitCode); see $log"
        }
        else {
            Sync-Path
            $r = Probe-Pwsh
            if ($r) { Good "installed: $($r.Version)" } else { Add-Failure 'PowerShell 7' 'installed but pwsh.exe is not usable; open a new terminal and re-run' }
        }
    }
    catch { Add-Failure 'PowerShell 7' $_.Exception.Message }
}

if ($toInstall | Where-Object { $_.Key -eq 'Git' }) {
    Step 'Git'
    try {
        $exe = Get-Artifact -Name $GitFile -Url $GitUrl -Sha256 $GitSha256 -Size $GitSize
        Info 'installing (Inno Setup, silent)'
        $p = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-') -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Add-Failure 'Git' "installer exited $($p.ExitCode)"
        }
        else {
            Sync-Path
            $r = Probe-Git
            if ($r) { Good "installed: $($r.Version)" } else { Add-Failure 'Git' 'installed but git.exe is not usable; open a new terminal and re-run' }
        }
    }
    catch { Add-Failure 'Git' $_.Exception.Message }
}

if ($toInstall | Where-Object { $_.Key -eq 'SevenZip' }) {
    Step '7-Zip'
    try {
        $exe = Get-Artifact -Name $SevenZipFile -Url $SevenZipUrl -Sha256 $SevenZipSha256 -Size $SevenZipSize
        Info 'installing (NSIS, silent)'
        $p = Start-Process -FilePath $exe -ArgumentList @('/S') -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            Add-Failure '7-Zip' "installer exited $($p.ExitCode)"
        }
        else {
            $r = Probe-SevenZip
            if ($r) { Good "installed: $($r.Path)" } else { Add-Failure '7-Zip' "installer ran but 7z.exe is not at $SevenZipExe" }
        }
    }
    catch { Add-Failure '7-Zip' $_.Exception.Message }
}

if ($toInstall | Where-Object { $_.Key -eq 'Msys2' }) {
    Step 'MSYS2'
    try {
        if (Test-Path -LiteralPath $Msys2Root) {
            Warn2 "$Msys2Root exists but is incomplete or not working; replacing it"
            Remove-Item -LiteralPath $Msys2Root -Recurse -Force -EA SilentlyContinue
        }
        $archive = Get-Artifact -Name $Msys2File -Url $Msys2Url -Sha256 $Msys2Sha256 -Size $Msys2Size
        Info 'unpacking to C:\ (produces C:\msys64)'
        # Plain .tar.xz in preference to the .sfx.exe so there are no self-extractor
        # flags to guess at. It unpacks to a single msys64\ directory, which is
        # exactly the layout wanted under C:\.
        $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tar)) {
            throw "bsdtar not found at $tar. Windows 10 1803+ and Windows 11 ship it; this host looks older or broken."
        }
        & $tar -xf $archive -C 'C:\'
        if ($LASTEXITCODE -ne 0) { throw "extraction failed (exit $LASTEXITCODE)" }
        if (-not (Test-Path -LiteralPath $MsysBash)) { throw "extracted but $MsysBash is missing" }
        Good "unpacked: $Msys2Root"
        Info 'running first-time initialisation (creates /etc/passwd, mount table)'
        # The first run lets /etc/profile print "MSYS2 is starting for the first
        # time..." to stderr. Under Windows PowerShell 5.1 with
        # $ErrorActionPreference='Stop' that line surfaces as a terminating native
        # error and poisons this step. Defuse by running the init inside a
        # localized 'Continue' preference, then check the exit code ourselves.
        # Windows PowerShell 5.1 turns native stderr into a terminating error
        # because of $ErrorActionPreference='Stop' - this surfaced as the false
        # "MSYS2 is starting for the first time..." failure table entry. Run the
        # init through cmd with its own NUL redirect so it cannot snowball that way.
        $initOut = & cmd.exe /c ('"' + $MsysBash + '" -lc "exit 0" >NUL 2>&1')
        $initRc = $LASTEXITCODE
        if ($initRc -ne 0) { Add-Failure 'MSYS2' "initial setup exited $initRc" }
        $r = Probe-Msys2
        if ($r) { Good "working: $($r.Version)" } else { Add-Failure 'MSYS2' 'unpacked but bash/pacman did not become usable' }
    }
    catch { Add-Failure 'MSYS2' $_.Exception.Message }
}

if ($toInstall | Where-Object { $_.Key -eq 'WxWidgets' }) {
    Step "wxWidgets $WxVersion"
    # fetch-deps and extract-deps already know how to get and unpack this with the
    # pinned SHA-512, including mirror fallback. Reuse them rather than duplicating
    # the URL and digest here.
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) { $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue }
    if (-not $pwshCmd) {
        $std = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $std) { $pwshCmd = @{ Source = $std } }
    }
    if (-not $pwshCmd) {
        Add-Failure "wxWidgets $WxVersion" 'needs pwsh to run fetch-deps/extract-deps; install PowerShell 7 first, then re-run'
    }
    else {
        try {
    Info 'fetching and unpacking via fetch-deps / extract-deps'
    # Both get -Keep: fetch-deps would otherwise delete the very archives its own
    # cleanup phase runs, and extract-deps unpacks from those archives, so running
    # them without -Keep discards exactly what the next stage of this same bootstrap
    # (and the later FileZilla build) needs.
    & $pwshCmd.Source -NoProfile -File (Join-Path $ScriptsDir 'fetch-deps_win64.ps1') -Root $Root -Keep
    if ($LASTEXITCODE -ne 0) { throw "fetch-deps exited $LASTEXITCODE" }
    & $pwshCmd.Source -NoProfile -File (Join-Path $ScriptsDir 'extract-deps_win64.ps1') -Root $Root -Only wx -Keep
    if ($LASTEXITCODE -ne 0) { throw "extract-deps exited $LASTEXITCODE" }

            $r = Probe-WxWidgets
            if ($r) { Good "ready: $($r.Version)" } else { Add-Failure "wxWidgets $WxVersion" "unpacked but the expected files are missing from $WxRoot" }
        }
        catch { Add-Failure "wxWidgets $WxVersion" $_.Exception.Message }
    }
}

# --------------------------------------------------------------------- summary

if ($script:Failures.Count -gt 0 -and $ThenBuild) {
    Write-Host ''
    Warn2 '-ThenBuild was requested but bootstrap had failures; not starting the build.'
}

if ($ThenBuild -and $script:Failures.Count -eq 0) {
    $build = Join-Path $ScriptsDir 'install-filezilla-dark_win64.ps1'
    if (-not (Test-Path -LiteralPath $build)) {
        Add-Failure 'handoff' "cannot find $build"
    }
    else {
        Write-Host ''
        Write-Host 'Launching the build...' -ForegroundColor Cyan
        $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if (-not $pwshCmd) { $pwshCmd = @{ Source = (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe') } }
        # Under pwsh, not &, so the orchestrator's exit code becomes ours and a
        # failing build is not reported as a successful bootstrap.
        & $pwshCmd.Source -NoProfile -File $build -Root $Root
        $code = $LASTEXITCODE
        Write-Host ''
        if ($code -eq 0) { Good 'build finished successfully' }
        else { Add-Failure 'build' "install-filezilla-dark_win64.ps1 exited $code" }
    }
}

Write-Host ''
if ($Keep) {
    Write-Host "Keeping $($script:DownloadedInstallers.Count) installer(s) this run downloaded in $DownloadDir (-Keep)."
}
elseif ($script:DownloadedInstallers.Count -gt 0) {
    foreach ($f in $script:DownloadedInstallers) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Removed $($script:DownloadedInstallers.Count) installer(s) this run downloaded. Pass -Keep to retain them."
}

if ($script:Failures.Count -eq 0) {
    Write-Host 'Bootstrap complete. The build should now run:' -ForegroundColor Green
    Write-Host ''
    Write-Host "    pwsh -File `"$ScriptsDir\install-filezilla-dark_win64.ps1`" -Root `"$Root`""
    Write-Host ''

    # A freshly installed PS7 is not on this console's PATH, so resolve the
    # binary explicitly; otherwise the next line is 'pwsh is not recognized'.
    $pwshPath = $null
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwshCmd) { $pwshPath = $pwshCmd.Source }
    if (-not $pwshPath) {
        $candidate = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate) { $pwshPath = $candidate }
    }
    if ($pwshPath) {
        $reply = Read-Host 'Run that build command now? [Y/N]'
        if ($reply -match '^[Yy]') {
            Write-Host "`nStarting the build via $pwshPath ..." -ForegroundColor Cyan
            $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $ScriptsDir 'install-filezilla-dark_win64.ps1'), '-Root', $Root)
            if ($Keep) { $buildArgs += '-Keep' }
            & $pwshPath @buildArgs
            exit $LASTEXITCODE
        }
    }
    exit 0
}

Write-Host 'Bootstrap finished with problems:' -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host "    - $f" -ForegroundColor Red }
Write-Host ''
Write-Host 'The build cannot proceed until these are resolved. Re-running this' -ForegroundColor Red
Write-Host 'script is safe; components already present are left alone.' -ForegroundColor Red
exit 1
