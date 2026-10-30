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

# Walks the exception chain: a static .NET method call surfaces as a
# MethodInvocationException whose inner Win32Exception carries code 5.
function Test-QdfAccessDeniedError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception -is [System.UnauthorizedAccessException]) { return $true }
        if ($exception -is [System.ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 5) { return $true }
        if ($exception.Message -match 'Access is denied|拒绝访问') { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

# Windows refuses to delete a read-only file (Access Denied). Size and mtime
# were verified by the first DeleteVerified call, and the retry verifies them
# again, so clearing the bit cannot widen what gets removed.
function Remove-QdfCandidateFile {
    param([string]$Path, [long]$Size, [datetime]$LastWriteTimeUtc)

    $writeTime = $LastWriteTimeUtc.ToFileTimeUtc()
    try {
        [QdfPathLease]::DeleteVerified($Path, $Size, $writeTime)
        return
    }
    catch {
        $deleteError = $_
        if (-not (Test-QdfAccessDeniedError -ErrorRecord $deleteError)) { throw $deleteError }
    }

    $attributes = $null
    try { $attributes = [System.IO.File]::GetAttributes($Path) }
    catch { throw $deleteError }
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -eq 0) { throw $deleteError }

    [System.IO.File]::SetAttributes(
        $Path,
        [System.IO.FileAttributes](([int]$attributes) -band (-bnot [int][System.IO.FileAttributes]::ReadOnly))
    )
    try {
        [QdfPathLease]::DeleteVerified($Path, $Size, $writeTime)
    }
    catch {
        $retryError = $_
        if ([System.IO.File]::Exists($Path)) {
            try { [System.IO.File]::SetAttributes($Path, $attributes) } catch { }
        }
        throw $retryError
    }
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

# A fully covered directory becomes one unit delete only when it holds at
# least this many files. Coverage is proved by the clean walk itself, so no
# separate planner pass (and no second tree walk) is needed.
$script:QdfMinUnitFiles = 64

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

# Whole-subtree removal for a directory the clean walk proved fully covered.
# One directory delete replaces one verified unlink per file — the difference
# matters for caches holding hundreds of thousands of tiny files. Safety:
# ancestry and non-reparse are enforced inside
# QdfPathLease.DeleteDirectoryVerified, and the boundary recheck below covers
# the directory against rule-external movement.
function Remove-QdfCandidateDirectory {
    param([string]$Path, [object]$Rule, [object[]]$NormalizedRoots)
    if (-not (Test-QdfCandidatePath -Path $Path -Rule $Rule -NormalizedRoots $NormalizedRoots)) {
        throw 'Candidate is outside the safe rule boundary.'
    }
    if (Test-QdfProtectedPath -Path $Path) { throw 'Candidate is protected.' }
    [QdfPathLease]::DeleteDirectoryVerified($Path)
}

function Add-QdfCleanReceiptItem {
    param([hashtable]$Context, [object]$Entry)
    if ($Context.ReceiptItems.Count -lt $Context.MaxReceiptItems) {
        $null = $Context.ReceiptItems.Add($Entry)
    }
    else { $Context.Receipt.ReceiptTruncated = $true }
}

# Progress is rule-granular plus an item counter refreshed every 256 entries;
# per-file events would cost more than the work they report.
function Write-QdfCleanProgress {
    param([hashtable]$Context)
    if ($null -eq $Context.OnProgress) { return }
    & $Context.OnProgress @{
        RuleId = $Context.RuleId
        RuleName = $Context.RuleName
        Index = $Context.RuleIndex
        Total = $Context.RuleTotal
        Items = $Context.CandidateCount
        BytesFreed = $Context.Summary.BytesFreed
    }
}

function Write-QdfCleanOutcome {
    param([hashtable]$Context, [object]$Entry, [string]$Status, [string]$Reason = '')
    $Entry.Type = 'outcome'
    $Entry.Status = $Status
    $Entry.Reason = $Reason
    # Journal failure aborts all subsequent deletions.
    try { Write-QdfJournalEvent $Context.JournalPath $Entry }
    catch { $Context.Summary.JournalIncomplete = $true; throw }
    Add-QdfCleanReceiptItem -Context $Context -Entry $Entry
}

# One verified unlink for a file whose directory is not fully covered. The
# lease pins every ancestor while the delete runs, and DeleteVerified re-checks
# size and mtime against the values the walk read moments ago.
function Invoke-QdfCleanFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File, [hashtable]$Context)

    $summary = $Context.Summary
    $entry = [pscustomobject]@{
        Type = 'planned'; RuleId = $Context.RuleId; Path = $File.FullName; Size = [long]$File.Length
        Action = $Context.Action; DryRun = [bool]$Context.DryRun; Status = 'Unknown'; Reason = ''
    }
    try { Write-QdfJournalEvent $Context.JournalPath $entry }
    catch { $summary.JournalIncomplete = $true; throw }

    $lease = $null
    try {
        if ($Context.DryRun) {
            $entry.Status = 'DryRun'
        }
        elseif ($Context.Action -eq 'recycle') {
            Move-QdfFileToRecycleBin -Path $File.FullName
            $summary.BytesRecycled += [long]$File.Length
            $entry.Status = 'Recycled'
        }
        else {
            $lease = New-Object QdfPathLease($File.FullName)
            Remove-QdfCandidateFile -Path $File.FullName -Size ([long]$File.Length) -LastWriteTimeUtc $File.LastWriteTimeUtc
            $summary.BytesFreed += [long]$File.Length
            $entry.Status = 'Deleted'
        }
        $summary.SuccessfulCount++
    }
    catch {
        if ($_.Exception.Message -eq 'Cancelled.') { throw }
        $entry.Status = 'Failed'; $entry.Reason = $_.Exception.Message; $summary.FailedCount++
        if ($summary.Failures.Count -lt $Context.MaxReceiptItems) { $summary.Failures += $entry.PSObject.Copy() }
    }
    finally { if ($null -ne $lease) { $lease.Dispose() } }
    Write-QdfCleanOutcome -Context $Context -Entry $entry -Status $entry.Status -Reason $entry.Reason
}

# Whole-subtree removal for a directory the walk proved fully covered. A busy
# tree is skipped as a unit: retrying every locked file is what made a running
# browser's cache take tens of minutes. Any other failure still falls back to
# per-file verified removal.
function Invoke-QdfCleanUnit {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$Bytes,
        [int]$Count,
        [hashtable]$Context,
        [object[]]$NormalizedRoots
    )

    $summary = $Context.Summary
    $entry = [pscustomobject]@{
        Type = 'planned'; RuleId = $Context.RuleId; Path = $Path; Size = $Bytes
        Action = 'delete'; DryRun = $false; Status = 'Unknown'; Reason = ''
    }
    try { Write-QdfJournalEvent $Context.JournalPath $entry }
    catch { $summary.JournalIncomplete = $true; throw }

    $status = 'Deleted'
    $reason = ''
    try {
        Remove-QdfCandidateDirectory -Path $Path -Rule $Context.Rule -NormalizedRoots $NormalizedRoots
        $summary.BytesFreed += $Bytes
        $summary.SuccessfulCount += $Count
    }
    catch {
        if ($_.Exception.Message -eq 'Cancelled.') { throw }
        $reason = $_.Exception.Message
        if ($reason -match 'being used|used by another process|access.*denied|拒绝访问|进程无法访问') {
            $status = 'SkippedBusy'
            $summary.SkippedCount++
        }
        else {
            $status = 'SlowPathFallback'
        }
    }
    Write-QdfCleanOutcome -Context $Context -Entry $entry -Status $status -Reason $reason

    if ($status -eq 'SlowPathFallback') {
        $Context.SuppressCount = $true
        try { $null = Invoke-QdfCleanDirectory -Path $Path -Context $Context -AllowUnitDelete $false }
        finally { $Context.SuppressCount = $false }
    }
    return $status
}

# Bottom-up walk that decides and removes in one pass. A directory is fully
# eligible when every file below it is a candidate; such a subtree is returned
# to its parent instead of being deleted, so the largest covered subtree wins
# and one directory delete replaces every per-file unlink inside it. A subtree
# smaller than QdfMinUnitFiles returns its files for individual removal, which
# keeps the old "do not delete a small rule root itself" behavior.
function Invoke-QdfCleanDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Context,
        [bool]$AllowUnitDelete
    )

    $count = 0
    $bytes = 0L
    $fullyEligible = $true
    $filesOut = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $unitsOut = New-Object System.Collections.Generic.List[object]
    $entries = $null

    try { $entries = [System.IO.Directory]::EnumerateFileSystemEntries($Path) }
    catch {
        return [pscustomobject]@{ Eligible = $false; Count = 0; Bytes = 0L; Files = $null }
    }

    try {
        foreach ($entryPath in $entries) {
            $Context['Visited'] = [int]$Context['Visited'] + 1
            if (($Context['Visited'] -band 255) -eq 0) {
                if ($Context['CancelPath'] -and [System.IO.File]::Exists($Context['CancelPath'])) { throw 'Cancelled.' }
                # A failing progress sink (closed UI pipe) must stop deletion,
                # not be mistaken for an unreadable directory below.
                $Context['ProgressCall'] = $true
                Write-QdfCleanProgress -Context $Context
                $Context['ProgressCall'] = $false
            }

            # One FileInfo read serves attributes, length and mtime: the walk
            # and the later unlink share the same cached metadata.
            $info = $null
            try {
                $info = New-Object System.IO.FileInfo($entryPath)
                $attributes = $info.Attributes
            }
            catch {
                $fullyEligible = $false
                continue
            }

            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $fullyEligible = $false
                continue
            }

            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                if (-not $Context['Recurse']) { continue }
                if ($Context['WhitelistActive'] -and
                    (Test-QdfWhitelistedNormalized -NormalizedPath (Get-QdfNormalizedPath -Path $entryPath))) {
                    $fullyEligible = $false
                    continue
                }
                # Never descend into a protected directory, and never let a
                # parent's unit delete swallow one.
                if (Test-QdfProtectedPath -Path $entryPath) {
                    $fullyEligible = $false
                    continue
                }

                $sub = Invoke-QdfCleanDirectory -Path $entryPath -Context $Context -AllowUnitDelete $AllowUnitDelete
                if (-not $sub.Eligible) {
                    $fullyEligible = $false
                    continue
                }
                $count += [int]$sub.Count
                $bytes += [long]$sub.Bytes
                if ($AllowUnitDelete) {
                    if ([int]$sub.Count -ge $script:QdfMinUnitFiles) {
                        $null = $unitsOut.Add([pscustomobject]@{ Directory = $entryPath; Count = [int]$sub.Count; Bytes = [long]$sub.Bytes })
                    }
                    elseif ($null -ne $sub.Files) {
                        foreach ($file in $sub.Files) { $null = $filesOut.Add($file) }
                    }
                }
                continue
            }

            # Scanner-level checks only: the walk already refused reparse
            # entries and protected directories, and the lease re-checks the
            # ancestor chain at unlink time. Re-normalizing every path here
            # would double the cost of the walk for no extra guarantee.
            $name = $info.Name
            if (-not $Context['MatchAll'] -and -not (Test-QdfNameMatchesPatterns -Name $name -Patterns $Context['Patterns'])) {
                $fullyEligible = $false
                continue
            }
            if ($Context['CutoffUtc'] -ne [datetime]::MaxValue -and $info.LastWriteTimeUtc -ge $Context['CutoffUtc']) {
                $fullyEligible = $false
                continue
            }
            if (Test-QdfProtectedLeafName -Name $name) {
                $fullyEligible = $false
                continue
            }
            if ($Context['WhitelistActive'] -and
                (Test-QdfWhitelistedNormalized -NormalizedPath (Get-QdfNormalizedPath -Path $entryPath))) {
                $fullyEligible = $false
                continue
            }

            $count++
            $bytes += [long]$info.Length
            if (-not $Context['SuppressCount']) { $Context['CandidateCount'] = [int]$Context['CandidateCount'] + 1 }
            if ($AllowUnitDelete) { $null = $filesOut.Add($info) }
            else { Invoke-QdfCleanFile -File $info -Context $Context }
        }
    }
    catch [System.IO.IOException] {
        if ($Context['ProgressCall'] -or $Context.Summary.JournalIncomplete) { throw }
        $fullyEligible = $false
    }
    catch [System.UnauthorizedAccessException] {
        if ($Context['ProgressCall'] -or $Context.Summary.JournalIncomplete) { throw }
        $fullyEligible = $false
    }

    if (-not $AllowUnitDelete) {
        return [pscustomobject]@{ Eligible = $false; Count = 0; Bytes = 0L; Files = $null }
    }
    if ($fullyEligible) {
        $files = $null
        if ($count -lt $script:QdfMinUnitFiles) { $files = $filesOut.ToArray() }
        return [pscustomobject]@{ Eligible = $true; Count = $count; Bytes = $bytes; Files = $files }
    }

    # Not fully covered: remove the covered children as units, then the covered
    # files one by one. Anything ineligible stays for the next run.
    foreach ($unit in $unitsOut) {
        $null = Invoke-QdfCleanUnit -Path ([string]$unit.Directory) -Bytes ([long]$unit.Bytes) -Count ([int]$unit.Count) -Context $Context -NormalizedRoots $Context['NormalizedRoots']
    }
    foreach ($file in $filesOut) { Invoke-QdfCleanFile -File $file -Context $Context }
    return [pscustomobject]@{ Eligible = $false; Count = 0; Bytes = 0L; Files = $null }
}

function Invoke-QdfClean {
    param(
        [string]$RulesPath = $script:QdfRulesPath,
        [Parameter(Mandatory = $true)][string[]]$SelectedRuleIds,
        [switch]$DryRun,
        [switch]$SkipOperationLog,
        [string]$ReceiptDirectory = '',
        [int]$MaxReceiptItems = 2000,
        [string]$CancelPath = '',
        [scriptblock]$OnProgress = $null
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

    try {
        $ruleIndex = 0
        $ruleTotal = $SelectedRuleIds.Count
        foreach ($ruleId in $SelectedRuleIds) {
            if ($CancelPath -and [System.IO.File]::Exists($CancelPath)) { $summary.State = 'Cancelled'; break }
            $rule = Get-QdfRuleById -Rules $rules -RuleId $ruleId
            $ruleIndex++
            $roots = @(Resolve-QdfRuleRoots -Rule $rule)
            if ($roots.Count -eq 0) { continue }

            $patterns = @(Get-QdfPropertyValue -Object $rule -Name 'filePatterns' -DefaultValue @('*'))
            $context = @{
                Summary = $summary
                Receipt = $receipt
                ReceiptItems = $receiptItems
                JournalPath = $journalPath
                Rule = $rule
                RuleId = $ruleId
                RuleName = [string](Get-QdfPropertyValue -Object $rule -Name 'name' -DefaultValue $ruleId)
                RuleIndex = $ruleIndex
                RuleTotal = $ruleTotal
                CutoffUtc = (Get-QdfRuleCutoffUtc -Rule $rule)
                Patterns = $patterns
                MatchAll = ($patterns.Count -eq 0 -or ($patterns.Count -eq 1 -and [string]$patterns[0] -eq '*'))
                Recurse = [bool](Get-QdfPropertyValue -Object $rule -Name 'recurse' -DefaultValue $false)
                Action = [string](Get-QdfPropertyValue -Object $rule -Name 'action' -DefaultValue 'delete')
                DryRun = [bool]$DryRun
                WhitelistActive = (@(Get-QdfWhitelistEntries).Count -gt 0)
                CancelPath = $CancelPath
                MaxReceiptItems = $MaxReceiptItems
                NormalizedRoots = @($roots | ForEach-Object { Get-QdfNormalizedPath -Path $_.FullName })
                Visited = 0
                CandidateCount = 0
                SuppressCount = $false
                ProgressCall = $false
                OnProgress = $OnProgress
            }
            Write-QdfCleanProgress -Context $context
            $allowUnit = $context['Recurse'] -and $context['Action'] -eq 'delete' -and (-not $DryRun)

            foreach ($root in $roots) {
                if ($CancelPath -and [System.IO.File]::Exists($CancelPath)) { $summary.State = 'Cancelled'; break }
                if ($root.PSIsContainer) {
                    $result = Invoke-QdfCleanDirectory -Path $root.FullName -Context $context -AllowUnitDelete $allowUnit
                    if ($allowUnit -and $result.Eligible -and [int]$result.Count -gt 0) {
                        if ([int]$result.Count -ge $script:QdfMinUnitFiles) {
                            $null = Invoke-QdfCleanUnit -Path $root.FullName -Bytes ([long]$result.Bytes) -Count ([int]$result.Count) -Context $context -NormalizedRoots $context['NormalizedRoots']
                        }
                        elseif ($null -ne $result.Files) {
                            foreach ($file in $result.Files) { Invoke-QdfCleanFile -File $file -Context $context }
                        }
                    }
                }
                else {
                    # A rule may point at one file; it has no directory to fold.
                    $info = $null
                    try {
                        $info = New-Object System.IO.FileInfo($root.FullName)
                        $attributes = $info.Attributes
                    }
                    catch { continue }
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (-not $context['MatchAll'] -and -not (Test-QdfNameMatchesPatterns -Name $info.Name -Patterns $patterns)) { continue }
                    if ($context['CutoffUtc'] -ne [datetime]::MaxValue -and $info.LastWriteTimeUtc -ge $context['CutoffUtc']) { continue }
                    if (Test-QdfProtectedLeafName -Name $info.Name) { continue }
                    $context['CandidateCount'] = [int]$context['CandidateCount'] + 1
                    Invoke-QdfCleanFile -File $info -Context $context
                }
            }
            $summary.ScannedCandidateCount += [int]$context['CandidateCount']
            Write-QdfCleanProgress -Context $context
            if ($summary.State -eq 'Cancelled') { break }
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
