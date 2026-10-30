. (Join-Path $PSScriptRoot 'PathSafety.ps1')
$script:QdfUiStrings = $null
$script:QdfProtectedExactPathCache = $null
$script:QdfProtectedPrefixPathCache = $null
$script:QdfProtectedLeafNameSet = $null
$script:QdfSystemAllowedPathCache = $null
$script:QdfWhitelistCache = $null
$script:QdfWhitelistStamp = $null

function Get-QdfPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function Read-QdfJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file not found: $Path"
    }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "JSON file is empty: $Path"
    }

    return ($text | ConvertFrom-Json)
}

function Initialize-QdfDataDirectory {
    $paths = @(
        $script:QdfDataRoot,
        (Join-Path $script:QdfDataRoot 'logs'),
        (Join-Path $script:QdfDataRoot 'receipts')
    )

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Get-QdfUiString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [string]$DefaultValue = ''
    )

    if ($null -eq $script:QdfUiStrings) {
        $script:QdfUiStrings = Read-QdfJsonFile -Path $script:QdfStringsPath
    }

    return Get-QdfPropertyValue -Object $script:QdfUiStrings -Name $Key -DefaultValue $DefaultValue
}

function Format-QdfSize {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N1} KB' -f ($Bytes / 1KB))
    }

    return "$Bytes B"
}

function Get-QdfNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        return ''
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($expanded)
    }
    catch {
        return ''
    }

    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }

    return $fullPath
}

function Test-QdfPathEqualOrChild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $normalizedPath = Get-QdfNormalizedPath -Path $Path
    $normalizedParent = Get-QdfNormalizedPath -Path $ParentPath

    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or [string]::IsNullOrWhiteSpace($normalizedParent)) {
        return $false
    }

    if ([string]::Equals($normalizedPath, $normalizedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $childPrefix = $normalizedParent + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedPath.StartsWith($childPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-QdfNormalizedPathEqualOrChild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NormalizedPath,

        [Parameter(Mandatory = $true)]
        [string]$NormalizedParentPath
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedPath) -or [string]::IsNullOrWhiteSpace($NormalizedParentPath)) {
        return $false
    }

    if ([string]::Equals($NormalizedPath, $NormalizedParentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $childPrefix = $NormalizedParentPath + [System.IO.Path]::DirectorySeparatorChar
    return $NormalizedPath.StartsWith($childPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-QdfReparsePoint {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Item
    )

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-QdfPathChain {
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = Get-QdfNormalizedPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    try {
        while (-not [string]::IsNullOrWhiteSpace($current)) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
        return $true
    }
    catch { return $false }
}

function Get-QdfProtectedExactPaths {
    if ($null -ne $script:QdfProtectedExactPathCache) {
        return $script:QdfProtectedExactPathCache
    }

    $paths = New-Object System.Collections.Generic.List[string]

    $paths.Add((Get-QdfNormalizedPath -Path ([System.IO.Path]::GetPathRoot($env:SystemRoot))))
    $paths.Add((Get-QdfNormalizedPath -Path $env:SystemRoot))
    $paths.Add((Get-QdfNormalizedPath -Path $env:ProgramFiles))
    $paths.Add((Get-QdfNormalizedPath -Path ${env:ProgramFiles(x86)}))
    $paths.Add((Get-QdfNormalizedPath -Path $env:ProgramData))
    $paths.Add((Get-QdfNormalizedPath -Path $env:USERPROFILE))
    $paths.Add((Get-QdfNormalizedPath -Path $env:LOCALAPPDATA))
    $paths.Add((Get-QdfNormalizedPath -Path $env:APPDATA))

    $script:QdfProtectedExactPathCache = @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    return $script:QdfProtectedExactPathCache
}

function Get-QdfProtectedPrefixPaths {
    if ($null -ne $script:QdfProtectedPrefixPathCache) {
        return $script:QdfProtectedPrefixPathCache
    }

    $paths = New-Object System.Collections.Generic.List[string]
    $userProfile = Get-QdfNormalizedPath -Path $env:USERPROFILE
    $appData = Get-QdfNormalizedPath -Path $env:APPDATA
    $localAppData = Get-QdfNormalizedPath -Path $env:LOCALAPPDATA

    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $paths.Add((Get-QdfNormalizedPath -Path ($env:SystemRoot + '\')))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $paths.Add((Get-QdfNormalizedPath -Path ($env:ProgramFiles + '\')))
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $paths.Add((Get-QdfNormalizedPath -Path (${env:ProgramFiles(x86)} + '\')))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        $paths.Add((Get-QdfNormalizedPath -Path ($env:ProgramData + '\')))
    }

    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $paths.Add((Join-Path $userProfile '.ssh'))
        $paths.Add((Join-Path $userProfile '.gnupg'))
        $paths.Add((Join-Path $userProfile '.aws'))
        $paths.Add((Join-Path $userProfile '.azure'))
        $paths.Add((Join-Path $userProfile '.kube'))
        $paths.Add((Join-Path $userProfile '.docker'))
    }

    if (-not [string]::IsNullOrWhiteSpace($appData)) {
        $paths.Add((Join-Path $appData 'Microsoft\Crypto'))
        $paths.Add((Join-Path $appData 'Microsoft\Protect'))
    }

    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $paths.Add((Join-Path $localAppData 'Microsoft\Credentials'))
        $paths.Add((Join-Path $localAppData 'Microsoft\Windows\INetCookies'))
    }

    $script:QdfProtectedPrefixPathCache = @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    return $script:QdfProtectedPrefixPathCache
}

# The prefix protection above blocks every descendant of %SystemRoot%,
# %ProgramData%, Program Files and the credential dirs. A cleanup rule rooted
# there silently resolves to zero files — six shipped rules were dead this way.
# This list re-opens only the exact subpaths a rule needs, each backed by an
# upstream Mole cleanup routine. Add an entry only with that evidence, and
# never widen one to a bare drive/Windows/ProgramData root.
function Get-QdfSystemAllowedPaths {
    if ($null -ne $script:QdfSystemAllowedPathCache) {
        return $script:QdfSystemAllowedPathCache
    }

    $paths = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $normalized = Get-QdfNormalizedPath -Path $Path
        if (-not [string]::IsNullOrWhiteSpace($normalized)) { $null = $paths.Add($normalized) }
    }

    # Only paths that an *enabled* rule actually roots on belong here. The
    # four disabled rules (dev-aws/dev-azure/dev-kube/game-steam) stay blocked
    # on purpose: their disabledReason says the boundary was never opened.
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $null = & $add (Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
        foreach ($relative in @(
                'Microsoft\Windows Defender\Scans\History',
                'Microsoft\Windows Defender\Support'
            )) {
            $null = & $add (Join-Path $env:ProgramData $relative)
        }
    }

    $script:QdfSystemAllowedPathCache = @($paths | Select-Object -Unique)
    return $script:QdfSystemAllowedPathCache
}

function Test-QdfProtectedNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NormalizedPath
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedPath)) {
        return $true
    }

    # Checked before the protected lists: an allow-listed subpath must win over
    # the broader prefix it sits under, or the rule rooted there stays dead.
    foreach ($allowedPath in (Get-QdfSystemAllowedPaths)) {
        if (Test-QdfNormalizedPathEqualOrChild -NormalizedPath $NormalizedPath -NormalizedParentPath $allowedPath) {
            return $false
        }
    }

    foreach ($exactPath in (Get-QdfProtectedExactPaths)) {
        if ([string]::Equals($NormalizedPath, $exactPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    foreach ($prefixPath in (Get-QdfProtectedPrefixPaths)) {
        if (Test-QdfNormalizedPathEqualOrChild -NormalizedPath $NormalizedPath -NormalizedParentPath $prefixPath) {
            return $true
        }
    }

    $leafName = [System.IO.Path]::GetFileName($NormalizedPath)
    return (Get-QdfProtectedLeafNameSet).Contains($leafName)
}

function Get-QdfProtectedLeafNameSet {
    if ($null -eq $script:QdfProtectedLeafNameSet) {
        # HashSet, not an array: this runs once per scanned and once per
        # cleaned file, and `-contains` walked all 13 entries every time.
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @(
                'Cookies', 'Cookies-journal', 'Login Data', 'Login Data-journal',
                'Web Data', 'Web Data-journal', 'History', 'History-journal',
                'Bookmarks', 'NTUSER.DAT', 'SAM', 'SECURITY', 'SYSTEM'
            )) {
            $null = $set.Add($name)
        }
        $script:QdfProtectedLeafNameSet = $set
    }
    return $script:QdfProtectedLeafNameSet
}

# Leaf-name check without path normalization. Used per scanned file: the rule
# root was already checked against the protected paths, and reparse points are
# refused during traversal, so a child cannot land under a protected prefix.
# The removal boundary still runs the full Test-QdfProtectedPath.
function Test-QdfProtectedLeafName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return (Get-QdfProtectedLeafNameSet).Contains($Name)
}

function Test-QdfProtectedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = Get-QdfNormalizedPath -Path $Path
    return (Test-QdfProtectedNormalizedPath -NormalizedPath $normalized)
}

function Get-QdfWhitelistPath {
    if ([string]::IsNullOrWhiteSpace($script:QdfDataRoot)) {
        return ''
    }
    return (Join-Path $script:QdfDataRoot 'whitelist.txt')
}

# One entry per line; blank lines and # comments are ignored. A missing file
# means "nothing protected", but an unreadable one throws: silently dropping a
# whitelist the user wrote would delete what they asked to keep.
function Get-QdfWhitelistEntries {
    $path = Get-QdfWhitelistPath
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:QdfWhitelistCache = @()
        $script:QdfWhitelistStamp = $null
        return $script:QdfWhitelistCache
    }

    # Keyed by path *and* timestamp: tests (and a moved data root) can point at
    # a different file whose mtime happens to match the cached one.
    $stamp = $path + '|' + (Get-Item -LiteralPath $path -Force).LastWriteTimeUtc.Ticks
    if ($null -ne $script:QdfWhitelistCache -and $script:QdfWhitelistStamp -eq $stamp) {
        return $script:QdfWhitelistCache
    }

    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
        # A relative entry would resolve against the process CWD and protect
        # something the user never named.
        if (-not [System.IO.Path]::IsPathRooted($expanded)) { continue }
        $normalized = Get-QdfNormalizedPath -Path $expanded
        if (-not [string]::IsNullOrWhiteSpace($normalized)) { $null = $entries.Add($normalized) }
    }

    $script:QdfWhitelistCache = $entries.ToArray()
    $script:QdfWhitelistStamp = $stamp
    return $script:QdfWhitelistCache
}

function Test-QdfWhitelistedNormalized {
    param([Parameter(Mandatory = $true)][string]$NormalizedPath)

    if ([string]::IsNullOrWhiteSpace($NormalizedPath)) { return $false }
    foreach ($entry in (Get-QdfWhitelistEntries)) {
        if (Test-QdfNormalizedPathEqualOrChild -NormalizedPath $NormalizedPath -NormalizedParentPath $entry) {
            return $true
        }
    }
    return $false
}

function Test-QdfWhitelisted {
    param([Parameter(Mandatory = $true)][string]$Path)

    # @() keeps an empty whitelist from collapsing to $null under StrictMode.
    if (@(Get-QdfWhitelistEntries).Count -eq 0) { return $false }
    $normalized = Get-QdfNormalizedPath -Path $Path
    return (Test-QdfWhitelistedNormalized -NormalizedPath $normalized)
}

function Resolve-QdfRuleRoots {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Rule,

        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$SkippedItems = $null
    )

    $roots = New-Object System.Collections.Generic.List[System.IO.FileSystemInfo]
    $templates = @(Get-QdfPropertyValue -Object $Rule -Name 'pathTemplates' -DefaultValue @())

    foreach ($template in $templates) {
        if ([string]::IsNullOrWhiteSpace([string]$template)) {
            continue
        }

        $expanded = [Environment]::ExpandEnvironmentVariables([string]$template)
        $items = @()

        try {
            $items = @(Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue)
        }
        catch {
            $items = @()
        }

        foreach ($item in $items) {
            if (-not (Test-QdfPathChain -Path $item.FullName)) {
                if ($null -ne $SkippedItems) {
                    $SkippedItems.Add([pscustomobject]@{
                        Path = $item.FullName
                        Reason = 'Reparse points are not scanned.'
                    })
                }
                continue
            }

            if (Test-QdfProtectedPath -Path $item.FullName) {
                if ($null -ne $SkippedItems) {
                    $SkippedItems.Add([pscustomobject]@{
                        Path = $item.FullName
                        Reason = 'Protected path.'
                    })
                }
                continue
            }

            if (Test-QdfWhitelisted -Path $item.FullName) {
                if ($null -ne $SkippedItems) {
                    $SkippedItems.Add([pscustomobject]@{
                        Path = $item.FullName
                        Reason = 'Whitelisted.'
                    })
                }
                continue
            }

            $roots.Add($item)
        }
    }

    return @($roots | Sort-Object -Property FullName -Unique)
}

function Test-QdfNameMatchesPatterns {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object[]]$Patterns = @()
    )

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return $true
    }

    foreach ($pattern in $Patterns) {
        if ($Name -like [string]$pattern) {
            return $true
        }
    }

    return $false
}

function Get-QdfFilesFromRoot {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileSystemInfo]$Root,

        [Parameter(Mandatory = $true)]
        [object]$Rule,

        [Parameter(Mandatory = $true)]
        [datetime]$CutoffUtc,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$SkippedItems,

        [string]$CancelPath = ''
    )

    $recurse = [bool](Get-QdfPropertyValue -Object $Rule -Name 'recurse' -DefaultValue $false)
    $patterns = @(Get-QdfPropertyValue -Object $Rule -Name 'filePatterns' -DefaultValue @('*'))
    # '*' is the common rule shape; skip a per-file function call for it.
    $matchAll = ($patterns.Count -eq 0 -or ($patterns.Count -eq 1 -and [string]$patterns[0] -eq '*'))
    $noCutoff = ($CutoffUtc -eq [datetime]::MaxValue)
    $results = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    # An empty whitelist is the common case: skip per-entry normalization then.
    $whitelistActive = @(Get-QdfWhitelistEntries).Count -gt 0
    $queue = New-Object System.Collections.Generic.Queue[string]
    $rootPath = [string]$Root.FullName
    $visited = 0

    # A rule may point at a single file; the BFS below only queues directories.
    if ($Root -isnot [System.IO.DirectoryInfo]) {
        $info = $null
        try {
            $info = New-Object System.IO.FileInfo($rootPath)
            $attributes = $info.Attributes
        }
        catch {
            $SkippedItems.Add([pscustomobject]@{ Path = $rootPath; Reason = $_.Exception.Message })
            return ,$results
        }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $SkippedItems.Add([pscustomobject]@{ Path = $rootPath; Reason = 'Reparse points are not scanned.' })
            return ,$results
        }
        if ($whitelistActive -and
            (Test-QdfWhitelistedNormalized -NormalizedPath (Get-QdfNormalizedPath -Path $rootPath))) {
            $SkippedItems.Add([pscustomobject]@{ Path = $rootPath; Reason = 'Whitelisted.' })
            return ,$results
        }
        if ($matchAll -or (Test-QdfNameMatchesPatterns -Name $info.Name -Patterns $patterns)) {
            if ($noCutoff -or $info.LastWriteTimeUtc -lt $CutoffUtc) {
                if (Test-QdfProtectedLeafName -Name $info.Name) {
                    $SkippedItems.Add([pscustomobject]@{ Path = $rootPath; Reason = 'Protected path.' })
                }
                else { $results.Add($info) }
            }
        }
        return ,$results
    }

    try {
        $rootAttributes = [System.IO.File]::GetAttributes($rootPath)
    }
    catch {
        $SkippedItems.Add([pscustomobject]@{ Path = $rootPath; Reason = $_.Exception.Message })
        return ,$results
    }
    if (($rootAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $SkippedItems.Add([pscustomobject]@{ Path = $rootPath; Reason = 'Reparse points are not scanned.' })
        return ,$results
    }

    $queue.Enqueue($rootPath)
    while ($queue.Count -gt 0) {
        if ($CancelPath -and (($visited++ -band 255) -eq 0) -and [System.IO.File]::Exists($CancelPath)) {
            throw 'Scan cancelled.'
        }

        $currentPath = $queue.Dequeue()
        try {
            $currentAttributes = [System.IO.File]::GetAttributes($currentPath)
        }
        catch {
            $SkippedItems.Add([pscustomobject]@{ Path = $currentPath; Reason = $_.Exception.Message })
            continue
        }
        if (($currentAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $SkippedItems.Add([pscustomobject]@{ Path = $currentPath; Reason = 'Reparse points are not scanned.' })
            continue
        }

        try {
            # EnumerateFileSystemEntries returns strings; one FileInfo read then
            # fills attributes, length and mtime from its cached first stat.
            # The old path issued three separate metadata calls per file.
            foreach ($entryPath in [System.IO.Directory]::EnumerateFileSystemEntries($currentPath)) {
                if ($CancelPath -and (($visited++ -band 255) -eq 0) -and [System.IO.File]::Exists($CancelPath)) {
                    throw 'Scan cancelled.'
                }

                $info = $null
                try {
                    $info = New-Object System.IO.FileInfo($entryPath)
                    $attributes = $info.Attributes
                }
                catch {
                    $SkippedItems.Add([pscustomobject]@{ Path = $entryPath; Reason = $_.Exception.Message })
                    continue
                }

                if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $SkippedItems.Add([pscustomobject]@{ Path = $entryPath; Reason = 'Reparse points are not scanned.' })
                    continue
                }

                # Checked before the directory branch: a whitelisted directory
                # must not be queued, or its children are scanned.
                if ($whitelistActive -and
                    (Test-QdfWhitelistedNormalized -NormalizedPath (Get-QdfNormalizedPath -Path $entryPath))) {
                    $SkippedItems.Add([pscustomobject]@{ Path = $entryPath; Reason = 'Whitelisted.' })
                    continue
                }

                if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    if ($recurse) { $queue.Enqueue($entryPath) }
                    continue
                }

                if (-not $matchAll -and -not (Test-QdfNameMatchesPatterns -Name $info.Name -Patterns $patterns)) { continue }
                if (-not $noCutoff -and $info.LastWriteTimeUtc -ge $CutoffUtc) { continue }
                if (Test-QdfProtectedLeafName -Name $info.Name) {
                    $SkippedItems.Add([pscustomobject]@{ Path = $entryPath; Reason = 'Protected path.' })
                    continue
                }

                $results.Add($info)
            }
        }
        catch {
            if ($_.Exception.Message -eq 'Scan cancelled.') { throw }
            $SkippedItems.Add([pscustomobject]@{ Path = $currentPath; Reason = $_.Exception.Message })
        }
    }

    # Return the list as one object. Letting PowerShell enumerate 100k items
    # into the pipeline just to re-collect them at the call site was overhead.
    return ,$results
}

function Test-QdfCandidatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Rule,

        [object[]]$ResolvedRoots = @(),

        [string[]]$NormalizedRoots = @(),

        [switch]$PathIsNormalized
    )

    if ($PathIsNormalized) {
        $normalizedPath = $Path
    }
    else {
        $normalizedPath = Get-QdfNormalizedPath -Path $Path
    }
    if (-not (Test-QdfPathChain -Path $normalizedPath) -or (Test-QdfProtectedNormalizedPath -NormalizedPath $normalizedPath)) {
        return $false
    }
    # Re-checked at the removal boundary: the whitelist may have changed
    # between scanning and deletion.
    if (Test-QdfWhitelistedNormalized -NormalizedPath $normalizedPath) {
        return $false
    }

    $rootsToCheck = $NormalizedRoots
    if ($rootsToCheck.Count -eq 0) {
        $resolvedRoots = $ResolvedRoots
        if ($resolvedRoots.Count -eq 0) {
            $resolvedRoots = @(Resolve-QdfRuleRoots -Rule $Rule)
        }

        $rootsToCheck = @(
            foreach ($root in $resolvedRoots) {
                Get-QdfNormalizedPath -Path $root.FullName
            }
        )
    }

    foreach ($rootPath in $rootsToCheck) {
        if (Test-QdfNormalizedPathEqualOrChild -NormalizedPath $normalizedPath -NormalizedParentPath $rootPath) {
            return $true
        }
    }

    return $false
}

function New-QdfReceipt {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result,

        [Parameter(Mandatory = $true)]
        [string]$ReceiptDirectory
    )

    if (-not (Test-Path -LiteralPath $ReceiptDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $ReceiptDirectory -Force | Out-Null
    }

    $stamp = [guid]::NewGuid().ToString('N')
    $receiptPath = Join-Path $ReceiptDirectory ("receipt-$stamp-$PID.json")
    $json = $Result | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($receiptPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $receiptPath
}

function Write-QdfOperationLog {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Summary
    )

    Initialize-QdfDataDirectory
    $logPath = Join-Path (Join-Path $script:QdfDataRoot 'logs') 'operations.jsonl'
    $line = $Summary | ConvertTo-Json -Compress -Depth 6
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, $encoding)
}

function Show-QdfError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        (Get-QdfUiString -Key 'appTitle' -DefaultValue 'QingDaoFu'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
