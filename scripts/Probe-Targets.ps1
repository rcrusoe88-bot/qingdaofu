# Probes every candidate target in scripts/targets.json against THIS machine
# and reports which path patterns actually resolve, plus how much each one holds.
#
# Read-only: it never deletes, moves, or writes anything except its own report.
# Purpose: validate path patterns and measure the real payoff before candidates
# are promoted into rules/rules.json - and to collect real paths from other
# machines (the file covers more targets than the shipped ruleset on purpose).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Probe-Targets.ps1
#
# NOTE: this file is deliberately ASCII-only. PowerShell 5.1 reads a BOM-less
# UTF-8 script as ANSI, which corrupts non-ASCII literals and breaks parsing.
# All display text therefore lives in targets.json under "reportLabels".

param(
    [string]$Candidates,
    [string]$Report
)

$ErrorActionPreference = 'Continue'

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Candidates) { $Candidates = Join-Path $projectRoot 'scripts\targets.json' }
if (-not $Report) { $Report = Join-Path $projectRoot 'dist\target-probe.txt' }

$doc = Get-Content -LiteralPath $Candidates -Raw -Encoding UTF8 | ConvertFrom-Json
$L = $doc.reportLabels
$rules = @($doc.rules)

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# Walks a directory tree, honouring the rule's own file patterns, recursion flag
# and age cutoff, so the numbers match what the real scanner would collect.
# Reparse points are skipped for the same reason the app skips them: they can
# loop, or point outside the tree being measured.
function Get-TargetStat {
    param(
        [string]$Root,
        [string[]]$Patterns,
        [bool]$Recurse,
        [int]$MinAgeDays,
        [int]$Cap = 200000
    )

    $cutoff = $null
    if ($MinAgeDays -gt 0) { $cutoff = (Get-Date).AddDays(-$MinAgeDays) }

    $pats = @($Patterns)
    $usePattern = $false
    foreach ($p in $pats) { if ($p -and $p -ne '*') { $usePattern = $true } }

    # A target may be a single file rather than a directory (e.g. MEMORY.DMP).
    if (Test-Path -LiteralPath $Root -PathType Leaf) {
        $fi = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
        if (-not $fi) { return [pscustomobject]@{ Bytes = 0L; Files = 0; Capped = $false } }
        if ($cutoff -and $fi.LastWriteTime -gt $cutoff) {
            return [pscustomobject]@{ Bytes = 0L; Files = 0; Capped = $false }
        }
        return [pscustomobject]@{ Bytes = [long]$fi.Length; Files = 1; Capped = $false }
    }

    $bytes = 0L
    $files = 0
    $capped = $false
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($e in $entries) {
            $attr = 0
            try { $attr = [System.IO.File]::GetAttributes($e) } catch { continue }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }

            if ($attr -band [System.IO.FileAttributes]::Directory) {
                if ($Recurse) { $stack.Push($e) }
                continue
            }

            if ($usePattern) {
                $name = [System.IO.Path]::GetFileName($e)
                $hit = $false
                foreach ($p in $pats) { if ($p -and $name -like $p) { $hit = $true; break } }
                if (-not $hit) { continue }
            }

            $fi = $null
            try { $fi = New-Object System.IO.FileInfo $e } catch { continue }
            if ($cutoff -and $fi.LastWriteTime -gt $cutoff) { continue }

            $bytes += [long]$fi.Length
            $files++
            if ($files -ge $Cap) { $capped = $true; break }
        }
        if ($capped) { break }
    }

    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Capped = $capped }
}

$out = New-Object System.Collections.ArrayList
$null = $out.Add($L.title)
$null = $out.Add(("{0}: {1}" -f $L.generatedAt, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$null = $out.Add(("{0}: {1}   {2}: {3}" -f $L.machine, $env:COMPUTERNAME, $L.user, $env:USERNAME))
$null = $out.Add($L.note)
$null = $out.Add('')

$results = New-Object System.Collections.ArrayList

foreach ($rule in $rules) {
    $totalBytes = 0L
    $totalFiles = 0
    $hits = New-Object System.Collections.ArrayList
    $misses = New-Object System.Collections.ArrayList
    $capped = $false

    # Resolve every template first, then dedupe by full path. The engine does
    # the same thing (Core.ps1: Sort-Object -Property FullName -Unique), so two
    # templates pointing at one location - a case variant, or %GOPATH% next to
    # %USERPROFILE%\go - must not be counted twice here either.
    $resolved = New-Object System.Collections.ArrayList
    foreach ($tpl in @($rule.pathTemplates)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($tpl)
        $items = @()
        try { $items = @(Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue) } catch { }

        if ($items.Count -eq 0) {
            $null = $misses.Add($tpl)
            continue
        }
        foreach ($item in $items) { $null = $resolved.Add($item) }
    }

    foreach ($item in @($resolved | Sort-Object -Property FullName -Unique)) {
        $stat = Get-TargetStat -Root $item.FullName `
                               -Patterns @($rule.filePatterns) `
                               -Recurse ([bool]$rule.recurse) `
                               -MinAgeDays ([int]$rule.minAgeDays)
        if ($stat.Capped) { $capped = $true }
        $totalBytes += $stat.Bytes
        $totalFiles += $stat.Files
        if ($stat.Bytes -gt 0) {
            $null = $hits.Add(("{0}  ({1})" -f $item.FullName, (Format-Size $stat.Bytes)))
        } else {
            $null = $hits.Add(("{0}  ({1})" -f $item.FullName, $L.empty))
        }
    }

    $null = $results.Add([pscustomobject]@{
        Category = $rule.category
        Name     = $rule.name
        Tier     = $rule.tier
        Bytes    = $totalBytes
        Files    = $totalFiles
        Hits     = $hits
        Misses   = $misses
        Capped   = $capped
    })
}

foreach ($tier in @('safe', 'careful', 'deep')) {
    $group = @($results | Where-Object { $_.Tier -eq $tier } | Sort-Object -Property Bytes -Descending)
    if ($group.Count -eq 0) { continue }

    $tierBytes = 0L
    foreach ($g in $group) { $tierBytes += $g.Bytes }

    $null = $out.Add('=' * 78)
    $null = $out.Add(("{0}   --   {1} {2}   {3} {4}" -f $L.tierNames.$tier, $L.hits, (Format-Size $tierBytes), $group.Count, $L.rulesSuffix))
    $null = $out.Add('=' * 78)
    $null = $out.Add('')

    foreach ($g in $group) {
        $flag = ''
        if ($g.Capped) { $flag = "  [$($L.capped)]" }
        $null = $out.Add(("[{0}] {1}   {2}   {3} {4}{5}" -f $g.Category, $g.Name, (Format-Size $g.Bytes), $g.Files, $L.filesSuffix, $flag))
        foreach ($h in $g.Hits) { $null = $out.Add("    + $h") }
        foreach ($m in $g.Misses) { $null = $out.Add("    - $($L.notFound): $m") }
        $null = $out.Add('')
    }
}

$null = $out.Add('=' * 78)
$null = $out.Add($L.summary)
$null = $out.Add('=' * 78)
$grand = 0L
foreach ($tier in @('safe', 'careful', 'deep')) {
    $s = 0L
    $n = 0
    foreach ($r in $results) { if ($r.Tier -eq $tier) { $s += $r.Bytes; $n++ } }
    $grand += $s
    $null = $out.Add(("{0,-34} {1,12}   ({2} {3})" -f $L.tierNames.$tier, (Format-Size $s), $n, $L.rulesSuffix))
}
$null = $out.Add(("{0,-34} {1,12}" -f $L.total, (Format-Size $grand)))

$reportDir = Split-Path -Parent $Report
if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$out | Set-Content -LiteralPath $Report -Encoding UTF8

Write-Output ("$($L.reportWritten): $Report")
Write-Output ''
$out | ForEach-Object { Write-Output $_ }
