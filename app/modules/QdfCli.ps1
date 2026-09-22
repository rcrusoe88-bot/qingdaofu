<#
QdfCli.ps1 - QingDaoFu CLI shim for the Wails GUI.

Emits NDJSON (one compressed JSON object per line, UTF-8) on stdout:
  progress  {type:"progress", phase, ruleId, ruleName, index, total}
  result    last line on success; shape matches Invoke-QdfScan /
            Invoke-QdfClean / operations log entries / strings file
  error     {type:"error", message}

Exit codes: 0 success, 2 argument/file error, 3 crash.
Does NOT dot-source Gui*.ps1 (no WinForms dependency).
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('scan', 'clean', 'history', 'receipt', 'strings')]
    [string]$Command,

    [string]$RulesPath = '',

    [string[]]$RuleIds = @(),

    [switch]$DryRun,

    [string]$ReceiptPath = '',

    [string]$CancelPath = '',

    [int]$Last = 50
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# The GUI hands over -RuleIds as a single comma-joined argument, because
# PowerShell's -File binding cannot split an array (see gui/psproc.go). Empty
# entries are kept on purpose: "-RuleIds ''" means "nothing was selected", and
# filtering it away would leave Count at 0, which the branches below read as
# "no -RuleIds given at all" and turn into a full scan.
$RuleIds = @($RuleIds -split ',')

$script:QdfCliExitCode = 0

function Write-QdfCliLine {
    param([Parameter(Mandatory = $true)][object]$Object)
    $json = $Object | ConvertTo-Json -Compress -Depth 8
    if ($json.Length -gt 32768) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        for ($offset = 0; $offset -lt $bytes.Length; $offset += 24576) {
            $count = [math]::Min(24576, $bytes.Length - $offset)
            $frame = @{ type = 'result-chunk'; data = [Convert]::ToBase64String($bytes, $offset, $count) }
            [Console]::Out.WriteLine(($frame | ConvertTo-Json -Compress))
        }
        [Console]::Out.WriteLine('{"type":"result-end"}')
    }
    else { [Console]::Out.WriteLine($json) }
}

function Write-QdfCliError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-QdfCliLine -Object @{ type = 'error'; message = $Message }
}

try {
    # Locate app root the same way app/QingDaoFu.ps1 does.
    $qdfCliPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($qdfCliPath)) {
        $qdfCliPath = $PSCommandPath
    }
    $script:QdfAppRoot = Split-Path -Parent (Split-Path -Parent $qdfCliPath)
    $script:QdfProjectRoot = Split-Path -Parent $script:QdfAppRoot
    if ([string]::IsNullOrWhiteSpace($RulesPath)) {
        $script:QdfRulesPath = Join-Path $script:QdfProjectRoot 'rules\rules.json'
    }
    else {
        $script:QdfRulesPath = $RulesPath
    }
    $script:QdfStringsPath = Join-Path $script:QdfAppRoot 'strings.zh-CN.json'

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $script:QdfDataRoot = Join-Path $env:USERPROFILE 'AppData\Local\QingDaoFu'
    }
    else {
        $script:QdfDataRoot = Join-Path $env:LOCALAPPDATA 'QingDaoFu'
    }

    . (Join-Path $script:QdfAppRoot 'modules\Core.ps1')
    . (Join-Path $script:QdfAppRoot 'modules\Scanner.ps1')
    . (Join-Path $script:QdfAppRoot 'modules\Executor.ps1')

    switch ($Command) {
        'strings' {
            Write-QdfCliLine -Object (Read-QdfJsonFile -Path $script:QdfStringsPath)
        }

        'scan' {
            $ruleset = Read-QdfJsonFile -Path $script:QdfRulesPath
            Test-QdfRuleset -Ruleset $ruleset
            $allRules = @(Get-QdfPropertyValue -Object $ruleset -Name 'rules' -DefaultValue @())
            if ($RuleIds.Count -gt 0) {
                $allRules = @(
                    foreach ($rule in $allRules) {
                if ((Get-QdfPropertyValue $rule 'enabled' $true) -eq $false) { continue }
                        $id = [string](Get-QdfPropertyValue -Object $rule -Name 'id' -DefaultValue '')
                        if ($RuleIds -contains $id) {
                            $rule
                        }
                    }
                )
            }

            $cleanupRules = @()
            $largeRule = $null
            foreach ($rule in $allRules) {
                $kind = [string](Get-QdfPropertyValue -Object $rule -Name 'kind' -DefaultValue 'cleanup')
                if ($kind -eq 'large-files') {
                    $largeRule = $rule
                }
                else {
                    $cleanupRules += $rule
                }
            }

            $total = $cleanupRules.Count
            if ($null -ne $largeRule) {
                $total++
            }
            $index = 0
            $categories = @(foreach ($rule in $cleanupRules) {
                $index++
                $id = [string](Get-QdfPropertyValue -Object $rule -Name 'id' -DefaultValue '')
                $name = [string](Get-QdfPropertyValue -Object $rule -Name 'name' -DefaultValue '')
                Write-QdfCliLine -Object @{
                    type = 'progress'; phase = 'scan'; ruleId = $id
                    ruleName = $name; index = $index; total = $total
                }
                $single = Invoke-QdfScan `
                    -RulesPath $script:QdfRulesPath `
                    -RuleIds @($id) `
                    -SkipLargeFiles -MaxDetailsPerCategory 200
                @($single.Categories)
            })

            $largeFiles = @()
            $skipped = @()
            if ($null -ne $largeRule) {
                $index++
                $id = [string](Get-QdfPropertyValue -Object $largeRule -Name 'id' -DefaultValue '')
                $name = [string](Get-QdfPropertyValue -Object $largeRule -Name 'name' -DefaultValue '')
                Write-QdfCliLine -Object @{
                    type = 'progress'; phase = 'scan'; ruleId = $id
                    ruleName = $name; index = $index; total = $total
                }
                $largeScan = Invoke-QdfScan -RulesPath $script:QdfRulesPath -RuleIds @($id)
                $largeFiles = @($largeScan.LargeFiles)
                $skipped = @($largeScan.Skipped)
            }

            $sortedCategories = @($categories | Sort-Object -Property @{ Expression = 'TotalSize'; Descending = $true })
            $totalCandidateSize = 0L
            foreach ($category in $sortedCategories) {
                if ($category.Action -ne 'readonly') {
                    $totalCandidateSize += [long]$category.TotalSize
                }
            }

            Write-QdfCliLine -Object @{
                type = 'result'
                RulesPath = (Get-QdfNormalizedPath -Path $script:QdfRulesPath)
                StartedAt = ''
                CompletedAt = ([datetime]::UtcNow.ToString('o'))
                Categories = $sortedCategories
                LargeFiles = $largeFiles
                Skipped = $skipped
                TotalCandidateSize = $totalCandidateSize
                TotalCandidateSizeText = (Format-QdfSize -Bytes $totalCandidateSize)
            }
        }

        'clean' {
            if ($RuleIds.Count -eq 0) {
                throw 'No cleanup rules were selected.'
            }
            $names = @()
            $ruleset = Read-QdfJsonFile -Path $script:QdfRulesPath
            foreach ($ruleId in $RuleIds) {
                $rule = Get-QdfRuleById -Rules @(Get-QdfPropertyValue -Object $ruleset -Name 'rules' -DefaultValue @()) -RuleId $ruleId
                if ($null -ne $rule) {
                    $names += [string](Get-QdfPropertyValue -Object $rule -Name 'name' -DefaultValue '')
                }
            }
            Write-QdfCliLine -Object @{
                type = 'progress'; phase = 'clean'; ruleId = ($RuleIds -join ',')
                ruleName = ($names -join '、'); index = 1; total = 1
            }
            $summary = Invoke-QdfClean `
                -RulesPath $script:QdfRulesPath `
                -SelectedRuleIds $RuleIds `
                -DryRun:$DryRun -CancelPath $CancelPath
            $resultObject = @{ type = 'result' }
            foreach ($property in $summary.PSObject.Properties) {
                $resultObject[$property.Name] = $property.Value
            }
            Write-QdfCliLine -Object $resultObject
        }

        'history' {
            $logPath = Join-Path (Join-Path $script:QdfDataRoot 'logs') 'operations.jsonl'
            if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
                Write-QdfCliLine -Object @{ type = 'result'; Items = @() }
                break
            }
            $lines = [System.IO.File]::ReadAllLines($logPath, [System.Text.Encoding]::UTF8)
            $entries = @(
                foreach ($line in $lines) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        ($line | ConvertFrom-Json)
                    }
                }
            )
            $entries = @($entries | Select-Object -Last $Last)
            [array]::Reverse($entries)
            Write-QdfCliLine -Object @{ type = 'result'; Items = $entries }
        }

        'receipt' {
            if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
                throw 'ReceiptPath is required.'
            }
            $root = Join-Path $script:QdfDataRoot 'receipts'
            $full = [System.IO.Path]::GetFullPath($ReceiptPath)
            $fullRoot = [System.IO.Path]::GetFullPath($root)
            if (-not (Test-QdfPathChain $full) -or -not $full.StartsWith($fullRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Receipt path is outside the receipts directory: $ReceiptPath"
            }
            Write-QdfCliLine -Object (Read-QdfJsonFile -Path $full)
        }
    }
}
catch {
    $script:QdfCliExitCode = 2
    Write-QdfCliError -Message $_.Exception.Message
}
finally {
    exit $script:QdfCliExitCode
}
