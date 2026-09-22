#Requires -Version 5.1
# Compatibility entry point; always build a fresh GUI rather than reuse an arbitrary EXE.
param([string]$Version, [string]$ExePath, [switch]$SkipTests, [switch]$ShowHelp, [string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($ShowHelp) {
    Write-Output 'Usage: scripts\build-portable.ps1 [-Version <VERSION>] [-OutputDirectory <fresh directory>] [-SkipTests]'
    Write-Output 'Builds the GUI, tests, verifies all 82 baseline rule IDs, and produces a versioned ZIP plus SHA256SUMS.txt.'
    return
}
$current = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
if ($Version -and $Version -ne $current) { throw 'Update VERSION and gui/wails.json before selecting a different release version.' }
if ($ExePath) { throw 'External EXE packaging is disabled. The builder always compiles the current source.' }
& (Join-Path $root 'packaging\Build-Portable.ps1') -OutputDirectory $OutputDirectory -SkipTests:$SkipTests
