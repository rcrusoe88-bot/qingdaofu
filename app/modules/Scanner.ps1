function Test-QdfRuleset {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Ruleset
    )

    $schemaVersion = [int](Get-QdfPropertyValue -Object $Ruleset -Name 'schemaVersion' -DefaultValue 0)
    if ($schemaVersion -ne 1) {
        throw "Unsupported rules schema version: $schemaVersion"
    }

    $rules = @(Get-QdfPropertyValue -Object $Ruleset -Name 'rules' -DefaultValue @())
    if ($rules.Count -eq 0) {
        throw 'No cleanup rules were found.'
    }

    $seenIds = @{}
    foreach ($rule in $rules) {
        $id = [string](Get-QdfPropertyValue -Object $rule -Name 'id' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($id)) {
            throw 'A rule is missing its id.'
        }

        if ($seenIds.ContainsKey($id)) {
            throw "Duplicate rule id: $id"
        }
        $seenIds[$id] = $true

        $kind = [string](Get-QdfPropertyValue -Object $rule -Name 'kind' -DefaultValue 'cleanup')
        if (@('cleanup', 'large-files') -notcontains $kind) {
            throw "Unsupported rule kind for '$id': $kind"
        }

        $action = [string](Get-QdfPropertyValue -Object $rule -Name 'action' -DefaultValue '')
        if ($kind -eq 'cleanup' -and @('delete', 'recycle') -notcontains $action) {
            throw "Unsupported cleanup action for '$id': $action"
        }

        $risk = [string](Get-QdfPropertyValue -Object $rule -Name 'risk' -DefaultValue '')
        if (@('safe', 'careful', 'readonly') -notcontains $risk) {
            throw "Unsupported risk level for '$id': $risk"
        }

        # Optional so an older ruleset keeps loading: a missing category falls
        # back to the UI's catch-all group. Only an over-long value is an error.
        $category = [string](Get-QdfPropertyValue -Object $rule -Name 'category' -DefaultValue '')
        if ($category.Length -gt 40) {
            throw "Rule category is too long for '$id'."
        }
    }
}

function Get-QdfRuleById {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rules,

        [Parameter(Mandatory = $true)]
        [string]$RuleId
    )

    foreach ($rule in $Rules) {
        if ([string]::Equals(
            [string](Get-QdfPropertyValue -Object $rule -Name 'id' -DefaultValue ''),
            $RuleId,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            return $rule
        }
    }

    return $null
}

function Get-QdfRuleCutoffUtc {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Rule
    )

    $days = [int](Get-QdfPropertyValue -Object $Rule -Name 'minAgeDays' -DefaultValue 0)
    if ($days -le 0) {
        return [datetime]::MaxValue
    }

    return [datetime]::UtcNow.AddDays(-1 * $days)
}

function New-QdfFileCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    return [pscustomobject]@{
        Path = $File.FullName
        Name = $File.Name
        Size = [long]$File.Length
        LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
    }
}

function Invoke-QdfScan {
    param(
        [string]$RulesPath = $script:QdfRulesPath,

        [string[]]$RuleIds = @(),

        [int]$MaxDetailsPerCategory = 5000,

        [switch]$SkipLargeFiles
    )

    $startedAt = [datetime]::UtcNow
    $ruleset = Read-QdfJsonFile -Path $RulesPath
    Test-QdfRuleset -Ruleset $ruleset

    $allRules = @(Get-QdfPropertyValue -Object $ruleset -Name 'rules' -DefaultValue @())
    $selectedRules = New-Object System.Collections.Generic.List[object]
    foreach ($rule in $allRules) {
        $id = [string](Get-QdfPropertyValue -Object $rule -Name 'id' -DefaultValue '')
        if ($RuleIds.Count -eq 0 -or $RuleIds -contains $id) {
            $selectedRules.Add($rule)
        }
    }

    $categories = New-Object System.Collections.Generic.List[object]
    $largeFiles = New-Object System.Collections.Generic.List[object]
    $skippedItems = New-Object System.Collections.Generic.List[object]

    foreach ($rule in $selectedRules) {
        $kind = [string](Get-QdfPropertyValue -Object $rule -Name 'kind' -DefaultValue 'cleanup')
        if ($kind -eq 'large-files' -and $SkipLargeFiles) {
            continue
        }

        $cutoffUtc = Get-QdfRuleCutoffUtc -Rule $rule
        $roots = @(Resolve-QdfRuleRoots -Rule $rule -SkippedItems $skippedItems)
        $files = New-Object System.Collections.Generic.List[object]

        foreach ($root in $roots) {
            $matchedFiles = @(Get-QdfFilesFromRoot -Root $root -Rule $rule -CutoffUtc $cutoffUtc -SkippedItems $skippedItems)
            foreach ($file in $matchedFiles) {
                $candidate = New-QdfFileCandidate -File $file

                if ($kind -eq 'large-files') {
                    $threshold = [long](Get-QdfPropertyValue -Object $ruleset -Name 'largeFileThresholdBytes' -DefaultValue 1073741824)
                    if ($candidate.Size -ge $threshold) {
                        $largeFiles.Add($candidate)
                    }
                    continue
                }

                $files.Add($candidate)
            }
        }

        if ($kind -eq 'large-files') {
            continue
        }

        $totalSize = 0L
        foreach ($file in $files) {
            $totalSize += [long]$file.Size
        }

        $details = @()
        if ($MaxDetailsPerCategory -lt 0) {
            $details = @($files | Sort-Object -Property Size -Descending)
        }
        elseif ($MaxDetailsPerCategory -gt 0) {
            $details = @($files | Sort-Object -Property Size -Descending | Select-Object -First $MaxDetailsPerCategory)
        }

        $categories.Add([pscustomobject]@{
            Id = [string](Get-QdfPropertyValue -Object $rule -Name 'id' -DefaultValue '')
            Name = [string](Get-QdfPropertyValue -Object $rule -Name 'name' -DefaultValue '')
            Description = [string](Get-QdfPropertyValue -Object $rule -Name 'description' -DefaultValue '')
            Category = [string](Get-QdfPropertyValue -Object $rule -Name 'category' -DefaultValue '')
            Risk = [string](Get-QdfPropertyValue -Object $rule -Name 'risk' -DefaultValue 'safe')
            Action = [string](Get-QdfPropertyValue -Object $rule -Name 'action' -DefaultValue 'delete')
            DefaultSelected = [bool](Get-QdfPropertyValue -Object $rule -Name 'defaultSelected' -DefaultValue $false)
            ItemCount = $files.Count
            TotalSize = $totalSize
            TotalSizeText = Format-QdfSize -Bytes $totalSize
            DetailsTruncated = ($files.Count -gt $details.Count)
            Files = @($details)
        })
    }

    $categoriesArray = @($categories | Sort-Object -Property @{ Expression = 'TotalSize'; Descending = $true })
    $largeFilesArray = @($largeFiles | Sort-Object -Property Size -Descending)
    $totalCandidateSize = 0L
    foreach ($category in $categoriesArray) {
        if ($category.Action -ne 'readonly') {
            $totalCandidateSize += [long]$category.TotalSize
        }
    }

    $completedAt = [datetime]::UtcNow
    return [pscustomobject]@{
        RulesPath = (Get-QdfNormalizedPath -Path $RulesPath)
        StartedAt = $startedAt.ToString('o')
        CompletedAt = $completedAt.ToString('o')
        DurationSeconds = [math]::Round(($completedAt - $startedAt).TotalSeconds, 2)
        Categories = $categoriesArray
        LargeFiles = $largeFilesArray
        Skipped = $skippedItems.ToArray()
        TotalCandidateSize = $totalCandidateSize
        TotalCandidateSizeText = Format-QdfSize -Bytes $totalCandidateSize
    }
}
