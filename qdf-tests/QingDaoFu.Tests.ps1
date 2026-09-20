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

    if ($null -ne $Fixture -and (Test-Path -LiteralPath $Fixture.Root)) {
        Remove-Item -LiteralPath $Fixture.Root -Recurse -Force
    }
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
            $scan.Categories[0].Files[0].Path | Should Be $fixture.OldFile
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
}
