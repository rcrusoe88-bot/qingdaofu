#Requires -Version 5.1
param([string]$OutputDirectory = '', [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$projectRoot = Split-Path -Parent $PSScriptRoot
$version = ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must contain a numeric release version.' }
if ($env:GITHUB_REF -like 'refs/tags/*' -and $env:GITHUB_REF -ne ('refs/tags/v' + $version)) { throw 'Release tag and VERSION differ.' }
$config = [IO.File]::ReadAllText((Join-Path $projectRoot 'gui\wails.json')) | ConvertFrom-Json
if ($config.info.productVersion -ne $version) { throw 'Wails product version must match VERSION.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot ('release\build-' + [guid]::NewGuid().ToString('N')) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zip = Join-Path $OutputDirectory ('qingdaofu-' + $version + '-x64.zip')
if (Test-Path -LiteralPath $zip) { throw 'Use a fresh output directory; existing artifacts are never overwritten.' }
Push-Location $projectRoot
try {
    if (-not $SkipTests) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'qdf-tests\Run-Tests.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'QingDaoFu safety tests failed.' }
        & go test -mod=readonly ./gui ./cmd/...
        if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
        & go vet -mod=readonly ./gui ./cmd/...
        if ($LASTEXITCODE -ne 0) { throw 'Go vet failed.' }
        & node --test qdf-tests/frontend.test.cjs
        if ($LASTEXITCODE -ne 0) { throw 'Frontend tests failed.' }
    }
    $sourceCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve source commit.' }
    $sourceDirty = [bool](& git status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect source state.' }
    if ($env:GITHUB_REF -like 'refs/tags/*' -and $sourceDirty) { throw 'Tagged release requires a clean checkout.' }
} finally { Pop-Location }
$wails = (Get-Command wails -ErrorAction Stop).Source
Push-Location (Join-Path $projectRoot 'gui')
try {
    & $wails build -s -f -platform windows/amd64
    if ($LASTEXITCODE -ne 0) { throw 'Wails build failed.' }
} finally { Pop-Location }
$exe = Join-Path $projectRoot 'gui\build\bin\QingDaoFu.exe'
$exeVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersionRaw.ToString()
if ($exeVersion -ne $version -and $exeVersion -ne ($version + '.0')) { throw "Unexpected executable version: $exeVersion" }
# Unique staging never recursively deletes pre-existing directories.
$stage = Join-Path $OutputDirectory ('stage-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $stage 'QingDaoFu-Portable'
New-Item -ItemType Directory -Path $package -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'app') -Destination $package -Recurse
New-Item -ItemType Directory -Path (Join-Path $package 'rules') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'rules\rules.json') -Destination (Join-Path $package 'rules')
Copy-Item -LiteralPath $exe -Destination $package
foreach ($name in @('VERSION','LICENSE','THIRD_PARTY_NOTICES.md','README.md','RELEASE.md')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $package
}
$launcher = [string]([char]0x542F) + [string]([char]0x52A8) + [string]([char]0x6E05) + [string]([char]0x9053) + [string]([char]0x592B) + '.cmd'
$notes = [string]([char]0x4F7F) + [string]([char]0x7528) + [string]([char]0x524D) + [string]([char]0x5FC5) + [string]([char]0x8BFB) + '.txt'
foreach ($name in @($launcher,$notes)) { Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $package }
$rules = ([IO.File]::ReadAllText((Join-Path $package 'rules\rules.json')) | ConvertFrom-Json).rules
$files = @(Get-ChildItem -LiteralPath $package -Recurse -File | ForEach-Object {
    [pscustomobject]@{ Path = $_.FullName.Substring($package.Length + 1).Replace('\','/'); SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$manifest = [ordered]@{
    Version = $version; SourceCommit = $sourceCommit; SourceDirty = $sourceDirty; BuiltAtUtc = [datetime]::UtcNow.ToString('o')
    RuleCount = @($rules).Count; RuleIds = @($rules.id | Sort-Object)
    Validation = $(if ($SkipTests) { 'tests-skipped' } else { 'powershell-go-vet-frontend-passed' })
    Files = $files
}
[IO.File]::WriteAllText((Join-Path $package 'BUILD-MANIFEST.json'), ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Compress-Archive -LiteralPath $package -DestinationPath $zip -CompressionLevel Optimal
& (Join-Path $PSScriptRoot 'Test-PortableArchive.ps1') -ArchivePath $zip | Format-List | Out-Host
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Value ($hash + '  ' + [IO.Path]::GetFileName($zip)) -Encoding ASCII
Write-Output $zip
