$ErrorActionPreference = 'Stop'
# Pester 3 syntax is intentional for the Windows PowerShell 5.1 runtime shipped with Windows.
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
$result = Invoke-Pester -Script (Join-Path $PSScriptRoot 'QingDaoFu.Tests.ps1') -PassThru
if ($null -eq $result -or $result.TotalCount -eq 0 -or $result.FailedCount -gt 0) { exit 1 }
Write-Output ('Passed: {0}; Failed: {1}' -f $result.PassedCount, $result.FailedCount)
