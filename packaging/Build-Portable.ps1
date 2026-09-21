$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'dist'
$stageRoot = Join-Path $outputRoot 'stage'
$productName = [string]([char]0x6E05) + [string]([char]0x9053) + [string]([char]0x592B)
$launcherName = [string]([char]0x542F) + [string]([char]0x52A8) + $productName + '.cmd'
# 使用前必读.txt - built from code points so this script stays ASCII-only
$quickStartName = [string]([char]0x4F7F) + [string]([char]0x7528) + [string]([char]0x524D) + [string]([char]0x5FC5) + [string]([char]0x8BFB) + '.txt'
$packageRoot = Join-Path $stageRoot ($productName + '-Portable')
$zipPath = Join-Path $outputRoot ($productName + '-Portable.zip')

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

# Build the Wails GUI shell first: the exe has to sit at the package root,
# next to app\ and rules\, because gui\backend.go resolves the portable root
# from the exe's own directory. A build failure aborts before anything is staged.
$wails = (Get-Command wails -ErrorAction SilentlyContinue).Source
if (-not $wails) {
    $wails = Join-Path $env:USERPROFILE 'go\bin\wails.exe'
}
if (-not (Test-Path -LiteralPath $wails)) {
    throw "wails CLI not found. Install it with: go install github.com/wailsapp/wails/v2/cmd/wails@latest"
}

Push-Location (Join-Path $projectRoot 'gui')
try {
    & $wails build -s -f
    if ($LASTEXITCODE -ne 0) {
        throw "wails build failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $projectRoot 'app') -Destination $packageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'rules') -Destination $packageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'gui\build\bin\QingDaoFu.exe') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot $launcherName) -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot $quickStartName) -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') -Destination $packageRoot

# Zip the folder itself rather than its contents, so extracting yields a single
# 清道夫-Portable\ directory instead of scattering a dozen files into whatever
# folder the user extracted into.
Compress-Archive -Path $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal

Write-Output $zipPath
