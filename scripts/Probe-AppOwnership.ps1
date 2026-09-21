# Probes which application-data directories can be attributed to which
# application on THIS machine, and how strong that attribution is.
#
# Read-only. It reads the registry, Start Menu / Desktop shortcuts, Authenticode
# signatures and directory sizes. It does not create, move, or delete anything
# except its own report.
#
# Design note (learned the hard way, 2026-09-21): an earlier version used
# "a signed file inside the data directory" as the strongest evidence. That is
# WRONG. Electron / WebView2 apps ship runtime components signed by Google and
# Microsoft inside their own data directories, so that rule attributed
# ima.copilot to Google LLC and Xiaomi's PC manager to Microsoft Corporation.
# Signatures found *inside* a data dir identify a component vendor, not the app.
#
# What IS reliable is the other direction: shortcut -> real exe -> signature,
# which yields the true publisher. Linking that publisher to a data directory is
# done here by matching the INSTALL PATH's directory names (Huorong,
# BaiduNetdisk, ima.copilot) against data directory names - a much better signal
# than the publisher's display name, which for Chinese vendors is useless.
# Candidates are still only candidates: this script never asserts a final
# verdict, because the machine cannot tell that the "Huorong" folder is Huorong's.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Probe-AppOwnership.ps1
#
# NOTE: ASCII-only on purpose. PowerShell 5.1 reads a BOM-less UTF-8 script as
# ANSI, which corrupts non-ASCII literals and breaks parsing. Display text lives
# in scripts/app-ownership-labels.json.

param(
    [string]$Labels,
    [string]$Report,
    [int]$MaxFilesPerDir = 20000,
    [int]$MaxRegistryKeys = 3000
)

$ErrorActionPreference = 'Continue'

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Labels) { $Labels = Join-Path $projectRoot 'scripts\app-ownership-labels.json' }
if (-not $Report) { $Report = Join-Path $projectRoot 'dist\app-ownership.txt' }

$L = Get-Content -LiteralPath $Labels -Raw -Encoding UTF8 | ConvertFrom-Json

# Subdirectory names that are unambiguously a regenerable cache. A directory
# only counts as "cache-shaped" if it actually contains one of these; being
# owned by an app is NOT by itself a reason to delete anything.
$cacheNames = @(
    'Cache', 'Cache_Data', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache',
    'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Service Worker',
    'CacheStorage', 'CachedData', 'CachedExtensions', 'CachedExtensionVSIXs',
    'blob_storage', 'Crashpad', 'crashpad', 'CrashDumps', 'Logs', 'logs'
)

# Words that appear in install paths and company names but identify nothing.
# Without this, "Microsoft(R) Windows(R) Operating System" matches half the
# directories on the machine.
$stopTokens = @(
    'microsoft', 'windows', 'operating', 'system', 'systems', 'installer', 'uninstaller', 'uninstall',
    'application', 'applications', 'program', 'programs', 'files', 'common', 'update', 'updater',
    'launcher', 'desktop', 'version', 'local', 'roaming', 'appdata', 'data', 'software', 'technology',
    'technologies', 'corporation', 'limited', 'inc', 'llc', 'corp', 'company', 'group', 'network',
    'shenzhen', 'beijing', 'shanghai', 'zhuhai', 'nanjing', 'hangzhou', 'guangzhou', 'chengdu',
    'x86', 'x64', 'amd64', 'bin', 'lib', 'libs', 'app', 'apps', 'core', 'service', 'services',
    'cloud', 'share', 'node', 'nodejs', 'unicode', 'default', 'user', 'users', 'public', 'temp',
    'tmp', 'cache', 'caches', 'logs', 'resources', 'assets', 'static', 'dist', 'build', 'output',
    'releases', 'src'
)

# Vendors whose code ships *inside other apps' data directories* as a bundled
# runtime (Chromium, WebView2). A signature by one of these found inside a data
# directory says nothing about who owns that directory, so it is not offered as
# a candidate. This is exactly why ima.copilot must not become "Google LLC".
$componentVendors = @(
    'google llc', 'microsoft corporation', 'microsoft windows', 'apple inc.', 'mozilla',
    'adobe inc.', 'adobe systems', 'oracle america', 'intel corporation', 'nvidia corporation'
)

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-FileOwner {
    param([string]$Path)
    $publisher = ''
    $status = 'None'
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($null -ne $sig) {
            $status = [string]$sig.Status
            if ($null -ne $sig.SignerCertificate) {
                $publisher = [string]$sig.SignerCertificate.GetNameInfo(
                    [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            }
        }
    }
    catch { }

    $product = ''
    $company = ''
    try {
        $vi = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).VersionInfo
        if ($null -ne $vi) {
            $product = [string]$vi.ProductName
            $company = [string]$vi.CompanyName
        }
    }
    catch { }

    return [pscustomobject]@{ Publisher = $publisher; Product = $product; Company = $company; Status = $status }
}

function Get-ShortcutTargets {
    $roots = @(
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:PUBLIC 'Desktop'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch')
    )
    $shell = New-Object -ComObject WScript.Shell
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $links = @()
        try { $links = @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -Force -ErrorAction SilentlyContinue) } catch { }
        foreach ($link in $links) {
            $target = ''
            try { $target = [string]$shell.CreateShortcut($link.FullName).TargetPath } catch { }
            # Advertised (MSI) shortcuts store no target path; the registry covers those.
            if ([string]::IsNullOrWhiteSpace($target)) { continue }
            if ($target -notmatch '\.exe$') { continue }
            if ($seen.ContainsKey($target.ToLower())) { continue }
            $seen[$target.ToLower()] = $true
            $null = $out.Add([pscustomobject]@{ Link = $link.FullName; Exe = $target; Name = $link.BaseName })
        }
    }
    return $out
}

function Get-RegistryApps {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($key in $keys) {
        $items = @()
        try { $items = @(Get-ItemProperty -Path $key -ErrorAction SilentlyContinue) } catch { }
        foreach ($i in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$i.DisplayName)) { continue }
            if ($i.SystemComponent -eq 1) { continue }
            $null = $out.Add([pscustomobject]@{
                Name = [string]$i.DisplayName; Publisher = [string]$i.Publisher
                Version = [string]$i.DisplayVersion; InstallLocation = [string]$i.InstallLocation
                Source = 'registry'
            })
        }
    }
    return $out
}

function Get-AppxApps {
    $out = New-Object System.Collections.ArrayList
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue) } catch { }
    foreach ($p in $pkgs) {
        $pub = [string]$p.Publisher
        $m = [regex]::Match($pub, 'CN=([^,]+)')
        if ($m.Success) { $pub = $m.Groups[1].Value }
        $null = $out.Add([pscustomobject]@{
            Name = [string]$p.Name; Publisher = $pub; Version = [string]$p.Version
            InstallLocation = [string]$p.InstallLocation; Source = 'appx'
        })
    }
    return $out
}

function Measure-Dir {
    param([string]$Path, [int]$Cap)
    $bytes = 0L; $files = 0; $capped = $false
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($e in $entries) {
            $attr = 0
            try { $attr = [System.IO.File]::GetAttributes($e) } catch { continue }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($attr -band [System.IO.FileAttributes]::Directory) { $stack.Push($e); continue }
            try { $bytes += (New-Object System.IO.FileInfo $e).Length } catch { }
            $files++
            if ($files -ge $Cap) { $capped = $true; break }
        }
        if ($capped) { break }
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Capped = $capped }
}

function Get-CacheLikeChildren {
    param([string]$Path, [int]$MaxDepth = 3)
    $hits = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Path, 0))
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $dir = $item[0]; $depth = $item[1]
        if ($depth -ge $MaxDepth) { continue }
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($e in $entries) {
            $attr = 0
            try { $attr = [System.IO.File]::GetAttributes($e) } catch { continue }
            if (-not ($attr -band [System.IO.FileAttributes]::Directory)) { continue }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $name = [System.IO.Path]::GetFileName($e)
            if ($cacheNames -contains $name) { $null = $hits.Add($name) }
            else { $queue.Enqueue(@($e, $depth + 1)) }
        }
    }
    return $hits
}

# Shallow search for a validly signed binary. Last-resort attribution only:
# signatures found inside a data dir often belong to a bundled runtime, so this
# is used only when nothing else matched.
function Get-FirstSignedFile {
    param([string]$Path, [int]$MaxDepth = 3, [int]$MaxChecks = 40)
    $checked = 0
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Path, 0))
    while ($queue.Count -gt 0 -and $checked -lt $MaxChecks) {
        $item = $queue.Dequeue()
        $dir = $item[0]; $depth = $item[1]
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($e in $entries) {
            if ($checked -ge $MaxChecks) { break }
            $attr = 0
            try { $attr = [System.IO.File]::GetAttributes($e) } catch { continue }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($attr -band [System.IO.FileAttributes]::Directory) {
                if ($depth -lt $MaxDepth) { $queue.Enqueue(@($e, $depth + 1)) }
                continue
            }
            if ($e -notmatch '\.(exe|dll)$') { continue }
            $checked++
            $owner = Get-FileOwner -Path $e
            if ($owner.Status -eq 'Valid' -and $owner.Publisher) { return $owner }
        }
    }
    return $null
}

# Walks HKCU\Software two levels deep looking for values that point into AppData.
# Some installers record their data directory there, which is direct evidence -
# no guessing needed. Bounded because PowerShell registry access is slow.
function Get-RegistryPathHints {
    param([int]$MaxKeys)
    $patterns = @('AppData\Roaming', 'AppData\Local', '%APPDATA%', '%LOCALAPPDATA%')
    $out = New-Object System.Collections.ArrayList
    $count = 0
    $capped = $false

    $level1 = @()
    try { $level1 = @(Get-ChildItem -Path 'HKCU:\Software' -ErrorAction SilentlyContinue) } catch { }

    foreach ($k1 in $level1) {
        $candidates = New-Object System.Collections.ArrayList
        $null = $candidates.Add($k1)
        try {
            foreach ($k2 in @(Get-ChildItem -Path $k1.PSPath -ErrorAction SilentlyContinue)) { $null = $candidates.Add($k2) }
        } catch { }

        foreach ($key in $candidates) {
            $count++
            if ($count -gt $MaxKeys) { $capped = $true; break }

            $props = $null
            try { $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue } catch { continue }
            if ($null -eq $props) { continue }

            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                $v = [string]$p.Value
                if ($v.Length -lt 8) { continue }
                $hit = $false
                foreach ($pat in $patterns) {
                    if ($v -like ('*' + $pat + '*')) { $hit = $true; break }
                }
                if (-not $hit) { continue }
                $pretty = ($key.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '') -replace '^HKEY_CURRENT_USER', 'HKCU'
                $null = $out.Add([pscustomobject]@{ Key = $pretty; Value = $p.Name; Path = $v })
            }
        }
        if ($capped) { break }
    }
    return [pscustomobject]@{ Items = $out; Capped = $capped }
}

# ---------------------------------------------------------------- collect

Write-Output 'collecting inventory...'
$shortcuts = Get-ShortcutTargets
$regApps = Get-RegistryApps
$appxApps = Get-AppxApps
Write-Output ("  shortcuts: {0}   registry: {1}   appx: {2}" -f $shortcuts.Count, $regApps.Count, $appxApps.Count)

Write-Output 'reading signatures from shortcut targets...'
$sigRows = New-Object System.Collections.ArrayList
foreach ($s in $shortcuts) {
    if (-not (Test-Path -LiteralPath $s.Exe)) { continue }
    $owner = Get-FileOwner -Path $s.Exe
    $null = $sigRows.Add([pscustomobject]@{
        Exe = $s.Exe; Link = $s.Name; Publisher = $owner.Publisher
        Product = $owner.Product; Company = $owner.Company; Status = $owner.Status
    })
}

# Candidate index: token -> @{ Label; Source }. Tokens come from the install
# path of a *signature-verified* executable, plus its product and company names.
# The install path is the strong one: vendors name their install folder and
# their data folder the same way (D:\Huorong\... vs AppData\Local\Huorong).
Write-Output 'building candidate index...'
$index = @{}
function Add-IndexTokens {
    param([string]$Text, [string]$Label, [string]$Source)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    foreach ($raw in ($Text -split '[^\p{L}\p{N}.]+')) {
        $t = $raw.Trim().ToLower() -replace '\.(exe|dll)$', ''
        if ($t.Length -lt 2) { continue }
        if ($stopTokens -contains $t) { continue }
        if (-not $index.ContainsKey($t)) { $index[$t] = [pscustomobject]@{ Label = $Label; Source = $Source } }
    }
}

foreach ($s in $sigRows) {
    $verified = ($s.Status -eq 'Valid' -and -not [string]::IsNullOrWhiteSpace($s.Publisher))
    $label = $s.Product
    if ([string]::IsNullOrWhiteSpace($label)) { $label = $s.Link }
    if ([string]::IsNullOrWhiteSpace($label)) { $label = $s.Publisher }
    if ([string]::IsNullOrWhiteSpace($label)) { continue }

    # The install path is real whether or not the exe is signed - only the
    # publisher is unverified for unsigned ones, so the source label says so.
    # Plenty of Chinese apps ship unsigned exes; skipping them left
    # Cherry Studio matching nothing and falling through to a false positive.
    $pathSource = if ($verified) { 'installPath' } else { 'installPathUnsigned' }
    Add-IndexTokens -Text (Split-Path -Parent $s.Exe) -Label $label -Source $pathSource
    Add-IndexTokens -Text $s.Link -Label $label -Source 'shortcut'
    if ($verified) {
        Add-IndexTokens -Text $s.Product -Label $label -Source 'product'
        Add-IndexTokens -Text $s.Company -Label $label -Source 'company'
    }
}
# The registry's own install locations are not signature-verified, so they only
# fill gaps the verified sources did not already claim.
foreach ($a in $regApps) {
    if ([string]::IsNullOrWhiteSpace($a.InstallLocation)) { continue }
    Add-IndexTokens -Text $a.InstallLocation -Label $a.Name -Source 'registry'
}
Write-Output ("  index tokens: {0}" -f $index.Count)

Write-Output 'scanning registry for AppData path hints...'
$hints = Get-RegistryPathHints -MaxKeys $MaxRegistryKeys
Write-Output ("  hints: {0}   capped: {1}" -f $hints.Items.Count, $hints.Capped)

Write-Output 'measuring data directories...'
$dirRows = New-Object System.Collections.ArrayList
$bases = @(
    @{ Path = $env:APPDATA;      Tag = 'Roaming' },
    @{ Path = $env:LOCALAPPDATA; Tag = 'Local' }
)

foreach ($base in $bases) {
    if (-not (Test-Path -LiteralPath $base.Path)) { continue }
    $dirs = @()
    try { $dirs = @(Get-ChildItem -LiteralPath $base.Path -Directory -Force -ErrorAction SilentlyContinue) } catch { }

    foreach ($d in $dirs) {
        if ($d.Name -eq 'Packages') { continue }   # AppX layout is exact, handled separately
        $size = Measure-Dir -Path $d.FullName -Cap $MaxFilesPerDir
        if ($size.Bytes -lt 1MB) { continue }

        $key = $d.Name.ToLower()

        # Match quality: exact beats prefix beats substring. The ranking matters
        # - "cherrystudio" must prefer "cherry" (a prefix) over the "studio"
        # that also appears in "Visual Studio Code".
        $matches = New-Object System.Collections.ArrayList
        foreach ($t in $index.Keys) {
            # Prefix/substring matches need 5+ characters: at 4, generic English
            # words like "open" made AppData\Local\OpenAI match "Open Design".
            $q = 0
            if ($t -eq $key) { $q = 3 }
            elseif ($t.Length -ge 5 -and $key.StartsWith($t)) { $q = 2 }
            elseif ($t.Length -ge 5 -and $key.Contains($t)) { $q = 1 }
            # Deliberately no reverse "token contains the directory name" test:
            # winget package folders embed "microsoft" in a longer token, which
            # made every Microsoft-ish directory match FFmpeg.
            if ($q -eq 0) { continue }
            $e = $index[$t]
            $verified = ($e.Source -ne 'installPathUnsigned' -and $e.Source -ne 'registry')
            $null = $matches.Add([pscustomobject]@{
                Label = $e.Label; Source = $e.Source; Q = $q; Len = $t.Length; Verified = $verified
            })
        }

        $cands = New-Object System.Collections.ArrayList
        if ($matches.Count -gt 0) {
            $best = 0
            foreach ($m in $matches) { if ($m.Q -gt $best) { $best = $m.Q } }
            $seenLabels = @{}
            $ordered = $matches | Where-Object { $_.Q -eq $best } |
                Sort-Object -Property @{ Expression = 'Verified'; Descending = $true },
                                      @{ Expression = 'Len'; Descending = $true }
            foreach ($m in $ordered) {
                $sig = $m.Label + '|' + $m.Source
                if ($seenLabels.ContainsKey($sig)) { continue }
                $seenLabels[$sig] = $true
                $null = $cands.Add($m)
                if ($cands.Count -ge 3) { break }
            }
        }
        else {
            # Last resort: a signed binary inside the directory. Unreliable in
            # general (see $componentVendors), but it is the only signal for
            # apps that ship no shortcut at all - Claude Desktop is one, and it
            # holds 9.4 GB on this machine.
            $owner = Get-FirstSignedFile -Path $d.FullName
            if ($null -ne $owner) {
                $pn = $owner.Publisher.ToLower()
                $isComponent = $false
                foreach ($cv in $componentVendors) {
                    if ($pn -eq $cv -or $pn.StartsWith($cv)) { $isComponent = $true; break }
                }
                if (-not $isComponent) {
                    $label = $owner.Product
                    if ([string]::IsNullOrWhiteSpace($label)) { $label = $owner.Publisher }
                    $null = $cands.Add([pscustomobject]@{ Label = $label; Source = 'sigInDir'; Q = 0; Len = 0 })
                }
            }
        }

        $cacheLike = @(Get-CacheLikeChildren -Path $d.FullName)
        $null = $dirRows.Add([pscustomobject]@{
            Dir = ($base.Tag + '\' + $d.Name)
            Bytes = $size.Bytes
            Candidates = $cands
            CacheLike = ($cacheLike | Select-Object -Unique) -join ', '
        })
    }
}

# ---------------------------------------------------------------- report

$out = New-Object System.Collections.ArrayList
$null = $out.Add($L.title)
$null = $out.Add(("{0}: {1}" -f $L.generatedAt, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$null = $out.Add(("{0}: {1}   {2}: {3}" -f $L.machine, $env:COMPUTERNAME, $L.user, $env:USERNAME))
$null = $out.Add($L.note)
$null = $out.Add('')

$signedRows = @($sigRows | Where-Object { $_.Status -eq 'Valid' -and $_.Publisher })
$withCand = @($dirRows | Where-Object { $_.Candidates.Count -gt 0 })

$null = $out.Add('=' * 110)
$null = $out.Add($L.summaryHeading)
$null = $out.Add('=' * 110)
$null = $out.Add(("{0,-24} {1}" -f $L.totalApps, ($regApps.Count + $appxApps.Count)))
$null = $out.Add(("{0,-24} {1}" -f $L.totalShortcuts, $shortcuts.Count))
$null = $out.Add(("{0,-24} {1}" -f $L.signedShortcuts, $signedRows.Count))
$null = $out.Add(("{0,-24} {1}" -f $L.totalDirs, $dirRows.Count))
$null = $out.Add(("{0,-24} {1}" -f $L.dirsWithCandidate, $withCand.Count))
$null = $out.Add(("{0,-24} {1}" -f $L.dirsNoCandidate, ($dirRows.Count - $withCand.Count)))
$null = $out.Add(("{0,-24} {1}" -f $L.regHints, $hints.Items.Count))
if ($hints.Capped) { $null = $out.Add('  ' + $L.regScanCapped) }
$null = $out.Add('')

$null = $out.Add('=' * 110)
$null = $out.Add($L.sigHeading)
$null = $out.Add('=' * 110)
$null = $out.Add($L.sigExplain)
$null = $out.Add('')
if ($signedRows.Count -eq 0) {
    $null = $out.Add($L.noSignatures)
}
else {
    $null = $out.Add(("{0,-46} {1,-32} {2,-26} {3}" -f $L.colSigExe, $L.colSigPublisher, $L.colSigProduct, $L.colSigCompany))
    $null = $out.Add('-' * 110)
    foreach ($r in ($signedRows | Sort-Object -Property Publisher)) {
        $exe = $r.Exe; if ($exe.Length -gt 45) { $exe = '...' + $exe.Substring($exe.Length - 42) }
        $pub = $r.Publisher; if ($pub.Length -gt 31) { $pub = $pub.Substring(0, 31) }
        $prod = $r.Product; if ($prod.Length -gt 25) { $prod = $prod.Substring(0, 25) }
        $comp = $r.Company; if ($comp.Length -gt 30) { $comp = $comp.Substring(0, 30) }
        $null = $out.Add(("{0,-46} {1,-32} {2,-26} {3}" -f $exe, $pub, $prod, $comp))
    }
}
$null = $out.Add('')

$null = $out.Add('=' * 110)
$null = $out.Add($L.hintsHeading)
$null = $out.Add('=' * 110)
$null = $out.Add($L.hintsExplain)
$null = $out.Add('')
if ($hints.Items.Count -eq 0) {
    $null = $out.Add($L.noHints)
}
else {
    $null = $out.Add(("{0,-56} {1,-22} {2}" -f $L.colHintKey, $L.colHintValue, $L.colHintPath))
    $null = $out.Add('-' * 110)
    foreach ($h in $hints.Items) {
        $k = $h.Key; if ($k.Length -gt 55) { $k = $k.Substring(0, 55) }
        $v = $h.Value; if ($v.Length -gt 21) { $v = $v.Substring(0, 21) }
        $null = $out.Add(("{0,-56} {1,-22} {2}" -f $k, $v, $h.Path))
    }
}
$null = $out.Add('')

$null = $out.Add('=' * 110)
$null = $out.Add($L.dirsHeading)
$null = $out.Add('=' * 110)
$null = $out.Add($L.dirsExplain)
$null = $out.Add('')
$null = $out.Add(("{0,-32} {1,10}  {2,-24} {3}" -f $L.colDir, $L.colSize, $L.colCacheLike, $L.colCandidates))
$null = $out.Add('-' * 110)
foreach ($r in ($dirRows | Sort-Object -Property Bytes -Descending)) {
    $dir = $r.Dir; if ($dir.Length -gt 31) { $dir = $dir.Substring(0, 31) }
    $cl = $r.CacheLike; if (-not $cl) { $cl = $L.noCacheLike }
    if ($cl.Length -gt 23) { $cl = $cl.Substring(0, 23) }
    $cands = $L.noCandidate
    if ($r.Candidates.Count -gt 0) {
        $parts = @()
        foreach ($c in $r.Candidates) {
            $srcKey = 'src' + $c.Source.Substring(0, 1).ToUpper() + $c.Source.Substring(1)
            $parts += ("{0} [{1}]" -f $c.Label, $L.$srcKey)
        }
        $cands = $parts -join '  /  '
    }
    $null = $out.Add(("{0,-32} {1,10}  {2,-24} {3}" -f $dir, (Format-Size $r.Bytes), $cl, $cands))
}

$reportDir = Split-Path -Parent $Report
if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$out | Set-Content -LiteralPath $Report -Encoding UTF8

Write-Output ''
Write-Output ("$($L.reportWritten): $Report")
Write-Output ("  {0}: {1}" -f $L.dirsWithCandidate, $withCand.Count)
Write-Output ("  {0}: {1}" -f $L.dirsNoCandidate, ($dirRows.Count - $withCand.Count))
