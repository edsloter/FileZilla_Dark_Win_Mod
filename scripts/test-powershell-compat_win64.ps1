<#
.SYNOPSIS
    Checks that this repo is clean for Windows PowerShell 5.1, which is the shell it
    targets and the one every supported Windows already has.

.DESCRIPTION
    Read-only, needs no admin, no build and no network, and runs in a second or two.
    Safe to run before every commit.

    Two halves, because they catch different things.

    DYNAMIC checks run the real engine. Every script is parsed and then loaded, and
    the runtime helpers are exercised against commands that misbehave on purpose:
    one that writes to stderr and exits 0, which is what a compiler warning looks
    like, and one that fails, which is what a missing package looks like. These are
    the checks that matter most. Six bugs were fixed in this repo that every static
    review passed, all of them behavioural - PowerShell 5.1 turns a native command's
    stderr into a terminating error where 7 does not, Set-StrictMode makes a property
    read on $null throw, and an array splat aimed at a PowerShell script does not bind
    parameter names the way it looks like it should.

    STATIC checks scan for the specific traps that dynamic checks cannot reach,
    because they only bite on some input: cmdlets that exist only in 7, an argument
    list aimed at a script instead of a native tool, a property read chained onto a
    Get-Command that can return null, and a native command whose stderr is merged
    without the preference being scoped around it.

    Quoted strings and comment lines are stripped before the static scans, so shell
    snippets embedded in PowerShell - a bash -lc argument containing 2>&1, say - are
    not mistaken for PowerShell.

    Exits 0 when everything passes, 1 otherwise.

.EXAMPLE
    .\scripts\test-powershell-compat_win64.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$failures = 0

function Pass { param([string]$m) Write-Host "  PASS  $m" }
function Fail { param([string]$m) $script:failures++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Note { param([string]$m) Write-Host "  note  $m" }
function Head { param([string]$m) Write-Host "`n$m" -ForegroundColor Cyan }

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Host "repo: $RepoRoot"

# ------------------------------------------------------------------ dynamic

Head '1. every script parses under this engine'

$scripts = @(Get-ChildItem $RepoRoot -Recurse -Include *.ps1 -File | Sort-Object FullName)
foreach ($s in $scripts) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        Fail "$($s.Name): $($errs.Count) parse error(s); first at line $($errs[0].Extent.StartLineNumber)"
    }
}
if ($failures -eq 0) { Pass "all $($scripts.Count) scripts parse" }

Head '2. every script loads (this evaluates its param block)'

foreach ($s in $scripts) {
    try { $null = Get-Help $s.FullName -ErrorAction Stop }
    catch { Fail "$($s.Name) does not load: $($_.Exception.Message)" }
}
if ($failures -eq 0) { Pass "all $($scripts.Count) scripts load" }

Head '3. runtime behaviour that differs between 5.1 and 7'

. (Join-Path $RepoRoot 'versions.ps1')

function Doing { param([string]$m) Write-Host "  ...   $m" -ForegroundColor DarkGray }

# TLS: under 5.1 downloads use .NET Framework, whose default protocol set can still
# exclude Tls12, and GitHub and SourceForge refuse the older ones.
Doing 'checking TLS 1.2'
if ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) {
    Pass 'TLS 1.2 is enabled after loading versions.ps1'
}
else {
    Fail 'TLS 1.2 is NOT enabled - downloads may fail to negotiate HTTPS'
}

# A native command that warns and succeeds. Under 5.1 with ErrorActionPreference Stop
# this is fatal unless the helper scopes the preference; on 7 it never was.
Doing 'a warning on stderr must not abort the build'
$warner = Join-Path $env:TEMP 'fzdark-compat-warn.cmd'
Set-Content -LiteralPath $warner -Value "@echo off`r`necho warning: deprecated something 1>&2`r`nexit /b 0`r`n"

try {
    $out = @(Invoke-Native -File $warner -ArgumentList @() -IgnoreExitCode)
    Pass 'Invoke-Native survives a warning on stderr with exit 0'
}
catch { Fail "Invoke-Native threw on a warning: $($_.Exception.Message)" }

try {
    $out = @(Invoke-NativeLogged -File $warner -ArgumentList @() -IgnoreExitCode -PassThru)
    if ($out -match 'warning') { Pass 'Invoke-NativeLogged captures the warning text' }
    else { Fail 'Invoke-NativeLogged did not capture the warning text' }
}
catch { Fail "Invoke-NativeLogged threw on a warning: $($_.Exception.Message)" }

Remove-Item -LiteralPath $warner -Force -ErrorAction SilentlyContinue

# A command that fails: probes must tolerate it, real steps must still fail.
Doing 'a real failure must still fail loudly'
$failing = Join-Path $env:TEMP 'fzdark-compat-fail.cmd'
Set-Content -LiteralPath $failing -Value "@echo off`r`necho error: no such package 1>&2`r`nexit /b 1`r`n"

try {
    $null = Invoke-Native -File $failing -ArgumentList @() -IgnoreExitCode
    Pass 'Invoke-Native -IgnoreExitCode tolerates a failure (needed by probes)'
}
catch { Fail "Invoke-Native -IgnoreExitCode still threw: $($_.Exception.Message)" }

try {
    $null = Invoke-Native -File $failing -ArgumentList @()
    Fail 'Invoke-Native without -IgnoreExitCode did not throw on a failure'
}
catch { Pass 'Invoke-Native without -IgnoreExitCode still fails loudly' }

# Splatting: an array is argv, a hashtable binds by name. Getting this wrong against a
# PowerShell script produces a message that names neither the call nor the parameter.
Doing 'splat vs argv against a script'
$probe = Join-Path $env:TEMP 'fzdark-compat-probe.ps1'
Set-Content -LiteralPath $probe -Value "param([string]`$Name)`nWrite-Host `"got `$Name`"`n"

try {
    $null = Invoke-NativeLogged -File $probe -Splat @{ Name = 'value' } -IgnoreExitCode
    Pass 'Invoke-NativeLogged -Splat binds a script parameter by name'
}
catch { Fail "-Splat did not bind by name: $($_.Exception.Message)" }

try {
    $null = Invoke-NativeLogged -File $probe -ArgumentList @('-Name', 'value') -IgnoreExitCode
    Fail 'the guard did not fire on -ArgumentList aimed at a script'
}
catch {
    if ($_.Exception.Message -match 'Use -Splat') {
        Pass 'guard rejects -ArgumentList aimed at a script, and says what to use'
    }
    else {
        Fail "guard fired with an unhelpful message: $($_.Exception.Message)"
    }
}

# The other half of the guard: it must NOT fire for a native tool. Uses the same .cmd
# file as the checks above rather than naming cmd.exe, so this check depends on no
# particular executable beyond one already proven to run in this session. On a locked
# down or App Guard VM, resolving cmd.exe through PATH with streams redirected can stall
# where running a concrete file cannot, and a check that hangs is worse than no check.
Doing 'the guard must not misfire on a native tool'
try {
    $null = Invoke-NativeLogged -File $failing -ArgumentList @('ignored') -IgnoreExitCode
    Pass 'guard does not fire for a native tool, where -ArgumentList is argv'
}
catch { Fail "guard misfired on a native tool: $($_.Exception.Message)" }

Remove-Item -LiteralPath $failing -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue

# Get-HostPath is how a child step inherits the running host.
Doing 'the child step inherits this host'
$hostExe = $null
try { $hostExe = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
if ($hostExe) { Pass "the running host resolves for child steps: $hostExe" }
else { Fail 'could not resolve the running host path (Get-Process -Id $PID).Path' }

# ------------------------------------------------------------------- static

# Two views of each file. Comments go from both.
#   raw   keeps quoted strings, so a -File target named 'foo.ps1' is still visible.
#   bare  also blanks quoted strings, so a bash -lc argument containing 2>&1 is not
#         mistaken for PowerShell. Needed by the stderr check, useless for the splat
#         check, which is why both exist: stripping first and searching for .ps1 after
#         finds nothing, because stripping is what removes the .ps1.
function Get-CodeViews {
    param([string]$Path)
    $raw = New-Object System.Collections.Generic.List[string]
    $bare = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.TrimStart()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $raw.Add(($line -replace '\s+$', ''))
        $b = [regex]::Replace($line, "'[^']*'", " '' ")
        $b = [regex]::Replace($b, '"[^"]*"', ' "" ')
        $bare.Add(($b -replace '\s+$', ''))
    }
    return @{ Raw = ($raw -join "`n"); Bare = ($bare -join "`n") }
}

$codeFiles = @(Get-ChildItem $RepoRoot -Recurse -Include *.ps1, *.bat -File |
    Where-Object { $_.Name -ne 'test-powershell-compat_win64.ps1' })
$raw = @{}
$bare = @{}
foreach ($f in $codeFiles) {
    $views = Get-CodeViews $f.FullName
    $raw[$f.FullName] = $views.Raw
    $bare[$f.FullName] = $views.Bare
}

Head '4. static: nothing launches or requires PowerShell 7'

$hits = @()
foreach ($k in $raw.Keys) {
    if ($raw[$k] -match 'pwsh\.exe|ProgramFiles[^\s]*PowerShell|Get-Command\s+pwsh') { $hits += (Split-Path -Leaf $k) }
}
if ($hits.Count -eq 0) { Pass 'no reference to pwsh.exe or Program Files\PowerShell in code' }
else { Fail "references to pwsh: $(($hits | Select-Object -Unique) -join ', ')" }

Head '5. static: no cmdlets that exist only in PowerShell 7'

$sevenOnly = @(
    'Join-String'
    'Test-Json'
    'Update-TypeData'
    'Get-Error\b'
    'ConvertFrom-Json[^\n]*-AsHashtable'
    'ConvertFrom-Json[^\n]*-NoEnumerate'
    'ConvertFrom-Json[^\n]*-DateKind'
    'ConvertTo-Json[^\n]*-EscapeHandling'
    'ForEach-Object[^\n]*-Parallel'
    '(Get|Set)-Content[^\n]*-AsByteStream'
    'Invoke-RestMethod[^\n]*-StatusCodeVariable'
    'Invoke-WebRequest[^\n]*-SkipHttpErrorCheck'
    'Start-Process[^\n]*-Environment\b'
    'Get-WinEvent[^\n]*-FilterHashtable'
    'Get-ChildItem[^\n]*-Shadows'
)
$hits = @()
foreach ($k in $raw.Keys) {
    foreach ($p in $sevenOnly) {
        if ($raw[$k] -match $p) { $hits += "$([System.IO.Path]::GetFileName($k)) [$p]" }
    }
}
if ($hits.Count -eq 0) { Pass "none of the $($sevenOnly.Count) known 7-only cmdlets or parameters appear" }
else { Fail "7-only usage: $(($hits | Select-Object -Unique) -join '; ')" }

Head '6. static: -ArgumentList is never aimed at a PowerShell script'

# Anchored on -File so the guard in versions.ps1, which mentions .ps1 and
# -ArgumentList side by side but has no -File, does not trip it. Bounded by [^;] so a
# match cannot wander out of one call and into the next. Runs against raw, because
# the .ps1 lives inside quotes.
$hits = @()
foreach ($k in $raw.Keys) {
    $t = $raw[$k] -replace '\r?\n\s*', ' '
    foreach ($m in [regex]::Matches($t, 'Invoke-Native(?:Logged)?\b[^;]{0,300}?-File\s+\(?[^;]{0,160}?\.ps1[^;]{0,200}?-ArgumentList')) {
        $hits += "$([System.IO.Path]::GetFileName($k)): $($m.Value.Trim())"
    }
}
if ($hits.Count -eq 0) { Pass 'every PowerShell-script target uses -Splat' }
else { Fail "-ArgumentList aimed at a script (use -Splat): $($hits -join '; ')" }

Head '7. static: no property read chained onto a Get-Command that can return null'

$hits = @()
foreach ($k in $raw.Keys) {
    foreach ($m in [regex]::Matches($raw[$k], '\(Get-Command[^\n]*?\)\s*\.\s*\w+')) {
        $hits += "$([System.IO.Path]::GetFileName($k)): $($m.Value.Trim())"
    }
}
if ($hits.Count -eq 0) { Pass 'no (Get-Command ...).Property chains' }
else { Fail "under Set-StrictMode these throw when the command is absent: $($hits -join '; ')" }

Head '8. static: native stderr is never merged without scoping the preference'

# Matches any call operator followed by anything: earlier this required a word right
# after '& ', which missed '& (Join-Path ...) @args 2>&1' - a parenthesised target.
# Reads bare, so the two bash invocations that legitimately contain 2>&1 inside a
# quoted argument are not flagged.
$hits = @()
foreach ($k in $bare.Keys) {
    foreach ($line in ($bare[$k] -split "`n")) {
        if ($line -notmatch '(?<![\w\-])&\s') { continue }
        if ($line -notmatch '2>&1') { continue }
        if ($line -match 'Invoke-Native') { continue }
        $hits += "$([System.IO.Path]::GetFileName($k)): $($line.Trim())"
    }
}
if ($hits.Count -eq 0) { Pass 'no unscoped native command merges stderr into the pipeline' }
else { Fail "these abort on any stderr under 5.1: $($hits -join ' | ')" }

# ------------------------------------------------------------------- result

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'RESULT: compatible with Windows PowerShell 5.1' -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $failures check(s) failed" -ForegroundColor Red
exit 1
