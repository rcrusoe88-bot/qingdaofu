$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'app\QingDaoFu.ps1')

function New-QdfTestFixture {
    $root = Join-Path $env:TEMP ('QingDaoFu.Tests.' + [guid]::NewGuid().ToString('N'))
    $cacheRoot = Join-Path $root 'cache'
    $receiptRoot = Join-Path $root 'receipts'
    $rulesPath = Join-Path $root 'rules.json'

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

    $oldFile = Join-Path $cacheRoot 'old.tmp'
    $newFile = Join-Path $cacheRoot 'new.tmp'
    Set-Content -LiteralPath $oldFile -Value ('x' * 1024) -Encoding ASCII
    Set-Content -LiteralPath $newFile -Value ('y' * 2048) -Encoding ASCII
    (Get-Item -LiteralPath $oldFile).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-10)

    $ruleset = [pscustomobject]@{
        schemaVersion = 1
        largeFileThresholdBytes = 1073741824
        rules = @(
            [pscustomobject]@{
                id = 'fixture-cache'
                name = 'Fixture cache'
                description = 'Fixture only'
                kind = 'cleanup'
                risk = 'safe'
                action = 'delete'
                defaultSelected = $true
                pathTemplates = @($cacheRoot)
                filePatterns = @('*.tmp')
                recurse = $true
                minAgeDays = 7
            }
        )
    }

    $json = $ruleset | ConvertTo-Json -Depth 8
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($rulesPath, $json, $encoding)

    return [pscustomobject]@{
        Root = $root
        CacheRoot = $cacheRoot
        ReceiptRoot = $receiptRoot
        RulesPath = $rulesPath
        OldFile = $oldFile
        NewFile = $newFile
    }
}

function Remove-QdfTestFixture {
    param([object]$Fixture)
    if ($null -eq $Fixture -or -not (Test-Path -LiteralPath $Fixture.Root)) { return }
    $full = [System.IO.Path]::GetFullPath($Fixture.Root)
    $parent = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    if ([System.IO.Path]::GetDirectoryName($full) -ne $parent -or [System.IO.Path]::GetFileName($full) -notmatch '^QingDaoFu.Tests\.[a-f0-9]{32}$' -or (Test-QdfProtectedPath $full)) { throw 'Unsafe fixture cleanup path.' }
    Remove-QdfSafeTestTree -Path $full -Boundary $full
}
function Remove-QdfSafeTestTree {
    param([string]$Path, [string]$Boundary)
    if (-not (Test-QdfPathEqualOrChild $Path $Boundary) -or (Test-QdfProtectedPath $Path)) { throw 'Unsafe test path.' }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        if (-not (Test-QdfReparsePoint $item)) {
            foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) { Remove-QdfSafeTestTree $child.FullName $Boundary }
        }
        [System.IO.Directory]::Delete($Path, $false)
    } else { [System.IO.File]::Delete($Path) }
}

Describe 'QingDaoFu core safety' {
    It 'loads the versioned ruleset' {
        $ruleset = Read-QdfJsonFile -Path (Join-Path $projectRoot 'rules\rules.json')
        Test-QdfRuleset -Ruleset $ruleset
        $ruleset.schemaVersion | Should Be 1
        @($ruleset.rules).Count | Should BeGreaterThan 5
    }

    It 'protects Windows system paths' {
        Test-QdfProtectedPath -Path $env:WINDIR | Should Be $true
        Test-QdfProtectedPath -Path (Join-Path $env:WINDIR 'System32') | Should Be $true
    }

    It 'allows isolated temporary paths' {
        $fixture = New-QdfTestFixture
        try {
            Test-QdfProtectedPath -Path $fixture.OldFile | Should Be $false
        }
        finally {
            Remove-QdfTestFixture -Fixture $fixture
        }
    }
}

Describe 'QingDaoFu scanner' {
    It 'finds only files older than the rule threshold' {
        $fixture = New-QdfTestFixture
        try {
            $scan = Invoke-QdfScan -RulesPath $fixture.RulesPath -SkipLargeFiles -MaxDetailsPerCategory -1
            $scan.Categories.Count | Should Be 1
            $scan.Categories[0].ItemCount | Should Be 1
            $scan.Categories[0].Files[0].Path | Should Be (Get-Item -LiteralPath $fixture.OldFile).FullName
        }
        finally {
            Remove-QdfTestFixture -Fixture $fixture
        }
    }

    It 'rejects candidates outside the rule root' {
        $fixture = New-QdfTestFixture
        try {
            $ruleset = Read-QdfJsonFile -Path $fixture.RulesPath
            $rule = $ruleset.rules[0]
            Test-QdfCandidatePath -Path $fixture.OldFile -Rule $rule | Should Be $true
            Test-QdfCandidatePath -Path (Join-Path $env:WINDIR 'notepad.exe') -Rule $rule | Should Be $false
        }
        finally {
            Remove-QdfTestFixture -Fixture $fixture
        }
    }
}

Describe 'QingDaoFu executor' {
    It 'does not delete files during a dry run' {
        $fixture = New-QdfTestFixture
        try {
            $result = Invoke-QdfClean `
                -RulesPath $fixture.RulesPath `
                -SelectedRuleIds @('fixture-cache') `
                -DryRun `
                -SkipOperationLog `
                -ReceiptDirectory $fixture.ReceiptRoot

            Test-Path -LiteralPath $fixture.OldFile | Should Be $true
            $result.SuccessfulCount | Should Be 1
            Test-Path -LiteralPath $result.ReceiptPath | Should Be $true
        }
        finally {
            Remove-QdfTestFixture -Fixture $fixture
        }
    }

    It 'deletes only the scanned candidate during a real run' {
        $fixture = New-QdfTestFixture
        try {
            Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot | Out-Null
            $expectedBytes = (Get-Item -LiteralPath $fixture.OldFile).Length
            $result = Invoke-QdfClean `
                -RulesPath $fixture.RulesPath `
                -SelectedRuleIds @('fixture-cache') `
                -SkipOperationLog `
                -ReceiptDirectory $fixture.ReceiptRoot

            Test-Path -LiteralPath $fixture.OldFile | Should Be $false
            Test-Path -LiteralPath $fixture.NewFile | Should Be $true
            $result.SuccessfulCount | Should Be 1
            $result.BytesFreed | Should Be $expectedBytes
            Test-Path -LiteralPath $result.ReceiptPath | Should Be $true
        }
        finally {
            Remove-QdfTestFixture -Fixture $fixture
        }
    }

    It 'fast-path deletes a fully covered subtree once' {
        $fixture = New-QdfTestFixture
        try {
            # 64+ deletable files so the fast path qualifies, plus nested dirs.
            $treeRoot = Join-Path $fixture.CacheRoot 'tree'
            New-Item -ItemType Directory -Path (Join-Path $treeRoot 'a\b') -Force | Out-Null
            for ($i = 0; $i -lt 70; $i++) {
                Set-Content -LiteralPath (Join-Path $treeRoot "a\b\f$i.tmp") -Value ('x' * 64) -Encoding ASCII
                (Get-Item -LiteralPath (Join-Path $treeRoot "a\b\f$i.tmp")).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-10)
            }
            # A too-new file inside the tree must block coverage and survive.
            $protected = Join-Path $treeRoot 'a\b\new.tmp'
            Set-Content -LiteralPath $protected -Value 'keep' -Encoding ASCII

            $result = Invoke-QdfClean `
                -RulesPath $fixture.RulesPath `
                -SelectedRuleIds @('fixture-cache') `
                -SkipOperationLog `
                -ReceiptDirectory $fixture.ReceiptRoot

            Test-Path -LiteralPath $protected | Should Be $true
            @(Get-ChildItem -LiteralPath (Join-Path $treeRoot 'a\b') -Filter 'f*.tmp').Count | Should Be 0
            $result.ReceiptPath | Should Not BeNullOrEmpty
        }
        finally {
            Remove-QdfTestFixture -Fixture $fixture
        }
    }
}

Describe 'QingDaoFu whitelist' {
    It 'skips whitelisted paths during scanning' {
        $fixture = New-QdfTestFixture
        $originalDataRoot = $script:QdfDataRoot
        try {
            $script:QdfDataRoot = $fixture.Root
            [System.IO.File]::WriteAllText(
                (Join-Path $fixture.Root 'whitelist.txt'),
                $fixture.OldFile,
                (New-Object System.Text.UTF8Encoding($false))
            )

            $scan = Invoke-QdfScan -RulesPath $fixture.RulesPath -SkipLargeFiles -MaxDetailsPerCategory -1
            @($scan.Categories[0].Files).Count | Should Be 0
            @($scan.Skipped | Where-Object { $_.Reason -eq 'Whitelisted.' }).Count | Should BeGreaterThan 0
        }
        finally {
            $script:QdfDataRoot = $originalDataRoot
            Remove-QdfTestFixture -Fixture $fixture
        }
    }

    It 'refuses a candidate that a later whitelist covers' {
        $fixture = New-QdfTestFixture
        $originalDataRoot = $script:QdfDataRoot
        try {
            $scan = Invoke-QdfScan -RulesPath $fixture.RulesPath -SkipLargeFiles -MaxDetailsPerCategory -1
            @($scan.Categories[0].Files).Count | Should Be 1

            $script:QdfDataRoot = $fixture.Root
            [System.IO.File]::WriteAllText(
                (Join-Path $fixture.Root 'whitelist.txt'),
                $fixture.OldFile,
                (New-Object System.Text.UTF8Encoding($false))
            )

            $rule = (Read-QdfJsonFile -Path $fixture.RulesPath).rules[0]
            Test-QdfCandidatePath -Path $fixture.OldFile -Rule $rule | Should Be $false
        }
        finally {
            $script:QdfDataRoot = $originalDataRoot
            Remove-QdfTestFixture -Fixture $fixture
        }
    }
}

Describe 'QingDaoFu orphan scan helpers' {
    It 'treats a folder as installed when its name overlaps an app name' {
        $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $null = $names.Add('Google Chrome')
        Test-QdfOrphanNameInstalled -FolderName 'Chrome' -InstalledNames $names | Should Be $true
        Test-QdfOrphanNameInstalled -FolderName 'TotallyDifferent' -InstalledNames $names | Should Be $false

        # Containment is only trusted once the shorter side has 4+ characters.
        $short = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $null = $short.Add('Foo')
        Test-QdfOrphanNameInstalled -FolderName 'Foo' -InstalledNames $short | Should Be $true
        Test-QdfOrphanNameInstalled -FolderName 'Foobar' -InstalledNames $short | Should Be $false
    }

    It 'never reports folders owned by a shipped rule' {
        $names = Get-QdfRuleAppNames
        $names.Contains('Google') | Should Be $true
        $names.Contains('discord') | Should Be $true
        $names.Contains('Tencent') | Should Be $true
    }
}

Describe 'QingDaoFu safety regressions' {
    It 'rejects a junction in the ancestor of a rule root' {
        $fixture = New-QdfTestFixture
        try {
            $alias = Join-Path $fixture.Root 'alias'
            $target = Join-Path $fixture.Root 'target'
            $nested = Join-Path $target 'cache'
            New-Item -ItemType Directory -Path $nested -Force | Out-Null
            New-Item -ItemType Junction -Path $alias -Target $target -ErrorAction Stop | Out-Null
            $rule = (Read-QdfJsonFile $fixture.RulesPath).rules[0]
            $rule.pathTemplates = @((Join-Path $alias 'cache'))
            Test-QdfPathChain (Join-Path $alias 'cache') | Should Be $false
            @(Resolve-QdfRuleRoots $rule).Count | Should Be 0
        } finally { Remove-QdfTestFixture $fixture }
    }
    It 'pins ancestors against rename while a candidate is processed' {
        $fixture = New-QdfTestFixture
        $lease = $null
        try {
            $lease = New-Object QdfPathLease($fixture.OldFile)
            { [System.IO.Directory]::Move($fixture.CacheRoot, (Join-Path $fixture.Root 'renamed')) } | Should Throw
        } finally { if ($lease) { $lease.Dispose() }; Remove-QdfTestFixture $fixture }
    }
    It 'rejects metadata changes instead of deleting a replacement' {
        $fixture = New-QdfTestFixture
        try {
            Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot | Out-Null
            $original = Get-Item -LiteralPath $fixture.OldFile
            { Remove-QdfCandidateFile $fixture.OldFile ($original.Length + 1) $original.LastWriteTimeUtc } | Should Throw
            Test-Path -LiteralPath $fixture.OldFile | Should Be $true
        } finally { Remove-QdfTestFixture $fixture }
    }
    It 'writes BOM-free receipts and durable outcomes' {
        $fixture = New-QdfTestFixture
        try {
            $result = Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot
            $bytes = [System.IO.File]::ReadAllBytes($result.ReceiptPath)
            $bytes[0] | Should Be 123
            $result.State | Should Be 'Completed'
            $lines = @(Get-Content -LiteralPath ($result.ReceiptPath + '.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            $lines[1].Type | Should Be 'planned'
            $lines[2].Type | Should Be 'outcome'
            $lines[2].Status | Should Be 'DryRun'
        } finally { Remove-QdfTestFixture $fixture }
    }
    It 'honors cancellation before the first deletion and leaves a receipt' {
        $fixture = New-QdfTestFixture
        try {
            Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot | Out-Null
            $marker = Join-Path $fixture.Root 'cancel'
            Set-Content -LiteralPath $marker -Value 'stop'
            $result = Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot -CancelPath $marker
            $result.State | Should Be 'Cancelled'
            Test-Path -LiteralPath $fixture.OldFile | Should Be $true
            Test-Path -LiteralPath $result.ReceiptPath | Should Be $true
        } finally { Remove-QdfTestFixture $fixture }
    }
}

Describe 'QingDaoFu failure boundaries' {
    It 'does not delete anything if the initial receipt cannot be written' {
        $fixture = New-QdfTestFixture
        try {
            Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot | Out-Null
            $badReceiptRoot = Join-Path $fixture.Root 'not-a-directory'
            Set-Content -LiteralPath $badReceiptRoot -Value 'file'
            { Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -SkipOperationLog -ReceiptDirectory $badReceiptRoot } | Should Throw
            Test-Path -LiteralPath $fixture.OldFile | Should Be $true
        } finally { Remove-QdfTestFixture $fixture }
    }
    It 'rejects unknown selected rules instead of reporting empty success' {
        $fixture = New-QdfTestFixture
        try {
            { Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('unknown') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot } | Should Throw
        } finally { Remove-QdfTestFixture $fixture }
    }
    It 'honors disabled rules in scanning and execution' {
        $fixture = New-QdfTestFixture
        try {
            $set = Read-QdfJsonFile $fixture.RulesPath
            $set.rules[0] | Add-Member -NotePropertyName enabled -NotePropertyValue $false
            [System.IO.File]::WriteAllText($fixture.RulesPath, ($set | ConvertTo-Json -Depth 8))
            $scan = Invoke-QdfScan -RulesPath $fixture.RulesPath
            @($scan.Categories).Count | Should Be 0
            { Invoke-QdfClean -RulesPath $fixture.RulesPath -SelectedRuleIds @('fixture-cache') -DryRun -SkipOperationLog -ReceiptDirectory $fixture.ReceiptRoot } | Should Throw
        } finally { Remove-QdfTestFixture $fixture }
    }
    It 'keeps aggregate counts when details are capped' {
        $fixture = New-QdfTestFixture
        try {
            $scan = Invoke-QdfScan -RulesPath $fixture.RulesPath -MaxDetailsPerCategory 0
            $scan.Categories[0].ItemCount | Should Be 1
            @($scan.Categories[0].Files).Count | Should Be 0
            $scan.Categories[0].DetailsTruncated | Should Be $true
        } finally { Remove-QdfTestFixture $fixture }
    }
}

Describe 'Published v1.1.0 baseline and release version' {
    It 'preserves all 99 published rule IDs without duplicates' {
        $rules = (Read-QdfJsonFile (Join-Path $projectRoot 'rules\rules.json')).rules
        $ids = Read-QdfJsonFile (Join-Path $PSScriptRoot 'fixtures\v1.1.0-rule-ids.json')
        @($rules).Count | Should Be 99
        @($rules.id | Select-Object -Unique).Count | Should Be 99
        @(Compare-Object @($ids) @($rules.id)).Count | Should Be 0
    }
    It 'preserves the complete definitions of the eleven new published rules' {
        $rules = (Read-QdfJsonFile (Join-Path $projectRoot 'rules\rules.json')).rules
        $added = Read-QdfJsonFile (Join-Path $PSScriptRoot 'fixtures\v1.1.0-added-rules.json')
        @($added).Count | Should Be 11
        foreach ($expected in $added) {
            $actual = @($rules | Where-Object { $_.id -eq $expected.id })
            $actual.Count | Should Be 1
            ($actual[0] | ConvertTo-Json -Depth 12 -Compress) | Should Be ($expected | ConvertTo-Json -Depth 12 -Compress)
        }
    }
    It 'retains explicit reasons for the six disabled safety-review rules' {
        $rules = (Read-QdfJsonFile (Join-Path $projectRoot 'rules\rules.json')).rules
        $disabled = @($rules | Where-Object { (Get-QdfPropertyValue $_ 'enabled' $true) -eq $false })
        $disabled.Count | Should Be 6
        foreach ($rule in $disabled) {
            $rule.defaultSelected | Should Be $false
            [string]::IsNullOrWhiteSpace($rule.disabledReason) | Should Be $false
        }
    }
    It 'keeps VERSION, Wails and the legacy fallback consistent' {
        $version = ([IO.File]::ReadAllText((Join-Path $projectRoot 'VERSION'))).Trim()
        $config = Read-QdfJsonFile (Join-Path $projectRoot 'gui\wails.json')
        $config.info.productVersion | Should Be $version
        $legacy = [IO.File]::ReadAllText((Join-Path $projectRoot 'lib\core\version.ps1'))
        $legacy.Contains(('MoleDefaultVersion = "' + $version + '"')) | Should Be $true
    }
}
