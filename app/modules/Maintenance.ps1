# Maintenance operations that are not path rules: orphaned app-data detection
# and Recycle Bin emptying. Both are user-initiated commands, never part of a
# normal clean run.

# Top-level AppData folders that belong to Windows or to the shell itself.
# Anything here is skipped before the installed-app comparison runs.
$script:QdfOrphanSkipNames = @(
    'Microsoft', 'Windows', 'Packages', 'Programs', 'Temp', 'Roaming',
    'ConnectedDevicesPlatform', 'D3DSCache', 'PlaceholderTileLogoFolder',
    'Publish', 'VirtualStore', 'ElevatedDiagnostics', 'Comms', 'CrashDumps',
    'PackagedApps', 'Application Data', 'Local Settings', 'QingDaoFu',
    # Toolchain stores that are not applications and are already covered by
    # cleanup rules (or must never be deleted, per CONTRIBUTING.md).
    'pnpm', 'pnpm-cache', 'npm-cache', 'yarn', 'Yarn', 'go-build',
    'ms-playwright', 'wsl', 'uv', 'mise', 'NuGet', 'pip', 'node-gyp',
    'electron', 'TypeScript', 'fontconfig',
    # Deleting this breaks install/repair of MSI packages (CONTRIBUTING.md §7).
    'Package Cache'
)

# Every vendor/app name that a rules.json pathTemplate already reaches under
# %APPDATA% / %LOCALAPPDATA%. A folder owned by a shipped rule is not orphaned
# app data, so the scan reuses the rule table instead of a hand-kept list.
function Get-QdfRuleAppNames {
    $names = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($script:QdfRulesPath) -or
        -not (Test-Path -LiteralPath $script:QdfRulesPath -PathType Leaf)) {
        return $names
    }

    try {
        $ruleset = Read-QdfJsonFile -Path $script:QdfRulesPath
    }
    catch { return $names }

    $prefixes = @(
        ($env:LOCALAPPDATA + '\'),
        ($env:APPDATA + '\')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($rule in @(Get-QdfPropertyValue -Object $ruleset -Name 'rules' -DefaultValue @())) {
        foreach ($template in @(Get-QdfPropertyValue -Object $rule -Name 'pathTemplates' -DefaultValue @())) {
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$template)
            foreach ($prefix in $prefixes) {
                if (-not $expanded.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $first = $expanded.Substring($prefix.Length).Split('\')[0]
                if (-not [string]::IsNullOrWhiteSpace($first) -and $first -ne '*') { $null = $names.Add($first) }
                break
            }
        }
    }

    return $names
}

function Get-QdfInstalledAppNames {
    $names = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($path in $registryPaths) {
        try {
            foreach ($item in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
                $displayName = [string](Get-QdfPropertyValue -Object $item -Name 'DisplayName' -DefaultValue '')
                if (-not [string]::IsNullOrWhiteSpace($displayName)) { $null = $names.Add($displayName.Trim()) }
            }
        }
        catch { }
    }

    try {
        foreach ($app in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
            $name = [string](Get-QdfPropertyValue -Object $app -Name 'Name' -DefaultValue '')
            if (-not [string]::IsNullOrWhiteSpace($name)) { $null = $names.Add($name.Trim()) }
        }
    }
    catch { }

    return $names
}

# Deliberately conservative: a folder only counts as "installed" when its name
# is equal to, contains, or is contained in an installed app name, and the
# shorter side is at least 4 characters. Anything ambiguous stays an orphan
# candidate — the scan only reports, it never deletes.
function Test-QdfOrphanNameInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$FolderName,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$InstalledNames
    )

    if ([string]::IsNullOrWhiteSpace($FolderName)) { return $true }
    $folder = $FolderName.Trim()

    foreach ($name in $InstalledNames) {
        if ([string]::Equals($folder, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

        $shorter = if ($folder.Length -le $name.Length) { $folder } else { $name }
        if ($shorter.Length -lt 4) { continue }

        if ($folder.IndexOf($name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $name.IndexOf($folder, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

# Bounded recursive size. A tree that could not be fully read reports
# Complete = $false, and the caller keeps it as a candidate with that caveat.
function Get-QdfDirectorySize {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutSeconds = 3
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $total = 0L
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($Path)

    try {
        while ($pending.Count -gt 0) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                return [pscustomobject]@{ Bytes = $total; Complete = $false }
            }
            $directory = $pending.Pop()
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                    return [pscustomobject]@{ Bytes = $total; Complete = $false }
                }
                try {
                    $attributes = [System.IO.File]::GetAttributes($entry)
                }
                catch {
                    return [pscustomobject]@{ Bytes = $total; Complete = $false }
                }
                if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $pending.Push($entry)
                    }
                    continue
                }
                $total += (New-Object System.IO.FileInfo($entry)).Length
            }
        }
    }
    catch {
        return [pscustomobject]@{ Bytes = $total; Complete = $false }
    }

    return [pscustomobject]@{ Bytes = $total; Complete = $true }
}

# Read-only. Reports AppData folders that no installed program appears to own.
# It never deletes: a name match is a heuristic, and a folder can hold user
# data (settings, profiles) that cannot be rebuilt.
function Invoke-QdfOrphanScan {
    param(
        [int]$MinAgeDays = 60,
        [long]$MinSizeBytes = 10485760,
        [object[]]$Roots = @(),
        [string[]]$SkipNames = @()
    )

    if ($Roots.Count -eq 0) {
        $Roots = @(
            [pscustomobject]@{ Path = $env:APPDATA; Label = 'Roaming' },
            [pscustomobject]@{ Path = $env:LOCALAPPDATA; Label = 'Local' }
        )
    }

    $skip = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $script:QdfOrphanSkipNames) { $null = $skip.Add($name) }
    foreach ($name in (Get-QdfRuleAppNames)) { $null = $skip.Add($name) }
    foreach ($name in $SkipNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) { $null = $skip.Add($name.Trim()) }
    }

    $installed = Get-QdfInstalledAppNames
    $cutoffUtc = [datetime]::UtcNow.AddDays(-1 * [math]::Max(0, $MinAgeDays))
    $whitelistActive = @(Get-QdfWhitelistEntries).Count -gt 0
    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($root in $Roots) {
        $rootPath = [string]$root.Path
        $rootLabel = [string]$root.Label
        if ([string]::IsNullOrWhiteSpace($rootPath) -or -not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
        if (-not (Test-QdfPathChain -Path $rootPath)) { continue }

        try {
            $folders = @([System.IO.Directory]::EnumerateDirectories($rootPath))
        }
        catch { continue }

        foreach ($folderPath in $folders) {
            $name = [System.IO.Path]::GetFileName($folderPath)
            if ($skip.Contains($name)) { continue }
            # electron-updater leftovers have their own rule (app-updater-installer-cache).
            if ($name -like '*-updater') { continue }

            try {
                $info = Get-Item -LiteralPath $folderPath -Force -ErrorAction Stop
            }
            catch { continue }
            if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($info.LastWriteTimeUtc -ge $cutoffUtc) { continue }
            if ($whitelistActive -and (Test-QdfWhitelisted -Path $folderPath)) { continue }
            if (Test-QdfOrphanNameInstalled -FolderName $name -InstalledNames $installed) { continue }

            $size = Get-QdfDirectorySize -Path $folderPath
            if ($size.Bytes -lt $MinSizeBytes) { continue }

            $candidates.Add([pscustomobject]@{
                Path = $folderPath
                Name = $name
                Root = $rootLabel
                Size = [long]$size.Bytes
                SizeText = (Format-QdfSize -Bytes $size.Bytes)
                SizeComplete = [bool]$size.Complete
                LastModified = $info.LastWriteTimeUtc.ToString('o')
            })
        }
    }

    $sorted = @($candidates | Sort-Object -Property Size -Descending)
    $totalBytes = 0L
    foreach ($candidate in $sorted) { $totalBytes += [long]$candidate.Size }

    return [pscustomobject]@{
        ScannedAt = [datetime]::UtcNow.ToString('o')
        MinAgeDays = $MinAgeDays
        MinSizeBytes = $MinSizeBytes
        Candidates = $sorted
        CandidateCount = $sorted.Count
        TotalSize = $totalBytes
        TotalSizeText = (Format-QdfSize -Bytes $totalBytes)
    }
}

function Get-QdfRecycleBinInfo {
    $count = 0
    $total = 0L
    $shell = $null
    $namespace = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $namespace = $shell.Namespace(0xA)
        if ($null -eq $namespace) {
            return [pscustomobject]@{ Count = 0; Bytes = 0L; Readable = $false }
        }
        foreach ($item in @($namespace.Items())) {
            $count++
            try { $total += [long]$item.Size } catch { }
        }
        return [pscustomobject]@{ Count = $count; Bytes = $total; Readable = $true }
    }
    catch {
        return [pscustomobject]@{ Count = 0; Bytes = 0L; Readable = $false }
    }
    finally {
        if ($null -ne $namespace) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($namespace) } catch { } }
        if ($null -ne $shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }
    }
}

# Irreversible. Only reachable through the explicit recycle-bin command, never
# through a rules.json selection.
function Clear-QdfRecycleBin {
    param([switch]$DryRun)

    $info = Get-QdfRecycleBinInfo
    $result = [pscustomobject]@{
        ItemCount = [int]$info.Count
        TotalSize = [long]$info.Bytes
        TotalSizeText = (Format-QdfSize -Bytes $info.Bytes)
        Readable = [bool]$info.Readable
        DryRun = [bool]$DryRun
        Emptied = $false
        Error = ''
    }

    if ($DryRun -or $info.Count -eq 0) { return $result }

    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        $result.Emptied = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}
