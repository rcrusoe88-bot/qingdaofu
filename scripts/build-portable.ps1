# QingDaoFu - Portable Package Builder
# Builds the portable ZIP that end users actually run:
#   QingDaoFu.exe + app\ + rules\ + launcher + notes
#
# NOTE: scripts\build-release.ps1 is inherited from upstream tw93/Mole and
# still packs mole.ps1 / lib\ / cmd\, which QingDaoFu does not use. Use this
# script for QingDaoFu releases.
#
# Requires: the Wails GUI exe already built (wails build in .\gui).

#Requires -Version 5.1
param(
    [string]$Version,
    [string]$ExePath,
    [switch]$SkipTests,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$releaseDir = Join-Path $projectRoot "release"
$versionFile = Join-Path $projectRoot "VERSION"

function Show-BuildHelp {
    Write-Host ""
    Write-Host "QingDaoFu Portable Package Builder" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\build-portable.ps1 [-Version <v>] [-ExePath <path>] [-SkipTests]"
    Write-Host ""
    Write-Host "  -Version <v>    Version string (default: contents of VERSION)"
    Write-Host "  -ExePath <path> Path to QingDaoFu.exe"
    Write-Host "                  (default: gui\build\bin\QingDaoFu.exe)"
    Write-Host "  -SkipTests      Skip the Pester suite before packaging"
    Write-Host ""
    Write-Host "Output: release\qingdaofu-<version>-x64.zip"
    Write-Host "        release\SHA256SUMS.txt"
    Write-Host ""
}

if ($ShowHelp) {
    Show-BuildHelp
    exit 0
}

if (-not $Version) {
    $Version = (Get-Content $versionFile -Raw).Trim()
}
if (-not $ExePath) {
    $ExePath = Join-Path $projectRoot "gui\build\bin\QingDaoFu.exe"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  QingDaoFu - Portable Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Version : $Version" -ForegroundColor Yellow
Write-Host "Exe     : $ExePath" -ForegroundColor Yellow
Write-Host ""

# ---------------------------------------------------------------- pre-flight
Write-Host "[1/5] Pre-flight checks..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Host "  QingDaoFu.exe not found." -ForegroundColor Red
    Write-Host "  Build it first:  cd gui; wails build -platform windows/amd64" -ForegroundColor Gray
    exit 1
}

foreach ($d in @("app", "rules")) {
    $p = Join-Path $projectRoot $d
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host "  Missing required directory: $d\" -ForegroundColor Red
        exit 1
    }
}

$rulesFile = Join-Path $projectRoot "rules\rules.json"
$ruleCount = 0
# Read as UTF8 explicitly, same as app\modules\Core.ps1 does. A bare
# Get-Content in PS 5.1 decodes BOM-less UTF-8 as ANSI and mangles the
# Chinese rule text badly enough to break JSON parsing.
try {
    $text = [System.IO.File]::ReadAllText($rulesFile, [System.Text.Encoding]::UTF8)
    $ruleset = $text | ConvertFrom-Json
    $ruleCount = @($ruleset.rules).Count
} catch {
    Write-Host "  rules\rules.json is not valid JSON: $_" -ForegroundColor Red
    exit 1
}
Write-Host "  QingDaoFu.exe : OK" -ForegroundColor Green
Write-Host "  app\ rules\   : OK" -ForegroundColor Green
Write-Host "  rules.json    : $ruleCount rules" -ForegroundColor Green
Write-Host ""

# -------------------------------------------------------------------- tests
if (-not $SkipTests) {
    Write-Host "[2/5] Running tests..." -ForegroundColor Cyan
    $testScript = Join-Path $projectRoot "qdf-tests\Run-Tests.ps1"
    if (Test-Path -LiteralPath $testScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testScript
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Tests failed. Aborting." -ForegroundColor Red
            exit 1
        }
        Write-Host "  Tests passed" -ForegroundColor Green
    } else {
        Write-Host "  Test script not found, skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "[2/5] Skipping tests (-SkipTests)" -ForegroundColor Yellow
}
Write-Host ""

# ------------------------------------------------------------- stage payload
Write-Host "[3/5] Staging package payload..." -ForegroundColor Cyan

if (Test-Path -LiteralPath $releaseDir) {
    Remove-Item -LiteralPath $releaseDir -Recurse -Force
}
$stage = Join-Path $releaseDir "stage"
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Copy-Item -LiteralPath $ExePath -Destination (Join-Path $stage "QingDaoFu.exe") -Force
Write-Host "  QingDaoFu.exe" -ForegroundColor Gray

Copy-Item -LiteralPath (Join-Path $projectRoot "app") -Destination (Join-Path $stage "app") -Recurse -Force
Write-Host "  app\   ($((Get-ChildItem (Join-Path $stage 'app') -Recurse -File).Count) files)" -ForegroundColor Gray

# rules\ ships rules.json only - never the local candidate/bak scratch files.
$rulesDest = Join-Path $stage "rules"
New-Item -ItemType Directory -Path $rulesDest -Force | Out-Null
Copy-Item -LiteralPath $rulesFile -Destination (Join-Path $rulesDest "rules.json") -Force
Write-Host "  rules\ (rules.json, $ruleCount rules)" -ForegroundColor Gray

# ASCII-only discipline: PowerShell 5.1 reads a BOM-less script as ANSI, so
# UTF-8 CJK literals turn to mojibake. The Chinese-named files (launcher .cmd
# and the readme .txt) are picked up by extension instead of by name.
$extraFiles = New-Object System.Collections.ArrayList
foreach ($p in @(Get-ChildItem -LiteralPath $projectRoot -Filter *.cmd -File -ErrorAction SilentlyContinue)) {
    $null = $extraFiles.Add($p.FullName)
}
foreach ($p in @(Get-ChildItem -LiteralPath $projectRoot -Filter *.txt -File -ErrorAction SilentlyContinue)) {
    $null = $extraFiles.Add($p.FullName)
}
foreach ($n in @("README.md", "LICENSE", "VERSION")) {
    $null = $extraFiles.Add((Join-Path $projectRoot $n))
}

foreach ($src in $extraFiles) {
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage (Split-Path $src -Leaf)) -Force
        Write-Host "  $(Split-Path $src -Leaf)" -ForegroundColor Gray
    }
}
Write-Host ""

# ---------------------------------------------------------------- compress
Write-Host "[4/5] Compressing..." -ForegroundColor Cyan

$archiveName = "qingdaofu-$Version-x64"
$zipPath = Join-Path $releaseDir "$archiveName.zip"
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal -Force
$zipSize = (Get-Item -LiteralPath $zipPath).Length / 1MB
Write-Host "  $archiveName.zip ($([math]::Round($zipSize, 2)) MB)" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------- checksums
Write-Host "[5/5] Generating checksums..." -ForegroundColor Cyan

$sumPath = Join-Path $releaseDir "SHA256SUMS.txt"
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
Set-Content -LiteralPath $sumPath -Value "$hash  $archiveName.zip" -Encoding ASCII
Write-Host "  $hash  $archiveName.zip" -ForegroundColor Green
Write-Host ""

Remove-Item -LiteralPath $stage -Recurse -Force

Write-Host "Done: $zipPath" -ForegroundColor Cyan
Write-Host ""
