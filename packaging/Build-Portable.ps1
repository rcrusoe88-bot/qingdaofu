$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'dist'
$stageRoot = Join-Path $outputRoot 'stage'
$productName = [string]([char]0x6E05) + [string]([char]0x9053) + [string]([char]0x592B)
$launcherName = [string]([char]0x542F) + [string]([char]0x52A8) + $productName + '.cmd'
$packageRoot = Join-Path $stageRoot ($productName + '-Portable')
$zipPath = Join-Path $outputRoot ($productName + '-Portable.zip')

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $projectRoot 'app') -Destination $packageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot 'rules') -Destination $packageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $projectRoot $launcherName) -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'README-QINGDAO.md') -Destination (Join-Path $packageRoot 'README.md')

Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal

Write-Output $zipPath
