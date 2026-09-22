function Move-QdfFileToRecycleBin {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $Path,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
        [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
    )
    if ([System.IO.File]::Exists($Path)) { throw 'The recycle operation did not remove the candidate.' }
}

function Remove-QdfCandidateFile {
    param([string]$Path, [long]$Size, [datetime]$LastWriteTimeUtc)
    [QdfPathLease]::DeleteVerified($Path, $Size, $LastWriteTimeUtc.ToFileTimeUtc())
}

function Write-QdfJournalEvent {
    param([string]$Path, [object]$Event)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($Event | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}

function Save-QdfReceipt {
    param([string]$Path, [object]$Receipt)
    $temporary = $Path + '.tmp'
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($Receipt | ConvertTo-Json -Depth 8))
    $stream = New-Object System.IO.FileStream($temporary, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($temporary, $Path) }
}

function Invoke-QdfClean {
    param(
        [string]$RulesPath = $script:QdfRulesPath,
        [Parameter(Mandatory = $true)][string[]]$SelectedRuleIds,
        [switch]$DryRun,
        [switch]$SkipOperationLog,
        [string]$ReceiptDirectory = '',
        [int]$MaxReceiptItems = 2000,
        [string]$CancelPath = ''
    )
    if ($SelectedRuleIds.Count -eq 0) { throw 'No cleanup rules were selected.' }
    $ruleset = Read-QdfJsonFile -Path $RulesPath
    Test-QdfRuleset -Ruleset $ruleset
    $rules = @($ruleset.rules)
    foreach ($id in $SelectedRuleIds) {
        $rule = Get-QdfRuleById -Rules $rules -RuleId $id
        if ($null -eq $rule -or $rule.kind -ne 'cleanup' -or (Get-QdfPropertyValue $rule 'enabled' $true) -eq $false) {
            throw "Unknown or disabled cleanup rule: $id"
        }
    }
    if ([string]::IsNullOrWhiteSpace($ReceiptDirectory)) { $ReceiptDirectory = Join-Path $script:QdfDataRoot 'receipts' }
    if (-not (Test-Path -LiteralPath $ReceiptDirectory)) { New-Item -ItemType Directory -Path $ReceiptDirectory -Force | Out-Null }
    $receiptPath = Join-Path $ReceiptDirectory ('receipt-' + [guid]::NewGuid().ToString('N') + '.json')
    $journalPath = $receiptPath + '.jsonl'
    $summary = [pscustomobject]@{
        StartedAt = [datetime]::UtcNow.ToString('o'); CompletedAt = ''; State = 'Incomplete'
        DryRun = [bool]$DryRun; SelectedRuleIds = @($SelectedRuleIds)
        ScannedCandidateCount = 0; ProcessedCount = 0; SuccessfulCount = 0; FailedCount = 0; SkippedCount = 0
        BytesFreed = 0L; BytesFreedText = '0 B'; BytesRecycled = 0L; BytesRecycledText = '0 B'
        Failures = @(); ReceiptPath = $receiptPath; Error = ''; JournalIncomplete = $false
    }
    $receiptItems = New-Object System.Collections.Generic.List[object]
    $receipt = [pscustomobject]@{ Summary = $summary; Items = @(); ReceiptTruncated = $false }
    # A durable initial receipt must exist before any deletion, even if logging is unavailable.
    Save-QdfReceipt -Path $receiptPath -Receipt $receipt
    Write-QdfJournalEvent $journalPath @{ Type = 'started'; At = $summary.StartedAt }
    $seen = @{}
    try {
        $scan = Invoke-QdfScan -RulesPath $RulesPath -RuleIds $SelectedRuleIds -MaxDetailsPerCategory -1 -SkipLargeFiles
        $summary.ScannedCandidateCount = [int](($scan.Categories | Measure-Object -Property ItemCount -Sum).Sum)
        :categories foreach ($category in @($scan.Categories)) {
            $rule = Get-QdfRuleById -Rules $rules -RuleId $category.Id
            $roots = @(Resolve-QdfRuleRoots -Rule $rule | ForEach-Object { Get-QdfNormalizedPath $_.FullName })
            foreach ($file in @($category.Files)) {
                if ($CancelPath -and [System.IO.File]::Exists($CancelPath)) { $summary.State = 'Cancelled'; break categories }
                $candidatePath = [string]$file.Path
                if ($seen.ContainsKey($candidatePath)) { continue }
                $seen[$candidatePath] = $true
                $entry = [pscustomobject]@{
                    Type = 'planned'; RuleId = $category.Id; Path = $candidatePath; Size = [long]$file.Size
                    Action = $category.Action; DryRun = [bool]$DryRun; Status = 'Unknown'; Reason = ''
                }
                # A crash between planned and outcome means UNKNOWN, never an assumed success.
                Write-QdfJournalEvent $journalPath $entry
                $lease = $null
                try {
                    $lease = New-Object QdfPathLease($candidatePath)
                    if (-not (Test-QdfCandidatePath -Path $candidatePath -Rule $rule -NormalizedRoots $roots)) { throw 'Candidate is outside the safe rule boundary.' }
                    $current = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
                    $expectedTime = [datetime]::Parse($file.LastWriteTimeUtc).ToUniversalTime()
                    if ($current.PSIsContainer -or $current.Length -ne $file.Size -or $current.LastWriteTimeUtc -ne $expectedTime) { throw 'Candidate changed after scanning.' }
                    if ($DryRun) { $entry.Status = 'DryRun' }
                    elseif ($category.Action -eq 'recycle') {
                        Move-QdfFileToRecycleBin -Path $candidatePath
                        $entry.Status = 'Recycled'; $summary.BytesRecycled += $file.Size
                    }
                    else {
                        Remove-QdfCandidateFile -Path $candidatePath -Size $file.Size -LastWriteTimeUtc $expectedTime
                        $entry.Status = 'Deleted'; $summary.BytesFreed += $file.Size
                    }
                    $summary.SuccessfulCount++
                }
                catch {
                    $entry.Status = 'Failed'; $entry.Reason = $_.Exception.Message; $summary.FailedCount++
                    if ($summary.Failures.Count -lt $MaxReceiptItems) { $summary.Failures += $entry.PSObject.Copy() }
                }
                finally { if ($null -ne $lease) { $lease.Dispose() } }
                $entry.Type = 'outcome'
                # Journal failure aborts all subsequent deletions.
                try { Write-QdfJournalEvent $journalPath $entry }
                catch { $summary.JournalIncomplete = $true; throw }
                if ($receiptItems.Count -lt $MaxReceiptItems) { $receiptItems.Add($entry) }
                else { $receipt.ReceiptTruncated = $true }
            }
        }
        if ($summary.State -ne 'Cancelled') {
            $summary.State = if ($summary.FailedCount -gt 0) { 'Partial' } else { 'Completed' }
        }
    }
    catch { $summary.State = 'Failed'; $summary.Error = $_.Exception.Message }
    finally {
        $summary.CompletedAt = [datetime]::UtcNow.ToString('o')
        $summary.ProcessedCount = $summary.SuccessfulCount
        $summary.BytesFreedText = Format-QdfSize $summary.BytesFreed
        $summary.BytesRecycledText = Format-QdfSize $summary.BytesRecycled
        $receipt.Items = $receiptItems.ToArray()
        Save-QdfReceipt -Path $receiptPath -Receipt $receipt
    }
    # Receipts are the source of truth; a secondary log failure cannot erase the result.
    if (-not $DryRun -and -not $SkipOperationLog) {
        try { Write-QdfOperationLog -Summary $summary }
        catch { $summary.Error = 'Operation log unavailable: ' + $_.Exception.Message; Save-QdfReceipt $receiptPath $receipt }
    }
    return $summary
}
