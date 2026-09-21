function Move-QdfFileToRecycleBin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
        [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
    )
}

function Remove-QdfCandidateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    [System.IO.File]::Delete($Path)
}

function Invoke-QdfClean {
    param(
        [string]$RulesPath = $script:QdfRulesPath,

        [Parameter(Mandatory = $true)]
        [string[]]$SelectedRuleIds,

        [switch]$DryRun,

        [switch]$SkipOperationLog,

        [string]$ReceiptDirectory = '',

        # A receipt is for a human to review: 50k paths are unreviewable, and a
        # receipt that large runs to tens of MB, which accumulates into GBs of
        # receipts over time.
        [int]$MaxReceiptItems = 2000
    )

    if ($SelectedRuleIds.Count -eq 0) {
        throw 'No cleanup rules were selected.'
    }

    if ([string]::IsNullOrWhiteSpace($ReceiptDirectory)) {
        $ReceiptDirectory = Join-Path $script:QdfDataRoot 'receipts'
    }

    $scan = Invoke-QdfScan `
        -RulesPath $RulesPath `
        -RuleIds $SelectedRuleIds `
        -MaxDetailsPerCategory -1 `
        -SkipLargeFiles
    $ruleset = Read-QdfJsonFile -Path $RulesPath
    $rules = @(Get-QdfPropertyValue -Object $ruleset -Name 'rules' -DefaultValue @())

    $startedAt = [datetime]::UtcNow
    $results = New-Object System.Collections.Generic.List[object]
    $receiptItems = New-Object System.Collections.Generic.List[object]
    $successfulCount = 0
    $failedCount = 0
    $skippedCount = 0
    $bytesFreed = 0L
    $bytesRecycled = 0L

    foreach ($category in @($scan.Categories)) {
        $rule = Get-QdfRuleById -Rules $rules -RuleId $category.Id
        if ($null -eq $rule) {
            continue
        }

        $ruleRoots = @(Resolve-QdfRuleRoots -Rule $rule)
        $normalizedRuleRoots = @(
            foreach ($root in $ruleRoots) {
                Get-QdfNormalizedPath -Path $root.FullName
            }
        )
        foreach ($file in @($category.Files)) {
            $candidatePath = [string](Get-QdfPropertyValue -Object $file -Name 'Path' -DefaultValue '')
            $candidateSize = [long](Get-QdfPropertyValue -Object $file -Name 'Size' -DefaultValue 0)

            if ([string]::IsNullOrWhiteSpace($candidatePath) -or -not [System.IO.File]::Exists($candidatePath)) {
                $skippedCount++
                continue
            }

            try {
                $attributes = [System.IO.File]::GetAttributes($candidatePath)
            }
            catch {
                $skippedCount++
                continue
            }

            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $skippedCount++
                continue
            }

            if (-not (Test-QdfCandidatePath -Path $candidatePath -Rule $rule -NormalizedRoots $normalizedRuleRoots -PathIsNormalized)) {
                $skippedCount++
                continue
            }

            if ($receiptItems.Count -lt $MaxReceiptItems) {
                $receiptItems.Add([pscustomobject]@{
                    RuleId = $category.Id
                    Path = $candidatePath
                    Size = $candidateSize
                    Action = $category.Action
                    PlannedAt = [datetime]::UtcNow.ToString('o')
                    DryRun = [bool]$DryRun
                })
            }

            if ($DryRun) {
                $successfulCount++
                continue
            }

            try {
                if ($category.Action -eq 'recycle') {
                    Move-QdfFileToRecycleBin -Path $candidatePath
                    $bytesRecycled += $candidateSize
                }
                else {
                    Remove-QdfCandidateFile -Path $candidatePath
                    $bytesFreed += $candidateSize
                }

                $successfulCount++
            }
            catch {
                $failedCount++
                $results.Add([pscustomobject]@{
                    RuleId = $category.Id
                    Path = $candidatePath
                    Action = $category.Action
                    Success = $false
                    Reason = $_.Exception.Message
                })
            }
        }
    }

    $completedAt = [datetime]::UtcNow
    $summary = [pscustomobject]@{
        StartedAt = $startedAt.ToString('o')
        CompletedAt = $completedAt.ToString('o')
        DryRun = [bool]$DryRun
        SelectedRuleIds = @($SelectedRuleIds)
        ScannedCandidateCount = [int](($scan.Categories | Measure-Object -Property ItemCount -Sum).Sum)
        ProcessedCount = $successfulCount
        SuccessfulCount = $successfulCount
        FailedCount = $failedCount
        SkippedCount = $skippedCount
        BytesFreed = $bytesFreed
        BytesFreedText = Format-QdfSize -Bytes $bytesFreed
        BytesRecycled = $bytesRecycled
        BytesRecycledText = Format-QdfSize -Bytes $bytesRecycled
        Failures = $results.ToArray()
        ReceiptPath = ''
    }

    $receiptObject = [pscustomobject]@{
        Summary = $summary
        Items = $receiptItems.ToArray()
        ReceiptTruncated = ($receiptItems.Count -ge $MaxReceiptItems)
    }
    $summary.ReceiptPath = New-QdfReceipt -Result $receiptObject -ReceiptDirectory $ReceiptDirectory

    if (-not $DryRun -and -not $SkipOperationLog) {
        Write-QdfOperationLog -Summary $summary
    }

    return $summary
}
