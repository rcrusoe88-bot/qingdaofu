$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'QingDaoFu.ps1')
    Show-QdfMainWindow
}
catch {
    $message = $_.Exception.Message
    try {
        $logRoot = Join-Path $env:LOCALAPPDATA 'QingDaoFu\logs'
        if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        }

        $logPath = Join-Path $logRoot 'startup.log'
        $entry = ('{0} {1}' -f ([datetime]::UtcNow.ToString('o')), $message)
        Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    }
    catch {
    }

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'QingDaoFu',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
