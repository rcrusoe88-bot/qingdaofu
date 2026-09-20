function Get-QdfRiskText {
    param([string]$Risk)

    switch ($Risk) {
        'safe' { return Get-QdfUiString -Key 'riskSafe' -DefaultValue 'Safe' }
        'careful' { return Get-QdfUiString -Key 'riskCareful' -DefaultValue 'Careful' }
        'readonly' { return Get-QdfUiString -Key 'riskReadonly' -DefaultValue 'Read only' }
        default { return $Risk }
    }
}

function Get-QdfActionText {
    param([string]$Action)

    switch ($Action) {
        'delete' { return Get-QdfUiString -Key 'actionDelete' -DefaultValue 'Delete' }
        'recycle' { return Get-QdfUiString -Key 'actionRecycle' -DefaultValue 'Recycle Bin' }
        'readonly' { return Get-QdfUiString -Key 'riskReadonly' -DefaultValue 'Read only' }
        default { return $Action }
    }
}

function New-QdfPadding {
    param(
        [int]$Left,
        [int]$Top,
        [int]$Right,
        [int]$Bottom
    )

    return New-Object System.Windows.Forms.Padding -ArgumentList $Left, $Top, $Right, $Bottom
}

function Set-QdfStage {
    param(
        [ValidateSet('Scan', 'Review', 'Done')]
        [string]$Stage
    )

    $state = $script:QdfGuiState
    $state['ScanPanel'].Visible = ($Stage -eq 'Scan')
    $state['ReviewPanel'].Visible = ($Stage -eq 'Review')
    $state['DonePanel'].Visible = ($Stage -eq 'Done')

    $activeColor = [System.Drawing.Color]::FromArgb(23, 107, 99)
    $inactiveColor = [System.Drawing.Color]::FromArgb(122, 132, 140)

    foreach ($name in @('ScanStep', 'ReviewStep', 'DoneStep')) {
        $state[$name].ForeColor = $inactiveColor
    }

    switch ($Stage) {
        'Scan' {
            $state['ScanStep'].ForeColor = $activeColor
            $state['Form'].AcceptButton = $state['ScanButton']
        }
        'Review' {
            $state['ReviewStep'].ForeColor = $activeColor
            $state['Form'].AcceptButton = $state['CleanButton']
        }
        'Done' {
            $state['DoneStep'].ForeColor = $activeColor
            $state['Form'].AcceptButton = $state['CloseButton']
        }
    }
}

function Set-QdfStatus {
    param([string]$Text)

    $script:QdfGuiState['StatusLabel'].Text = $Text
}

function Get-QdfSelectedRuleIdsFromGrid {
    $selectedIds = New-Object System.Collections.Generic.List[string]
    $grid = $script:QdfGuiState['Grid']

    foreach ($row in $grid.Rows) {
        if ($row.Tag -eq '__large_files__') {
            continue
        }

        $cell = $row.Cells[0]
        if ($null -ne $cell.Value -and [bool]$cell.Value) {
            $selectedIds.Add([string]$row.Tag)
        }
    }

    return $selectedIds.ToArray()
}

function Show-QdfDetailsForRow {
    param([int]$RowIndex)

    $state = $script:QdfGuiState
    $grid = $state['Grid']
    $details = $state['Details']

    if ($RowIndex -lt 0 -or $RowIndex -ge $grid.Rows.Count) {
        $details.Text = ''
        return
    }

    $row = $grid.Rows[$RowIndex]
    $tag = [string]$row.Tag
    $lines = New-Object System.Collections.Generic.List[string]

    if ($tag -eq '__large_files__') {
        $largeFiles = @($state['LastScan'].LargeFiles)
        $lines.Add((Get-QdfUiString -Key 'largeFilesDescription' -DefaultValue ''))
        $lines.Add('')
        foreach ($file in ($largeFiles | Select-Object -First 200)) {
            $lines.Add(('[{0}] {1}' -f (Format-QdfSize -Bytes ([long]$file.Size)), $file.Path))
        }
        if ($largeFiles.Count -gt 200) {
            $lines.Add('')
            $lines.Add(('Only the first 200 paths are shown. Total: {0}' -f $largeFiles.Count))
        }
        $details.Text = ($lines -join [Environment]::NewLine)
        return
    }

    $category = $null
    foreach ($item in @($state['LastScan'].Categories)) {
        if ($item.Id -eq $tag) {
            $category = $item
            break
        }
    }

    if ($null -eq $category) {
        $details.Text = ''
        return
    }

    $lines.Add($category.Description)
    $lines.Add('')
    foreach ($file in @($category.Files | Select-Object -First 200)) {
        $lines.Add(('[{0}] {1}' -f (Format-QdfSize -Bytes ([long]$file.Size)), $file.Path))
    }

    if ($category.DetailsTruncated) {
        $lines.Add('')
        $lines.Add(('Only the first 200 paths are shown. Total: {0}' -f $category.ItemCount))
    }

    $details.Text = ($lines -join [Environment]::NewLine)
}

function Update-QdfReviewGrid {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scan
    )

    $state = $script:QdfGuiState
    $grid = $state['Grid']
    $grid.Rows.Clear()

    foreach ($category in @($Scan.Categories)) {
        $index = $grid.Rows.Add()
        $row = $grid.Rows[$index]
        $row.Tag = $category.Id
        $row.Cells[0].Value = [bool]$category.DefaultSelected
        $row.Cells[1].Value = $category.Name
        $row.Cells[2].Value = Get-QdfActionText -Action $category.Action
        $row.Cells[3].Value = Get-QdfRiskText -Risk $category.Risk
        $row.Cells[4].Value = $category.TotalSizeText
        $row.Cells[5].Value = $category.ItemCount
        $row.Cells[6].Value = $category.Description
    }

    $largeFiles = @($Scan.LargeFiles)
    if ($largeFiles.Count -gt 0) {
        $largeSize = 0L
        foreach ($file in $largeFiles) {
            $largeSize += [long]$file.Size
        }

        $index = $grid.Rows.Add()
        $row = $grid.Rows[$index]
        $row.Tag = '__large_files__'
        $row.Cells[0].Value = $false
        $row.Cells[0].ReadOnly = $true
        $row.Cells[1].Value = Get-QdfUiString -Key 'largeFilesHeading' -DefaultValue 'Large files'
        $row.Cells[2].Value = Get-QdfUiString -Key 'riskReadonly' -DefaultValue 'Read only'
        $row.Cells[3].Value = Get-QdfUiString -Key 'riskReadonly' -DefaultValue 'Read only'
        $row.Cells[4].Value = Format-QdfSize -Bytes $largeSize
        $row.Cells[5].Value = $largeFiles.Count
        $row.Cells[6].Value = Get-QdfUiString -Key 'largeFilesDescription' -DefaultValue ''
    }

    if ($grid.Rows.Count -gt 0) {
        $grid.Rows[0].Selected = $true
        $grid.CurrentCell = $grid.Rows[0].Cells[1]
        Show-QdfDetailsForRow -RowIndex 0
    }
    else {
        $state['Details'].Text = Get-QdfUiString -Key 'noItems' -DefaultValue ''
    }
}

function Reset-QdfScanButton {
    $state = $script:QdfGuiState
    $state['ScanButton'].Enabled = $true
    $state['CancelButton'].Enabled = $false
    $state['ScanButton'].Text = Get-QdfUiString -Key 'scanButton' -DefaultValue 'Scan'
}

function Complete-QdfBackgroundJob {
    $state = $script:QdfGuiState
    $job = $state['Job']
    if ($null -eq $job) {
        return
    }

    try {
        $result = @(Receive-Job -Job $job -ErrorAction Stop)
        $jobKind = [string]$state['JobKind']

        if ($jobKind -eq 'scan') {
            if ($result.Count -eq 0) {
                throw 'The scan job returned no result.'
            }

            $state['LastScan'] = $result[0]
            Update-QdfReviewGrid -Scan $result[0]
            Set-QdfStatus -Text (Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready')
            Set-QdfStage -Stage 'Review'
        }
        else {
            if ($result.Count -eq 0) {
                throw 'The cleanup job returned no result.'
            }

            $state['LastCleanResult'] = $result[0]
            Show-QdfDoneSummary -Result $result[0]
            Set-QdfStatus -Text (Get-QdfUiString -Key 'statusDone' -DefaultValue 'Done')
            Set-QdfStage -Stage 'Done'
        }
    }
    catch {
        Show-QdfError -Message $_.Exception.Message
        Set-QdfStatus -Text (Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready')
    }
    finally {
        if ($null -ne $state['Job']) {
            Remove-Job -Job $state['Job'] -Force -ErrorAction SilentlyContinue
        }
        $state['Job'] = $null
        $state['JobKind'] = ''
        Reset-QdfScanButton
        $state['CleanButton'].Enabled = $true
        $state['BackButton'].Enabled = $true
    }
}

function Start-QdfBackgroundJob {
    param(
        [ValidateSet('scan', 'clean')]
        [string]$Kind,

        [string[]]$RuleIds = @()
    )

    $state = $script:QdfGuiState
    if ($null -ne $state['Job']) {
        return
    }

    $loaderPath = Join-Path $script:QdfAppRoot 'QingDaoFu.ps1'
    $rulesPath = $script:QdfRulesPath

    if ($Kind -eq 'scan') {
        $job = Start-Job -ScriptBlock {
            param($Loader, $Rules)
            . $Loader
            Invoke-QdfScan -RulesPath $Rules
        } -ArgumentList $loaderPath, $rulesPath
    }
    else {
        $job = Start-Job -ScriptBlock {
            param($Loader, $Rules, $Ids)
            . $Loader
            Invoke-QdfClean -RulesPath $Rules -SelectedRuleIds $Ids
        } -ArgumentList $loaderPath, $rulesPath, $RuleIds
    }

    $state['Job'] = $job
    $state['JobKind'] = $Kind
    $state['ScanButton'].Enabled = $false
    $state['CancelButton'].Enabled = $true
    $state['CleanButton'].Enabled = $false
    $state['BackButton'].Enabled = $false
    Set-QdfStatus -Text $(if ($Kind -eq 'scan') {
        Get-QdfUiString -Key 'statusScanning' -DefaultValue 'Scanning'
    }
    else {
        Get-QdfUiString -Key 'statusCleaning' -DefaultValue 'Cleaning'
    })
}

function Stop-QdfBackgroundJob {
    $state = $script:QdfGuiState
    if ($null -eq $state['Job']) {
        return
    }

    Stop-Job -Job $state['Job'] -ErrorAction SilentlyContinue
    Remove-Job -Job $state['Job'] -Force -ErrorAction SilentlyContinue
    $state['Job'] = $null
    $state['JobKind'] = ''
    Reset-QdfScanButton
    $state['CleanButton'].Enabled = $true
    $state['BackButton'].Enabled = $true
    Set-QdfStatus -Text (Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready')
}

function Show-QdfDoneSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $state = $script:QdfGuiState
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-QdfUiString -Key 'doneHeading' -DefaultValue 'Done'))
    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-QdfUiString -Key 'summaryProcessed' -DefaultValue 'Processed'), $Result.SuccessfulCount))
    $lines.Add(('{0}: {1}' -f (Get-QdfUiString -Key 'summaryFreed' -DefaultValue 'Freed'), $Result.BytesFreedText))
    $lines.Add(('{0}: {1}' -f (Get-QdfUiString -Key 'summaryRecycled' -DefaultValue 'Recycled'), $Result.BytesRecycledText))
    $lines.Add(('{0}: {1}' -f (Get-QdfUiString -Key 'summaryFailed' -DefaultValue 'Failed'), $Result.FailedCount))
    $lines.Add(('{0}: {1}' -f (Get-QdfUiString -Key 'summarySkipped' -DefaultValue 'Skipped'), $Result.SkippedCount))
    $lines.Add('')
    $lines.Add(('{0}: {1}' -f (Get-QdfUiString -Key 'receiptPath' -DefaultValue 'Receipt'), $Result.ReceiptPath))

    if ($Result.BytesRecycled -gt 0) {
        $lines.Add('')
        $lines.Add((Get-QdfUiString -Key 'reviewDescription' -DefaultValue ''))
    }

    $state['DoneText'].Text = ($lines -join [Environment]::NewLine)
}

function Show-QdfMainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $appTitle = Get-QdfUiString -Key 'appTitle' -DefaultValue 'QingDaoFu'
    $accent = [System.Drawing.Color]::FromArgb(23, 107, 99)
    $ink = [System.Drawing.Color]::FromArgb(31, 41, 51)
    $muted = [System.Drawing.Color]::FromArgb(102, 112, 122)
    $surface = [System.Drawing.Color]::White
    $background = [System.Drawing.Color]::FromArgb(244, 247, 248)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $appTitle
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(980, 700)
    $form.Size = New-Object System.Drawing.Size(1080, 760)
    $form.BackColor = $background
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 88
    $header.BackColor = $surface
    $header.Padding = New-QdfPadding -Left 24 -Top 14 -Right 24 -Bottom 10
    $form.Controls.Add($header)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $appTitle
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $ink
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(24, 12)
    $header.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = Get-QdfUiString -Key 'appSubtitle' -DefaultValue ''
    $subtitleLabel.ForeColor = $muted
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = New-Object System.Drawing.Point(27, 55)
    $header.Controls.Add($subtitleLabel)

    $stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $stepPanel.Dock = 'Top'
    $stepPanel.Height = 42
    $stepPanel.FlowDirection = 'LeftToRight'
    $stepPanel.Padding = New-QdfPadding -Left 24 -Top 8 -Right 0 -Bottom 0
    $stepPanel.BackColor = $surface
    $form.Controls.Add($stepPanel)

    $scanStep = New-Object System.Windows.Forms.Label
    $scanStep.Text = Get-QdfUiString -Key 'stepScan' -DefaultValue '1. Scan'
    $scanStep.AutoSize = $true
    $scanStep.Margin = New-QdfPadding -Left 0 -Top 3 -Right 34 -Bottom 0
    $scanStep.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $stepPanel.Controls.Add($scanStep)

    $reviewStep = New-Object System.Windows.Forms.Label
    $reviewStep.Text = Get-QdfUiString -Key 'stepReview' -DefaultValue '2. Review'
    $reviewStep.AutoSize = $true
    $reviewStep.Margin = New-QdfPadding -Left 0 -Top 3 -Right 34 -Bottom 0
    $reviewStep.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $stepPanel.Controls.Add($reviewStep)

    $doneStep = New-Object System.Windows.Forms.Label
    $doneStep.Text = Get-QdfUiString -Key 'stepDone' -DefaultValue '3. Done'
    $doneStep.AutoSize = $true
    $doneStep.Margin = New-QdfPadding -Left 0 -Top 3 -Right 0 -Bottom 0
    $doneStep.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $stepPanel.Controls.Add($doneStep)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready'
    $statusStrip.Items.Add($statusLabel) | Out-Null
    $form.Controls.Add($statusStrip)

    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = 'Fill'
    $content.Padding = New-QdfPadding -Left 24 -Top 12 -Right 24 -Bottom 16
    $form.Controls.Add($content)
    $content.BringToFront()

    $scanPanel = New-Object System.Windows.Forms.Panel
    $scanPanel.Dock = 'Fill'
    $scanPanel.BackColor = $surface
    $scanPanel.Padding = New-QdfPadding -Left 40 -Top 36 -Right 40 -Bottom 36
    $content.Controls.Add($scanPanel)

    $scanHeading = New-Object System.Windows.Forms.Label
    $scanHeading.Text = Get-QdfUiString -Key 'scanHeading' -DefaultValue ''
    $scanHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
    $scanHeading.ForeColor = $ink
    $scanHeading.AutoSize = $true
    $scanHeading.Location = New-Object System.Drawing.Point(40, 42)
    $scanPanel.Controls.Add($scanHeading)

    $scanDescription = New-Object System.Windows.Forms.Label
    $scanDescription.Text = Get-QdfUiString -Key 'scanDescription' -DefaultValue ''
    $scanDescription.ForeColor = $muted
    $scanDescription.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $scanDescription.AutoSize = $true
    $scanDescription.Location = New-Object System.Drawing.Point(43, 94)
    $scanPanel.Controls.Add($scanDescription)

    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = Get-QdfUiString -Key 'scanButton' -DefaultValue 'Scan'
    $scanButton.Size = New-Object System.Drawing.Size(170, 44)
    $scanButton.Location = New-Object System.Drawing.Point(43, 150)
    $scanButton.BackColor = $accent
    $scanButton.ForeColor = [System.Drawing.Color]::White
    $scanButton.FlatStyle = 'Flat'
    $scanButton.FlatAppearance.BorderSize = 0
    $scanButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $scanPanel.Controls.Add($scanButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = Get-QdfUiString -Key 'cancelScan' -DefaultValue 'Cancel'
    $cancelButton.Size = New-Object System.Drawing.Size(110, 44)
    $cancelButton.Location = New-Object System.Drawing.Point(225, 150)
    $cancelButton.Enabled = $false
    $cancelButton.FlatStyle = 'Flat'
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(232, 236, 238)
    $cancelButton.ForeColor = $ink
    $scanPanel.Controls.Add($cancelButton)

    $reviewPanel = New-Object System.Windows.Forms.Panel
    $reviewPanel.Dock = 'Fill'
    $reviewPanel.BackColor = $surface
    $reviewPanel.Visible = $false
    $reviewPanel.Padding = New-QdfPadding -Left 18 -Top 14 -Right 18 -Bottom 14
    $content.Controls.Add($reviewPanel)

    $reviewLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $reviewLayout.Dock = 'Fill'
    $reviewLayout.ColumnCount = 1
    $reviewLayout.RowCount = 3
    $reviewLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $reviewLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 78)) | Out-Null
    $reviewLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $reviewLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 58)) | Out-Null
    $reviewPanel.Controls.Add($reviewLayout)

    $reviewHeader = New-Object System.Windows.Forms.Panel
    $reviewHeader.Dock = 'Fill'
    $reviewHeader.BackColor = $surface
    $reviewLayout.Controls.Add($reviewHeader, 0, 0)

    $reviewHeading = New-Object System.Windows.Forms.Label
    $reviewHeading.Text = Get-QdfUiString -Key 'reviewHeading' -DefaultValue ''
    $reviewHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
    $reviewHeading.ForeColor = $ink
    $reviewHeading.AutoSize = $true
    $reviewHeading.Location = New-Object System.Drawing.Point(2, 4)
    $reviewHeader.Controls.Add($reviewHeading)

    $reviewDescription = New-Object System.Windows.Forms.Label
    $reviewDescription.Text = Get-QdfUiString -Key 'reviewDescription' -DefaultValue ''
    $reviewDescription.ForeColor = $muted
    $reviewDescription.AutoSize = $true
    $reviewDescription.Location = New-Object System.Drawing.Point(4, 38)
    $reviewHeader.Controls.Add($reviewDescription)

    $reviewBody = New-Object System.Windows.Forms.TableLayoutPanel
    $reviewBody.Dock = 'Fill'
    $reviewBody.ColumnCount = 2
    $reviewBody.RowCount = 1
    $reviewBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 68)) | Out-Null
    $reviewBody.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 32)) | Out-Null
    $reviewLayout.Controls.Add($reviewBody, 0, 1)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.MultiSelect = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = $surface
    $grid.BorderStyle = 'None'
    $grid.GridColor = [System.Drawing.Color]::FromArgb(224, 229, 232)
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(239, 243, 244)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $ink
    $grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(220, 236, 233)
    $grid.DefaultCellStyle.SelectionForeColor = $ink

    $selectedColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $selectedColumn.HeaderText = ''
    $selectedColumn.Width = 42
    $selectedColumn.Name = 'Selected'
    $grid.Columns.Add($selectedColumn) | Out-Null

    $nameColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $nameColumn.HeaderText = Get-QdfUiString -Key 'columnName' -DefaultValue 'Name'
    $nameColumn.Width = 180
    $nameColumn.ReadOnly = $true
    $grid.Columns.Add($nameColumn) | Out-Null

    $actionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $actionColumn.HeaderText = Get-QdfUiString -Key 'columnAction' -DefaultValue 'Action'
    $actionColumn.Width = 105
    $actionColumn.ReadOnly = $true
    $grid.Columns.Add($actionColumn) | Out-Null

    $riskColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $riskColumn.HeaderText = Get-QdfUiString -Key 'columnRisk' -DefaultValue 'Risk'
    $riskColumn.Width = 70
    $riskColumn.ReadOnly = $true
    $grid.Columns.Add($riskColumn) | Out-Null

    $sizeColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $sizeColumn.HeaderText = Get-QdfUiString -Key 'columnSize' -DefaultValue 'Size'
    $sizeColumn.Width = 90
    $sizeColumn.ReadOnly = $true
    $grid.Columns.Add($sizeColumn) | Out-Null

    $countColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $countColumn.HeaderText = Get-QdfUiString -Key 'columnFiles' -DefaultValue 'Files'
    $countColumn.Width = 65
    $countColumn.ReadOnly = $true
    $grid.Columns.Add($countColumn) | Out-Null

    $descriptionColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $descriptionColumn.HeaderText = Get-QdfUiString -Key 'columnDescription' -DefaultValue 'Description'
    $descriptionColumn.AutoSizeMode = 'Fill'
    $descriptionColumn.ReadOnly = $true
    $grid.Columns.Add($descriptionColumn) | Out-Null

    $reviewBody.Controls.Add($grid, 0, 0)

    $details = New-Object System.Windows.Forms.RichTextBox
    $details.Dock = 'Fill'
    $details.ReadOnly = $true
    $details.BorderStyle = 'None'
    $details.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 250)
    $details.ForeColor = $ink
    $details.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $details.WordWrap = $false
    $reviewBody.Controls.Add($details, 1, 0)

    $reviewButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $reviewButtons.Dock = 'Fill'
    $reviewButtons.FlowDirection = 'RightToLeft'
    $reviewButtons.Padding = New-QdfPadding -Left 0 -Top 10 -Right 0 -Bottom 0
    $reviewLayout.Controls.Add($reviewButtons, 0, 2)

    $cleanButton = New-Object System.Windows.Forms.Button
    $cleanButton.Text = Get-QdfUiString -Key 'cleanButton' -DefaultValue 'Clean'
    $cleanButton.Size = New-Object System.Drawing.Size(150, 38)
    $cleanButton.BackColor = $accent
    $cleanButton.ForeColor = [System.Drawing.Color]::White
    $cleanButton.FlatStyle = 'Flat'
    $cleanButton.FlatAppearance.BorderSize = 0
    $reviewButtons.Controls.Add($cleanButton)

    $backButton = New-Object System.Windows.Forms.Button
    $backButton.Text = Get-QdfUiString -Key 'backButton' -DefaultValue 'Back'
    $backButton.Size = New-Object System.Drawing.Size(100, 38)
    $backButton.FlatStyle = 'Flat'
    $backButton.BackColor = [System.Drawing.Color]::FromArgb(232, 236, 238)
    $backButton.ForeColor = $ink
    $reviewButtons.Controls.Add($backButton)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = Get-QdfUiString -Key 'refreshButton' -DefaultValue 'Rescan'
    $refreshButton.Size = New-Object System.Drawing.Size(110, 38)
    $refreshButton.FlatStyle = 'Flat'
    $refreshButton.BackColor = [System.Drawing.Color]::FromArgb(232, 236, 238)
    $refreshButton.ForeColor = $ink
    $reviewButtons.Controls.Add($refreshButton)

    $donePanel = New-Object System.Windows.Forms.Panel
    $donePanel.Dock = 'Fill'
    $donePanel.BackColor = $surface
    $donePanel.Visible = $false
    $donePanel.Padding = New-QdfPadding -Left 40 -Top 30 -Right 40 -Bottom 30
    $content.Controls.Add($donePanel)

    $doneHeading = New-Object System.Windows.Forms.Label
    $doneHeading.Text = Get-QdfUiString -Key 'doneHeading' -DefaultValue ''
    $doneHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
    $doneHeading.ForeColor = $ink
    $doneHeading.AutoSize = $true
    $doneHeading.Location = New-Object System.Drawing.Point(40, 36)
    $donePanel.Controls.Add($doneHeading)

    $doneText = New-Object System.Windows.Forms.RichTextBox
    $doneText.ReadOnly = $true
    $doneText.BorderStyle = 'None'
    $doneText.BackColor = $surface
    $doneText.ForeColor = $ink
    $doneText.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $doneText.Location = New-Object System.Drawing.Point(43, 96)
    $doneText.Size = New-Object System.Drawing.Size(800, 300)
    $doneText.Anchor = 'Top,Left,Right'
    $donePanel.Controls.Add($doneText)

    $doneButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $doneButtons.Dock = 'Bottom'
    $doneButtons.Height = 58
    $doneButtons.FlowDirection = 'RightToLeft'
    $doneButtons.Padding = New-QdfPadding -Left 0 -Top 10 -Right 0 -Bottom 0
    $donePanel.Controls.Add($doneButtons)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = Get-QdfUiString -Key 'closeButton' -DefaultValue 'Close'
    $closeButton.Size = New-Object System.Drawing.Size(110, 38)
    $closeButton.FlatStyle = 'Flat'
    $closeButton.BackColor = [System.Drawing.Color]::FromArgb(232, 236, 238)
    $closeButton.ForeColor = $ink
    $doneButtons.Controls.Add($closeButton)

    $recycleButton = New-Object System.Windows.Forms.Button
    $recycleButton.Text = Get-QdfUiString -Key 'openRecycleBin' -DefaultValue 'Recycle Bin'
    $recycleButton.Size = New-Object System.Drawing.Size(130, 38)
    $recycleButton.FlatStyle = 'Flat'
    $recycleButton.BackColor = [System.Drawing.Color]::FromArgb(232, 236, 238)
    $recycleButton.ForeColor = $ink
    $doneButtons.Controls.Add($recycleButton)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 350

    $script:QdfGuiState = @{
        Form = $form
        Content = $content
        ScanPanel = $scanPanel
        ReviewPanel = $reviewPanel
        DonePanel = $donePanel
        ScanStep = $scanStep
        ReviewStep = $reviewStep
        DoneStep = $doneStep
        ScanButton = $scanButton
        CancelButton = $cancelButton
        CleanButton = $cleanButton
        BackButton = $backButton
        CloseButton = $closeButton
        Grid = $grid
        Details = $details
        DoneText = $doneText
        StatusLabel = $statusLabel
        Timer = $timer
        Job = $null
        JobKind = ''
        LastScan = $null
        LastCleanResult = $null
    }

    if ($env:QDF_UI_RENDER_REVIEW -eq '1') {
        $fakeCategories = @(
            [pscustomobject]@{
                Id = 'fixture-cache'
                Name = 'Fixture cache'
                Description = 'Layout verification item.'
                Risk = 'safe'
                Action = 'delete'
                DefaultSelected = $true
                ItemCount = 12
                TotalSize = 1073741824
                TotalSizeText = '1.00 GB'
                DetailsTruncated = $false
                Files = @(
                    [pscustomobject]@{ Path = 'C:\Temp\fixture-one.tmp'; Size = 536870912 }
                )
            }
        )
        $fakeScan = [pscustomobject]@{
            Categories = $fakeCategories
            LargeFiles = @()
        }
        $script:QdfGuiState['LastScan'] = $fakeScan
        Update-QdfReviewGrid -Scan $fakeScan
    }

    $scanButton.Add_Click({
        Set-QdfStatus -Text (Get-QdfUiString -Key 'statusScanning' -DefaultValue 'Scanning')
        Start-QdfBackgroundJob -Kind 'scan'
    })

    $cancelButton.Add_Click({
        Stop-QdfBackgroundJob
    })

    $refreshButton.Add_Click({
        Start-QdfBackgroundJob -Kind 'scan'
    })

    $backButton.Add_Click({
        Set-QdfStage -Stage 'Scan'
    })

    $grid.Add_SelectionChanged({
        if ($script:QdfGuiState['Grid'].SelectedRows.Count -gt 0) {
            Show-QdfDetailsForRow -RowIndex $script:QdfGuiState['Grid'].SelectedRows[0].Index
        }
    })

    $cleanButton.Add_Click({
        $selectedIds = @(Get-QdfSelectedRuleIdsFromGrid)
        if ($selectedIds.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                (Get-QdfUiString -Key 'noRulesSelected' -DefaultValue ''),
                (Get-QdfUiString -Key 'confirmTitle' -DefaultValue 'Confirm'),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $permanentBytes = 0L
        $recycleBytes = 0L
        foreach ($row in $script:QdfGuiState['Grid'].Rows) {
            if ($row.Tag -eq '__large_files__' -or -not [bool]$row.Cells[0].Value) {
                continue
            }

            $category = $null
            foreach ($item in @($script:QdfGuiState['LastScan'].Categories)) {
                if ($item.Id -eq $row.Tag) {
                    $category = $item
                    break
                }
            }

            if ($null -eq $category) {
                continue
            }

            if ($category.Action -eq 'recycle') {
                $recycleBytes += [long]$category.TotalSize
            }
            else {
                $permanentBytes += [long]$category.TotalSize
            }
        }

        $message = @(
            (Get-QdfUiString -Key 'confirmQuestion' -DefaultValue ''),
            '',
            ('{0}: {1}' -f (Get-QdfUiString -Key 'confirmPermanent' -DefaultValue 'Delete'), (Format-QdfSize -Bytes $permanentBytes)),
            ('{0}: {1}' -f (Get-QdfUiString -Key 'confirmRecycle' -DefaultValue 'Recycle'), (Format-QdfSize -Bytes $recycleBytes))
        ) -join [Environment]::NewLine

        $answer = [System.Windows.Forms.MessageBox]::Show(
            $message,
            (Get-QdfUiString -Key 'confirmTitle' -DefaultValue 'Confirm'),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-QdfBackgroundJob -Kind 'clean' -RuleIds $selectedIds
        }
    })

    $closeButton.Add_Click({
        $script:QdfGuiState['Form'].Close()
    })

    $recycleButton.Add_Click({
        Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:RecycleBinFolder'
    })

    $timer.Add_Tick({
        $job = $script:QdfGuiState['Job']
        if ($null -eq $job) {
            return
        }

        if ($job.State -eq 'Completed') {
            Complete-QdfBackgroundJob
        }
        elseif ($job.State -eq 'Failed') {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            Show-QdfError -Message $reason.Message
            Stop-QdfBackgroundJob
        }
        elseif ($job.State -eq 'Stopped') {
            Stop-QdfBackgroundJob
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)

        if ($null -ne $script:QdfGuiState['Job']) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                (Get-QdfUiString -Key 'runningTaskClosePrompt' -DefaultValue 'A task is still running.'),
                (Get-QdfUiString -Key 'appTitle' -DefaultValue 'QingDaoFu'),
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )

            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                $eventArgs.Cancel = $true
                return
            }

            Stop-QdfBackgroundJob
        }
    })

    $timer.Start()
    if ($env:QDF_UI_RENDER_REVIEW -eq '1') {
        Set-QdfStage -Stage 'Review'
    }
    else {
        Set-QdfStage -Stage 'Scan'
    }
    Set-QdfStatus -Text (Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready')

    if (-not [string]::IsNullOrWhiteSpace($env:QDF_UI_RENDER_PATH)) {
        $script:QdfSmokeTimer = New-Object System.Windows.Forms.Timer
        $script:QdfSmokeTimer.Interval = 1200
        $script:QdfSmokeTimer.Add_Tick({
            $script:QdfSmokeTimer.Stop()
            $formToRender = $script:QdfGuiState['Form']
            $bitmap = New-Object System.Drawing.Bitmap($formToRender.Width, $formToRender.Height)
            $rectangle = New-Object System.Drawing.Rectangle(0, 0, $formToRender.Width, $formToRender.Height)
            $formToRender.DrawToBitmap($bitmap, $rectangle)
            $bitmap.Save($env:QDF_UI_RENDER_PATH, [System.Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Dispose()
            $formToRender.Close()
        })
        $script:QdfSmokeTimer.Start()
    }
    elseif ($env:QDF_UI_SMOKE_TEST -eq '1') {
        $script:QdfSmokeTimer = New-Object System.Windows.Forms.Timer
        $script:QdfSmokeTimer.Interval = 1200
        $script:QdfSmokeTimer.Add_Tick({
            $script:QdfSmokeTimer.Stop()
            $script:QdfGuiState['Form'].Close()
        })
        $script:QdfSmokeTimer.Start()
    }

    [System.Windows.Forms.Application]::Run($form)
    $timer.Stop()
    $timer.Dispose()
    if ($null -ne $script:QdfSmokeTimer) {
        $script:QdfSmokeTimer.Dispose()
        $script:QdfSmokeTimer = $null
    }
}
