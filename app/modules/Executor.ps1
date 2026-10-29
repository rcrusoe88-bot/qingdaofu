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

$script:QdfJournalWriters = @{}

function Get-QdfJournalWriter {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:QdfJournalWriters.ContainsKey($Path)) { return $script:QdfJournalWriters[$Path] }
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $writer = [pscustomobject]@{ Stream = $stream; Encoding = (New-Object System.Text.UTF8Encoding($false)); Pending = 0 }
    $script:QdfJournalWriters[$Path] = $writer
    return $writer
}

function Write-QdfJournalEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Event,
        [switch]$Durable
    )
    $writer = Get-QdfJournalWriter -Path $Path
    $bytes = $writer.Encoding.GetBytes(($Event | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine)
    $writer.Stream.Write($bytes, 0, $bytes.Length)
    $writer.Pending++
    if ($Durable -or $Event.Type -eq 'planned' -or $Event.Type -eq 'started' -or $writer.Pending -ge 128) {
        $writer.Stream.Flush($true)
        $writer.Pending = 0
    }
}

function Close-QdfJournalWriter {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $script:QdfJournalWriters.ContainsKey($Path)) { return }
    $writer = $script:QdfJournalWriters[$Path]
    try {
        $writer.Stream.Flush($true)
    }
    finally {
        $writer.Stream.Dispose()
        $script:QdfJournalWriters.Remove($Path)
    }
}

# Case-insensitive child-of test. Note: `([string]$x.Y).Contains`-style casts
# and inline `[string]$obj.Path.StartsWith(...)` parses the cast over the WHOLE
# expression in PowerShell 5.1, turning the bool result into the string
# "False"/"True" — and `if('False')` is truthy. Bind the string first.
function Test-QdfPathUnder {
    param([string]$Path, [string]$Directory)
    return $Path.StartsWith($Directory + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# Pick whole-subtree removal targets out of one category's scan results. A
# candidate directory qualifies only when every live file under it (recursive)
# was scanned as a candidate — then nothing inside is exempt, and the fast
# path deletes the entire subtree in one shot instead of one verified unlink
# per file. minFiles keeps the amortized walk off rules with only a few files.
# Returns disjoint picks: a qualifying parent suppresses its qualifying
# descendants, so one subtree is never counted or deleted twice.
# candidate directory qualifies only when every live file under it (recursive)
# was scanned as a candidate — then nothing inside is exempt, and the fast
# path deletes the entire subtree in one shot instead of one verified unlink
# per file. minFiles keeps the amortized walk off rules with only a few files.
# Returns disjoint picks: a qualifying parent suppresses its qualifying
# descendants, so one subtree is never counted or deleted twice.
function Get-QdfFastPathDirectories {
    param(
        [Parameter(Mandatory = $true)][object[]]$Files,
        [int]$MinFiles = 64
    )

    if ($Files.Count -lt $MinFiles) { return @() }

    # Direct parent directories and the set of candidate paths, built once.
    $dirSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $candidatePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        $path = [string]$file.Path
        $null = $candidatePaths.Add($path)
        $dir = [System.IO.Path]::GetDirectoryName($path)
        if (-not [string]::IsNullOrWhiteSpace($dir)) { $null = $dirSet.Add($dir) }
    }

    # Candidate count and byte total per directory subtree, accumulated once
    # along each file's ancestor chain. The previous version re-walked every
    # file for every distinct directory — O(dirs x files) — so a 200k-file rule
    # spent hours here before the first deletion.
    $subtreeCount = New-Object 'System.Collections.Generic.Dictionary[string, int]' ([System.StringComparer]::OrdinalIgnoreCase)
    $subtreeBytes = New-Object 'System.Collections.Generic.Dictionary[string, long]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        $size = [long]$file.Size
        $dir = [System.IO.Path]::GetDirectoryName([string]$file.Path)
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
            if ($dirSet.Contains($dir)) {
                if ($subtreeCount.ContainsKey($dir)) {
                    $subtreeCount[$dir]++
                    $subtreeBytes[$dir] += $size
                }
                else {
                    $subtreeCount[$dir] = 1
                    $subtreeBytes[$dir] = $size
                }
            }
            $dir = [System.IO.Path]::GetDirectoryName($dir)
        }
    }

    # The coverage walk can dominate on a huge tree (198k files took ~90 s), so
    # it runs on a budget. Whatever was proven before the deadline is still
    # safe to remove as a subtree; the rest falls back to per-file deletion.
    $budget = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetSeconds = 15
    # Largest subtrees first: a rule root that is fully covered is found on the
    # first pass, and one directory delete then replaces hundreds of thousands
    # of per-file deletes.
    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $subtreeCount.GetEnumerator()) {
        if ([int]$entry.Value -ge $MinFiles) { $ordered.Add($entry) }
    }
    $ordered.Sort([System.Comparison[object]] { param($a, $b) ([int]$b.Value).CompareTo([int]$a.Value) })

    $qualifying = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $ordered) {
        if ($budget.Elapsed.TotalSeconds -ge $budgetSeconds) { break }
        $dir = $entry.Key
        $expected = [int]$entry.Value
        if ($candidatePaths.Contains($dir)) { continue }   # the directory itself is a candidate

        # Count live files, stopping the moment the count exceeds what was
        # scanned: coverage can only fail from there, so the full walk is not
        # needed. A walk that throws leaves coverage unproven.
        $liveCount = 0
        $complete = $true
        try {
            foreach ($unused in [System.IO.Directory]::EnumerateFiles($dir, '*', [System.IO.SearchOption]::AllDirectories)) {
                $liveCount++
                if ($liveCount -gt $expected) { break }
            }
        }
        catch { $complete = $false }
        if (-not $complete -or $liveCount -ne $expected) { continue }

        $qualifying.Add([pscustomobject]@{
            Directory = $dir
            Bytes = [long]$subtreeBytes[$dir]
            LiveCount = $expected
        })
    }

    # Disjoint picks: a qualifying parent suppresses its qualifying descendants.
    $picks = New-Object System.Collections.Generic.List[object]
    foreach ($pick in @($qualifying | Sort-Object -Property @{ Expression = 'Directory'; Descending = $true })) {
        $nested = $false
        foreach ($existing in $picks) {
            if (Test-QdfPathUnder -Path ([string]$pick.Directory) -Directory ([string]$existing.Directory)) {
                $nested = $true
                break
            }
        }
        if (-not $nested) { $picks.Add($pick) }
    }
    # ToArray, not @($picks): PowerShell 5.1 throws "parameter type mismatch"
    # when @() wraps a List[object] directly.
    return $picks.ToArray()
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

# Whole-subtree removal for recursion-matched rules on delete actions. The
# scanner guarantees every file under the rule root matches the rule, so a
# directory whose live file count equals its candidate count can be deleted in
# one shot instead of one verified unlink per file — the difference matters for
# caches holding hundreds of thousands of tiny files. Safety: ancestry and
# non-reparse are enforced inside QdfPathLease.DeleteDirectoryVerified, and the
# boundary recheck below covers the directory against rule-external movement.
function Remove-QdfCandidateDirectory {
    param([string]$Path, [object]$Rule, [object[]]$NormalizedRoots)
    if (-not (Test-QdfCandidatePath -Path $Path -Rule $Rule -NormalizedRoots $NormalizedRoots)) {
        throw 'Candidate is outside the safe rule boundary.'
    }
    if (Test-QdfProtectedPath -Path $Path) { throw 'Candidate is protected.' }
    [QdfPathLease]::DeleteDirectoryVerified($Path)
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
        $scanParams = @{
            RulesPath = $RulesPath
            RuleIds = $SelectedRuleIds
            MaxDetailsPerCategory = -1
            SkipLargeFiles = $true
            CancelPath = $CancelPath
        }
        $scan = Invoke-QdfScan @scanParams
        $summary.ScannedCandidateCount = [int](($scan.Categories | Measure-Object -Property ItemCount -Sum).Sum)
        :categories foreach ($category in @($scan.Categories)) {
            $rule = Get-QdfRuleById -Rules $rules -RuleId $category.Id
            $roots = @(Resolve-QdfRuleRoots -Rule $rule | ForEach-Object { Get-QdfNormalizedPath $_.FullName })

            # Fast path: recursion-matched delete rules may have whole subtrees
            # whose every live file is a scanned candidate. Remove each such
            # subtree in one shot, journaling one planned/outcome pair per
            # directory, then let the per-file loop skip its members naturally.
            if (-not $DryRun -and $category.Action -eq 'delete') {
                foreach ($pick in (Get-QdfFastPathDirectories -Files @($category.Files))) {
                    if ($CancelPath -and [System.IO.File]::Exists($CancelPath)) { $summary.State = 'Cancelled'; break categories }
                    $entry = [pscustomobject]@{
                        Type = 'planned'; RuleId = $category.Id; Path = $pick.Directory
                        Size = [long]$pick.Bytes; Action = 'delete'; DryRun = $false; Status = 'Unknown'; Reason = ''
                    }
                    Write-QdfJournalEvent $journalPath $entry
                    try {
                        Remove-QdfCandidateDirectory -Path $pick.Directory -Rule $rule -NormalizedRoots $roots
                        $entry.Status = 'Deleted'; $summary.BytesFreed += [long]$pick.Bytes
                        $summary.SuccessfulCount += [int]$pick.LiveCount
                        # Mark the subtree's scanned members done so the per-file
                        # loop below does not re-walk now-missing paths.
                        foreach ($file in @($category.Files)) {
                            if (Test-QdfPathUnder -Path ([string]$file.Path) -Directory ([string]$pick.Directory)) {
                                $seen[[string]$file.Path] = $true
                            }
                        }
                    }
                    catch {
                        $message = $_.Exception.Message
                        if ($message -match 'being used|used by another process|access.*denied|拒绝访问|进程无法访问') {
                            $entry.Status = 'SkippedBusy'
                            $entry.Reason = $message
                            $summary.SkippedCount++
                            foreach ($file in @($category.Files)) {
                                if (Test-QdfPathUnder -Path ([string]$file.Path) -Directory ([string]$pick.Directory)) {
                                    $seen[[string]$file.Path] = $true
                                }
                            }
                        }
                        else {
                            # Non-lock failures still fall back to verified files.
                            $entry.Status = 'SlowPathFallback'; $entry.Reason = $message
                        }
                    }
                    $entry.Type = 'outcome'
                    try { Write-QdfJournalEvent $journalPath $entry }
                    catch { $summary.JournalIncomplete = $true; throw }
                    if ($receiptItems.Count -lt $MaxReceiptItems) { $receiptItems.Add($entry) }
                    else { $receipt.ReceiptTruncated = $true }
                }
            }

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
    catch {
        if ($_.Exception.Message -match 'cancel') {
            $summary.State = 'Cancelled'
        }
        else {
            $summary.State = 'Failed'; $summary.Error = $_.Exception.Message
        }
    }
    finally {
        Close-QdfJournalWriter -Path $journalPath
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
