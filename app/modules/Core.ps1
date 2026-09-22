. (Join-Path $PSScriptRoot 'PathSafety.ps1')
$script:QdfUiStrings = $null
$script:QdfProtectedExactPathCache = $null
$script:QdfProtectedPrefixPathCache = $null
$script:QdfProtectedLeafNameCache = $null

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

function Test-QdfProtectedNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NormalizedPath
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedPath)) {
        return $true
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
    if ($null -eq $script:QdfProtectedLeafNameCache) {
        $script:QdfProtectedLeafNameCache = @(
            'Cookies', 'Cookies-journal', 'Login Data', 'Login Data-journal',
            'Web Data', 'Web Data-journal', 'History', 'History-journal',
            'Bookmarks', 'NTUSER.DAT', 'SAM', 'SECURITY', 'SYSTEM'
        )
    }

    return ($script:QdfProtectedLeafNameCache -contains $leafName)
}

function Test-QdfProtectedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = Get-QdfNormalizedPath -Path $Path
    return (Test-QdfProtectedNormalizedPath -NormalizedPath $normalized)
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
        [System.Collections.Generic.List[object]]$SkippedItems
    )

    $recurse = [bool](Get-QdfPropertyValue -Object $Rule -Name 'recurse' -DefaultValue $false)
    $patterns = @(Get-QdfPropertyValue -Object $Rule -Name 'filePatterns' -DefaultValue @('*'))
    $results = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[System.IO.FileSystemInfo]
    $queue.Enqueue($Root)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not (Test-QdfPathChain -Path $current.FullName)) { continue }

        if ($current.PSIsContainer) {
            $children = @()
            try {
                $children = @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop)
            }
            catch {
                $SkippedItems.Add([pscustomobject]@{
                    Path = $current.FullName
                    Reason = $_.Exception.Message
                })
                continue
            }

            foreach ($child in $children) {
                if (Test-QdfReparsePoint -Item $child) {
                    $SkippedItems.Add([pscustomobject]@{
                        Path = $child.FullName
                        Reason = 'Reparse points are not scanned.'
                    })
                    continue
                }

                if ($child.PSIsContainer) {
                    if ($recurse) {
                        $queue.Enqueue($child)
                    }
                    continue
                }

                if (-not (Test-QdfNameMatchesPatterns -Name $child.Name -Patterns $patterns)) {
                    continue
                }

                if ($child.LastWriteTimeUtc -ge $CutoffUtc) {
                    continue
                }

                if (Test-QdfProtectedPath -Path $child.FullName) {
                    $SkippedItems.Add([pscustomobject]@{
                        Path = $child.FullName
                        Reason = 'Protected file.'
                    })
                    continue
                }

                $results.Add($child)
            }

            continue
        }

        if (-not (Test-QdfNameMatchesPatterns -Name $current.Name -Patterns $patterns)) {
            continue
        }

        if ($current.LastWriteTimeUtc -ge $CutoffUtc) {
            continue
        }

        if (-not (Test-QdfProtectedPath -Path $current.FullName)) {
            $results.Add($current)
        }
    }

    return $results.ToArray()
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
