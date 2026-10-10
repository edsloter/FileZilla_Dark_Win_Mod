<#
.SYNOPSIS
    Proves that the MSYS2 ucrt64 Boost.Regex installation is usable the way
    FileZilla needs it.

.DESCRIPTION
    Two things make this non-obvious:

      * MSYS2 ships Boost.Regex as libregex / libregex.dll.a, NOT as
        libboost_regex. So the link flag has to be -lregex.
      * FileZilla's m4/check_regex.m4 requires BOOST_REVIEW_STANDALONE (sic)
        to be defined before including <boost/regex.hpp>, and src/interface/
        filter.cpp does exactly that.

    So rather than guess from the library file names, this compiles and runs a
    real program using boost::regex with BOOST_REGEX_STANDALONE, linked against
    -lregex.

.NOTES
    Writes a temporary .cpp/.exe under $env:TEMP and cleans up after itself.
#>

$ErrorActionPreference = 'Stop'

$ucrt = 'C:\msys64\ucrt64'
$gpp = Join-Path $ucrt 'bin\g++.exe'
if (-not (Test-Path $gpp)) { throw "ucrt64 g++ not found at $gpp" }

$src = @'
#define BOOST_REGEX_STANDALONE
#include <boost/regex.hpp>
#include <iostream>

int main()
{
    boost::regex re("^a+b$");
    if (!boost::regex_match("aaab", re)) { std::cout << "FAIL: no match\n"; return 1; }
    if (boost::regex_match("b", re))     { std::cout << "FAIL: bad match\n"; return 1; }
    std::cout << "OK: boost::regex works, BOOST_RE_VERSION="
              << BOOST_RE_VERSION << "\n";
    return 0;
}
'@

$dir = Join-Path $env:TEMP 'fzdark-boostre'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$cpp = Join-Path $dir 'regexcheck.cpp'
$exe = Join-Path $dir 'regexcheck.exe'
Set-Content -Path $cpp -Value $src -Encoding UTF8

$env:PATH = "$ucrt\bin;$env:PATH"

Write-Host "compiler: $(& $gpp --version | Select-Object -First 1)"
Write-Host "linking : -lregex (MSYS2's name for Boost.Regex)"
Write-Host ""

& $gpp -std=c++17 -O2 $cpp -o $exe -lregex
if ($LASTEXITCODE -ne 0) { throw "compiling the Boost.Regex check failed (exit $LASTEXITCODE)" }

& $exe
if ($LASTEXITCODE -ne 0) { throw "the Boost.Regex check failed at runtime (exit $LASTEXITCODE)" }

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue