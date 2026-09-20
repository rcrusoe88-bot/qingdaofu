Set-StrictMode -Version 2.0

$qdfLoaderPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($qdfLoaderPath)) {
    $qdfLoaderPath = $PSCommandPath
}
if ([string]::IsNullOrWhiteSpace($qdfLoaderPath)) {
    throw 'Unable to resolve the QingDaoFu loader path.'
}

$script:QdfAppRoot = Split-Path -Parent $qdfLoaderPath
$script:QdfProjectRoot = Split-Path -Parent $script:QdfAppRoot
$script:QdfRulesPath = Join-Path $script:QdfProjectRoot 'rules\rules.json'
$script:QdfStringsPath = Join-Path $script:QdfAppRoot 'strings.zh-CN.json'
$script:QdfAssetRoot = Join-Path $script:QdfAppRoot 'assets'

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $script:QdfDataRoot = Join-Path $env:USERPROFILE 'AppData\Local\QingDaoFu'
}
else {
    $script:QdfDataRoot = Join-Path $env:LOCALAPPDATA 'QingDaoFu'
}

. (Join-Path $script:QdfAppRoot 'modules\Core.ps1')
. (Join-Path $script:QdfAppRoot 'modules\Scanner.ps1')
. (Join-Path $script:QdfAppRoot 'modules\Executor.ps1')
. (Join-Path $script:QdfAppRoot 'modules\Gui.ps1')
. (Join-Path $script:QdfAppRoot 'modules\Gui.Arcade.ps1')
