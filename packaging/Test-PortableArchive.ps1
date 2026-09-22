#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$ArchivePath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot = Split-Path -Parent $PSScriptRoot
$archive = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($ArchivePath))
try {
    $entries = @{}
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if ($name.EndsWith('/')) { continue }
        if (-not $name.StartsWith('QingDaoFu-Portable/') -or $name.Contains('../') -or $entries.ContainsKey($name)) { throw "Unexpected or duplicate entry: $name" }
        $entries[$name.Substring('QingDaoFu-Portable/'.Length)] = $entry
    }
    function Read-ArchiveText([string]$Name) {
        if (-not $entries.ContainsKey($Name)) { throw "Missing package entry: $Name" }
        $reader = New-Object System.IO.StreamReader($entries[$Name].Open(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    foreach ($name in @('QingDaoFu.exe','VERSION','README.md','RELEASE.md','BUILD-MANIFEST.json','app/modules/QdfCli.ps1','app/modules/PathSafety.ps1','app/modules/Executor.ps1','rules/rules.json')) {
        if (-not $entries.ContainsKey($name)) { throw "Missing package entry: $name" }
    }
    $manifest = Read-ArchiveText 'BUILD-MANIFEST.json' | ConvertFrom-Json
    $version = (Read-ArchiveText 'VERSION').Trim()
    $expectedVersion = ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))).Trim()
    if ($version -ne $expectedVersion -or $manifest.Version -ne $version) { throw 'Package version does not match source VERSION.' }
    $rules = (Read-ArchiveText 'rules/rules.json' | ConvertFrom-Json).rules
    $baseline = [IO.File]::ReadAllText((Join-Path $projectRoot 'qdf-tests\fixtures\v1.1.0-rule-ids.json')) | ConvertFrom-Json
    if (@($rules).Count -ne 82 -or @(Compare-Object @($baseline) @($rules.id)).Count -ne 0) { throw 'Package lost or changed the v1.1.0 rule ID set.' }
    $added = [IO.File]::ReadAllText((Join-Path $projectRoot 'qdf-tests\fixtures\v1.1.0-added-rules.json')) | ConvertFrom-Json
    foreach ($rule in $added) {
        $actual = @($rules | Where-Object { $_.id -eq $rule.id })
        if ($actual.Count -ne 1 -or ($actual[0] | ConvertTo-Json -Depth 12 -Compress) -cne ($rule | ConvertTo-Json -Depth 12 -Compress)) { throw "Published new rule regressed: $($rule.id)" }
    }
    if ($manifest.RuleCount -ne 82 -or @(Compare-Object @($manifest.RuleIds) @($rules.id)).Count -ne 0) { throw 'Manifest rule set mismatch.' }
    if (@($manifest.Files).Count + 1 -ne $entries.Count) { throw 'Manifest does not cover the whole archive.' }
    foreach ($file in $manifest.Files) {
        if (-not $entries.ContainsKey($file.Path)) { throw "Manifest entry missing: $($file.Path)" }
        $stream = $entries[$file.Path].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
        if ($actualHash -ne $file.SHA256) { throw "Package file hash mismatch: $($file.Path)" }
        # Executable bytes vary by toolchain; shipped scripts, rules and docs must match this checkout.
        if ($file.Path -ne 'QingDaoFu.exe') {
            $source = Join-Path $projectRoot $file.Path
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $actualHash) { throw "Package/source mismatch: $($file.Path)" }
        }
    }
    [pscustomobject]@{ Version = $version; RuleCount = @($rules).Count; DisabledRuleCount = @($rules | Where-Object { $_.PSObject.Properties['enabled'] -and $_.enabled -eq $false }).Count; SourceCommit = $manifest.SourceCommit; SourceDirty = $manifest.SourceDirty; Validation = $manifest.Validation; FileCount = $entries.Count; SHA256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant() }
} finally { $archive.Dispose() }
