$ErrorActionPreference = 'Stop'
$testFile = Join-Path $PSScriptRoot 'QingDaoFu.Tests.ps1'

Import-Module Pester
$result = Invoke-Pester -Script $testFile -PassThru

Write-Output ('Passed: {0}' -f $result.PassedCount)
Write-Output ('Failed: {0}' -f $result.FailedCount)

if ($result.FailedCount -gt 0) {
    exit 1
}
