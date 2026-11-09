#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$projectRoot = Split-Path -Parent $PSScriptRoot
$installer = [IO.Path]::GetFullPath($InstallerPath)
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Installer not found: $installer" }

$version = ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))).Trim()
$expectedName = "QingDaoFu-$version-x64-setup.exe"
if ([IO.Path]::GetFileName($installer) -cne $expectedName) { throw "Unexpected installer name; expected $expectedName" }

$info = (Get-Item -LiteralPath $installer).VersionInfo
if ($info.ProductVersion -ne $version -and $info.ProductVersion -ne "$version.0") { throw "Unexpected installer version: $($info.ProductVersion)" }

# NSIS compresses most UI strings, so byte inspection is not a reliable
# payload test. Check the build inputs and let the real install smoke test
# verify that app/, rules/ and the launcher actually reach the target.
$bytes = [IO.File]::ReadAllBytes($installer)
$script = [IO.File]::ReadAllText((Join-Path $projectRoot 'gui\build\windows\installer\project.nsi'))
foreach ($needle in @('wails.webview2runtime', 'payload\app', 'payload\rules', 'MUI_FINISHPAGE_RUN')) {
    if (-not $script.Contains($needle)) { throw "Installer script is missing: $needle" }
}
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'gui\build\bin\QingDaoFu.exe') -PathType Leaf)) {
    throw 'Installer payload is missing: QingDaoFu.exe'
}
foreach ($name in @('app\modules\QdfCli.ps1','rules\rules.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ('gui\build\payload\' + $name)) -PathType Leaf)) {
        throw "Installer payload is missing: $name"
    }
}

$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    Version  = $version
    Size     = $bytes.Length
    SHA256   = $hash
    Signed   = (Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'NotSigned'
    Installer = $installer
}
