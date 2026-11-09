#Requires -Version 5.1
param(
    [string]$OutputDirectory = '',
    [string]$MakensisPath = '',
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$projectRoot = Split-Path -Parent $PSScriptRoot
$version = ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must contain a numeric release version.' }
$config = [IO.File]::ReadAllText((Join-Path $projectRoot 'gui\wails.json')) | ConvertFrom-Json
if ($config.info.productVersion -ne $version) { throw 'Wails product version must match VERSION.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot ('release\installer-' + [guid]::NewGuid().ToString('N')) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh output directory; existing artifacts are never overwritten.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

if (-not $MakensisPath) {
    $command = Get-Command makensis -ErrorAction SilentlyContinue
    if ($command) { $MakensisPath = $command.Source }
}
if (-not $MakensisPath) {
    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\NSIS\makensis.exe",
        "$env:ProgramFiles\NSIS\makensis.exe",
        "$env:LOCALAPPDATA\Programs\NSIS\makensis.exe"
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $MakensisPath = $candidate; break }
    }
}
if (-not $MakensisPath -or -not (Test-Path -LiteralPath $MakensisPath -PathType Leaf)) {
    throw 'NSIS makensis.exe not found. Install NSIS or pass -MakensisPath.'
}

$gocache = Join-Path $OutputDirectory 'gocache'
$wailsVersion = 'v2.17.0'
$wailsExe = Join-Path $gocache ('wails-' + $wailsVersion + '.exe')
if (-not (Test-Path -LiteralPath $wailsExe -PathType Leaf)) {
    New-Item -ItemType Directory -Path $gocache -Force | Out-Null
    $env:GOBIN = $gocache
    & go install "github.com/wailsapp/wails/v2/cmd/wails@$wailsVersion"
    if ($LASTEXITCODE -ne 0) { throw "Cannot install Wails CLI $wailsVersion." }
    $built = Join-Path $gocache 'wails.exe'
    if (-not (Test-Path -LiteralPath $built -PathType Leaf)) { throw 'Wails CLI build produced no executable.' }
    Move-Item -LiteralPath $built -Destination $wailsExe
}

Push-Location $projectRoot
try {
    if (-not $SkipTests) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'qdf-tests\Run-Tests.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'QingDaoFu safety tests failed.' }
        & go test -mod=readonly ./gui ./cmd/... ./internal/...
        if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
        & node --test qdf-tests/frontend.test.cjs
        if ($LASTEXITCODE -ne 0) { throw 'Frontend tests failed.' }
    }
} finally { Pop-Location }

# Stage exactly the files that must sit beside the installed EXE.
$payload = Join-Path $projectRoot 'gui\build\payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
# Wails overwrites its embedded bootstrapper during -nsis; a stale read-only
# copy from a previous build makes os.WriteFile fail on Windows.
$bootstrapper = Join-Path $projectRoot 'gui\build\windows\installer\tmp\MicrosoftEdgeWebview2Setup.exe'
if (Test-Path -LiteralPath $bootstrapper -PathType Leaf) {
    (Get-Item -LiteralPath $bootstrapper -Force).Attributes = [IO.FileAttributes]::Normal
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'app') -Destination $payload -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $payload 'rules') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'rules\rules.json') -Destination (Join-Path $payload 'rules') -Force
foreach ($name in @('VERSION','LICENSE','THIRD_PARTY_NOTICES.md','README.md','RELEASE.md','使用前必读.txt','启动清道夫.cmd')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $payload -Force
}

$guiDir = Join-Path $projectRoot 'gui'
$makensisDir = Split-Path -Parent $MakensisPath
$originalPath = $env:PATH
Push-Location $guiDir
try {
    # Wails invokes "makensis" by name when -nsis is set.
    $env:PATH = $makensisDir + ';' + $env:PATH
    # Embed the signed Microsoft bootstrapper so WebView2 installation never
    # depends on the app's own HTTP download at first launch.
    & $wailsExe build -s -f -platform windows/amd64 -webview2 embed -nsis -installscope user
    if ($LASTEXITCODE -ne 0) { throw 'Wails installer build failed.' }
} finally {
    $env:PATH = $originalPath
    Pop-Location
}

$installer = Join-Path $projectRoot ('gui\build\bin\QingDaoFu-' + $version + '-x64-setup.exe')
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Installer was not created: $installer" }
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
$destination = Join-Path $OutputDirectory ([IO.Path]::GetFileName($installer))
Copy-Item -LiteralPath $installer -Destination $destination
Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value ($hash + '  ' + [IO.Path]::GetFileName($installer)) -Encoding ASCII
& (Join-Path $PSScriptRoot 'Test-Installer.ps1') -InstallerPath $installer | Format-List | Out-Host
Write-Output $destination
