function Get-QdfCategoryById {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Categories,

        [Parameter(Mandatory = $true)]
        [string]$CategoryId
    )

    foreach ($category in $Categories) {
        if ([string]::Equals([string]$category.Id, $CategoryId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $category
        }
    }

    return $null
}

function Get-QdfResourceImage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $path = Join-Path (Join-Path $script:QdfAssetRoot 'arcade-console') $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Asset not found: $path"
    }

    return [System.Drawing.Image]::FromFile($path)
}

function New-QdfStepIndicator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$Color
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 10, 28, 0
    $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $label.ForeColor = $Color
    $label.Padding = New-QdfPadding -Left 10 -Top 0 -Right 0 -Bottom 0
    return $label
}

function New-QdfFlatButton {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [System.Drawing.Size]$Size,

        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$BackColor,

        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$ForeColor,

        [System.Drawing.Image]$Image = $null,

        [int]$FontSize = 11,

        [bool]$Bold = $true
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = $Size
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.Font = New-Object System.Drawing.Font(
        'Microsoft YaHei UI',
        $FontSize,
        $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular })
    )
    if ($null -ne $Image) {
        $button.BackgroundImage = $Image
        $button.BackgroundImageLayout = 'Stretch'
    }
    return $button
}

function New-QdfCartridgePanel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Category,

        [Parameter(Mandatory = $true)]
        [scriptblock]$OnSelectionChanged
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Tag = [string]$Category.Id
    $panel.Size = New-Object System.Drawing.Size(260, 240)
    $panel.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 8, 8, 8, 8
    $panel.BackColor = [System.Drawing.Color]::FromArgb(238, 238, 232)
    $panel.BackgroundImage = Get-QdfResourceImage -Name 'cartridge-surface.png'
    $panel.BackgroundImageLayout = 'Stretch'
    $panel.Cursor = 'Hand'
    $panel.Padding = New-QdfPadding -Left 14 -Top 12 -Right 14 -Bottom 12

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = [string]$Category.Name
    $nameLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $nameLabel.ForeColor = [System.Drawing.Color]::FromArgb(28, 35, 40)
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object System.Drawing.Point(16, 14)
    $nameLabel.MaximumSize = New-Object System.Drawing.Size(220, 0)
    $panel.Controls.Add($nameLabel)

    $sizeLabel = New-Object System.Windows.Forms.Label
    $sizeLabel.Text = ('{0} | {1}' -f $category.TotalSizeText, $category.ItemCount)
    $sizeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $sizeLabel.ForeColor = [System.Drawing.Color]::FromArgb(66, 72, 78)
    $sizeLabel.AutoSize = $true
    $sizeLabel.Location = New-Object System.Drawing.Point(18, 46)
    $panel.Controls.Add($sizeLabel)

    $riskLabel = New-Object System.Windows.Forms.Label
    $riskLabel.Text = Get-QdfRiskText -Risk $category.Risk
    $riskLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $riskLabel.ForeColor = [System.Drawing.Color]::FromArgb(23, 107, 99)
    $riskLabel.AutoSize = $true
    $riskLabel.Location = New-Object System.Drawing.Point(18, 70)
    $panel.Controls.Add($riskLabel)

    $descriptionLabel = New-Object System.Windows.Forms.Label
    $descriptionLabel.Text = [string]$Category.Description
    $descriptionLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $descriptionLabel.ForeColor = [System.Drawing.Color]::FromArgb(102, 112, 122)
    $descriptionLabel.Location = New-Object System.Drawing.Point(16, 96)
    $descriptionLabel.Size = New-Object System.Drawing.Size(226, 64)
    $panel.Controls.Add($descriptionLabel)

    $toggle = New-Object System.Windows.Forms.CheckBox
    $toggle.Appearance = 'Button'
    $toggle.Text = ''
    $toggle.Checked = [bool]$Category.DefaultSelected
    $toggle.Enabled = ($category.Action -ne 'readonly')
    $toggle.Size = New-Object System.Drawing.Size(60, 26)
    $toggle.Location = New-Object System.Drawing.Point(16, 168)
    $toggle.FlatStyle = 'Flat'
    $toggle.FlatAppearance.BorderSize = 0
    $toggle.BackColor = [System.Drawing.Color]::FromArgb(23, 107, 99)
    $panel.Controls.Add($toggle)

    $actionLabel = New-Object System.Windows.Forms.Label
    $actionLabel.Text = Get-QdfActionText -Action $category.Action
    $actionLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $actionLabel.ForeColor = [System.Drawing.Color]::FromArgb(122, 132, 140)
    $actionLabel.AutoSize = $true
    $actionLabel.Location = New-Object System.Drawing.Point(86, 174)
    $panel.Controls.Add($actionLabel)

    $panel.Add_Click({
        param($sender, $eventArgs)
        Show-QdfDetailsForCategory -CategoryId ([string]$sender.Tag)
    })

    $nameLabel.Add_Click({
        param($sender, $eventArgs)
        $parent = $sender.Parent
        if ($null -ne $parent) {
            Show-QdfDetailsForCategory -CategoryId ([string]$parent.Tag)
        }
    })

    $toggle.Add_Click({
        param($sender, $eventArgs)
        & $OnSelectionChanged
    })

    return [pscustomobject]@{
        Panel = $panel
        Toggle = $toggle
    }
}

function Update-QdfTargetSummary {
    $state = $script:QdfGuiState
    if ($null -eq $state['LastScan']) {
        return
    }

    $permanentBytes = 0L
    $recycleBytes = 0L
    foreach ($category in @($state['LastScan'].Categories)) {
        $id = [string]$category.Id
        if (-not $state['CategoryToggles'].ContainsKey($id)) {
            continue
        }

        $toggle = $state['CategoryToggles'][$id]
        if (-not $toggle.Checked) {
            continue
        }

        if ($category.Action -eq 'recycle') {
            $recycleBytes += [long]$category.TotalSize
        }
        else {
            $permanentBytes += [long]$category.TotalSize
        }
    }

    $state['PermanentSummaryLabel'].Text = Format-QdfSize -Bytes $permanentBytes
    $state['RecycleSummaryLabel'].Text = Format-QdfSize -Bytes $recycleBytes
}

function Show-QdfDetailsForCategory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CategoryId
    )

    $state = $script:QdfGuiState
    if ($null -eq $state['LastScan']) {
        return
    }

    $category = Get-QdfCategoryById -Categories @($state['LastScan'].Categories) -CategoryId $CategoryId
    if ($null -eq $category) {
        $state['Details'].Text = ''
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($category.Description)
    $lines.Add('')
    $lines.Add(('处理方式: {0} | 风险: {1}' -f (Get-QdfActionText -Action $category.Action), (Get-QdfRiskText -Risk $category.Risk)))
    $lines.Add('')
    foreach ($file in @($category.Files | Select-Object -First 120)) {
        $lines.Add(('[{0}] {1}' -f (Format-QdfSize -Bytes ([long]$file.Size)), $file.Path))
    }

    if ($category.DetailsTruncated) {
        $lines.Add('')
        $lines.Add(('Only the first 120 paths are shown. Total: {0}' -f $category.ItemCount))
    }

    $state['Details'].Text = ($lines -join [Environment]::NewLine)
}

function Update-QdfReviewGrid {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scan
    )

    $state = $script:QdfGuiState
    $rack = $state['RackPanel']
    $rack.Controls.Clear()
    $state['CategoryToggles'] = @{}

    foreach ($category in @($Scan.Categories)) {
        $panel = New-QdfCartridgePanel -Category $category -OnSelectionChanged {
            Update-QdfTargetSummary
        }
        $state['CategoryToggles'][$category.Id] = $panel.Toggle
        $rack.Controls.Add($panel.Panel)
    }

    if (@($Scan.LargeFiles).Count -gt 0) {
        $largeSize = 0L
        foreach ($file in @($Scan.LargeFiles)) {
            $largeSize += [long]$file.Size
        }

        $readonlyPanel = New-Object System.Windows.Forms.Panel
        $readonlyPanel.Size = New-Object System.Drawing.Size(260, 108)
        $readonlyPanel.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 8, 8, 8, 8
        $readonlyPanel.BackColor = [System.Drawing.Color]::FromArgb(232, 238, 240)

        $readonlyTitle = New-Object System.Windows.Forms.Label
        $readonlyTitle.Text = Get-QdfUiString -Key 'largeFilesHeading' -DefaultValue 'Large files'
        $readonlyTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
        $readonlyTitle.AutoSize = $true
        $readonlyTitle.Location = New-Object System.Drawing.Point(14, 12)
        $readonlyPanel.Controls.Add($readonlyTitle)

        $readonlySummary = New-Object System.Windows.Forms.Label
        $readonlySummary.Text = ('{0} | {1}' -f @($Scan.LargeFiles).Count, (Format-QdfSize -Bytes $largeSize))
        $readonlySummary.ForeColor = [System.Drawing.Color]::FromArgb(102, 112, 122)
        $readonlySummary.AutoSize = $true
        $readonlySummary.Location = New-Object System.Drawing.Point(14, 42)
        $readonlyPanel.Controls.Add($readonlySummary)

        $readonlyHint = New-Object System.Windows.Forms.Label
        $readonlyHint.Text = Get-QdfUiString -Key 'largeFilesDescription' -DefaultValue ''
        $readonlyHint.ForeColor = [System.Drawing.Color]::FromArgb(102, 112, 122)
        $readonlyHint.AutoSize = $false
        $readonlyHint.Size = New-Object System.Drawing.Size(228, 38)
        $readonlyHint.Location = New-Object System.Drawing.Point(14, 66)
        $readonlyPanel.Controls.Add($readonlyHint)

        $rack.Controls.Add($readonlyPanel)
    }

    if (@($Scan.Categories).Count -gt 0) {
        $firstCategory = @($Scan.Categories)[0]
        Show-QdfDetailsForCategory -CategoryId ([string]$firstCategory.Id)
    }
    else {
        $state['Details'].Text = Get-QdfUiString -Key 'noItems' -DefaultValue ''
    }

    Update-QdfTargetSummary
}

function Get-QdfSelectedRuleIdsFromGrid {
    $state = $script:QdfGuiState
    $ids = New-Object System.Collections.Generic.List[string]

    if ($null -eq $state['CategoryToggles']) {
        return @()
    }

    foreach ($key in @($state['CategoryToggles'].Keys)) {
        $toggle = $state['CategoryToggles'][$key]
        if ($toggle.Checked) {
            $ids.Add([string]$key)
        }
    }

    return @($ids)
}

function Show-QdfMainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $appTitle = Get-QdfUiString -Key 'appTitle' -DefaultValue 'QingDaoFu'
    $metal = [System.Drawing.Color]::FromArgb(33, 38, 42)
    $surface = [System.Drawing.Color]::FromArgb(23, 27, 30)
    $ink = [System.Drawing.Color]::White
    $muted = [System.Drawing.Color]::FromArgb(164, 174, 180)
    $accent = [System.Drawing.Color]::FromArgb(23, 107, 99)
    $warning = [System.Drawing.Color]::FromArgb(196, 70, 43)
    $neutral = [System.Drawing.Color]::FromArgb(64, 71, 78)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $appTitle
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(1080, 740)
    $form.Size = New-Object System.Drawing.Size(1180, 820)
    $form.BackColor = $metal
    $form.ForeColor = $ink
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.BackgroundImage = Get-QdfResourceImage -Name 'console-metal-texture.png'
    $form.BackgroundImageLayout = 'Stretch'

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 98
    $header.BackColor = $surface
    $header.Padding = New-QdfPadding -Left 22 -Top 14 -Right 22 -Bottom 8
    $form.Controls.Add($header)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $appTitle
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $ink
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(22, 14)
    $header.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = Get-QdfUiString -Key 'appSubtitle' -DefaultValue ''
    $subtitleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $subtitleLabel.ForeColor = $muted
    $subtitleLabel.AutoSize = $true
    $subtitleLabel.Location = New-Object System.Drawing.Point(24, 58)
    $header.Controls.Add($subtitleLabel)

    $stepPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $stepPanel.FlowDirection = 'LeftToRight'
    $stepPanel.AutoSize = $true
    $stepPanel.Location = New-Object System.Drawing.Point(520, 22)
    $header.Controls.Add($stepPanel)

    $scanStep = New-Object System.Windows.Forms.Label
    $scanStep.Text = Get-QdfUiString -Key 'stepScan' -DefaultValue '1. Scan'
    $scanStep.ForeColor = $accent
    $scanStep.AutoSize = $true
    $scanStep.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 8, 24, 0
    $scanStep.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $stepPanel.Controls.Add($scanStep)

    $reviewStep = New-Object System.Windows.Forms.Label
    $reviewStep.Text = Get-QdfUiString -Key 'stepReview' -DefaultValue '2. Review'
    $reviewStep.ForeColor = $muted
    $reviewStep.AutoSize = $true
    $reviewStep.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 8, 24, 0
    $reviewStep.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $stepPanel.Controls.Add($reviewStep)

    $doneStep = New-Object System.Windows.Forms.Label
    $doneStep.Text = Get-QdfUiString -Key 'stepDone' -DefaultValue '3. Done'
    $doneStep.ForeColor = $muted
    $doneStep.AutoSize = $true
    $doneStep.Margin = New-Object System.Windows.Forms.Padding -ArgumentList 0, 8, 0, 0
    $doneStep.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $stepPanel.Controls.Add($doneStep)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready'
    $statusStrip.Items.Add($statusLabel) | Out-Null
    $form.Controls.Add($statusStrip)

    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = 'Fill'
    $content.Padding = New-QdfPadding -Left 18 -Top 14 -Right 18 -Bottom 14
    $content.BackColor = [System.Drawing.Color]::Transparent
    $form.Controls.Add($content)
    $content.BringToFront()

    # Scan stage
    $scanPanel = New-Object System.Windows.Forms.Panel
    $scanPanel.Dock = 'Fill'
    $scanPanel.BackColor = [System.Drawing.Color]::Transparent
    $content.Controls.Add($scanPanel)

    $scanCenter = New-Object System.Windows.Forms.TableLayoutPanel
    $scanCenter.Dock = 'Fill'
    $scanCenter.ColumnCount = 1
    $scanCenter.RowCount = 3
    $scanCenter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 30)) | Out-Null
    $scanCenter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $scanCenter.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 70)) | Out-Null
    $scanPanel.Controls.Add($scanCenter)

    $scanHeading = New-Object System.Windows.Forms.Label
    $scanHeading.Text = Get-QdfUiString -Key 'scanHeading' -DefaultValue ''
    $scanHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
    $scanHeading.ForeColor = $ink
    $scanHeading.AutoSize = $true
    $scanCenter.Controls.Add($scanHeading, 0, 0)
    $scanCenter.SetColumnSpan($scanHeading, 1)

    $scanDescription = New-Object System.Windows.Forms.Label
    $scanDescription.Text = Get-QdfUiString -Key 'scanDescription' -DefaultValue ''
    $scanDescription.ForeColor = $muted
    $scanDescription.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12)
    $scanDescription.AutoSize = $true
    $scanCenter.Controls.Add($scanDescription, 0, 1)

    $scanButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $scanButtons.FlowDirection = 'LeftToRight'
    $scanButtons.AutoSize = $true
    $scanCenter.Controls.Add($scanButtons, 0, 2)

    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = Get-QdfUiString -Key 'scanButton' -DefaultValue 'Scan'
    $scanButton.Size = New-Object System.Drawing.Size(260, 84)
    $scanButton.BackColor = $accent
    $scanButton.ForeColor = $ink
    $scanButton.FlatStyle = 'Flat'
    $scanButton.FlatAppearance.BorderSize = 0
    $scanButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $scanButtons.Controls.Add($scanButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = Get-QdfUiString -Key 'cancelScan' -DefaultValue 'Cancel'
    $cancelButton.Size = New-Object System.Drawing.Size(150, 84)
    $cancelButton.BackColor = $neutral
    $cancelButton.ForeColor = $ink
    $cancelButton.FlatStyle = 'Flat'
    $cancelButton.FlatAppearance.BorderSize = 0
    $cancelButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $cancelButton.Enabled = $false
    $scanButtons.Controls.Add($cancelButton)

    # Review stage
    $reviewPanel = New-Object System.Windows.Forms.Panel
    $reviewPanel.Dock = 'Fill'
    $reviewPanel.BackColor = [System.Drawing.Color]::Transparent
    $reviewPanel.Visible = $false
    $content.Controls.Add($reviewPanel)

    $reviewRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $reviewRoot.Dock = 'Fill'
    $reviewRoot.ColumnCount = 2
    $reviewRoot.RowCount = 2
    $reviewRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 72)) | Out-Null
    $reviewRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 28)) | Out-Null
    $reviewRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 72)) | Out-Null
    $reviewRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $reviewPanel.Controls.Add($reviewRoot)

    $reviewHeader = New-Object System.Windows.Forms.Panel
    $reviewHeader.Dock = 'Fill'
    $reviewHeader.BackColor = [System.Drawing.Color]::Transparent
    $reviewRoot.Controls.Add($reviewHeader, 0, 0)
    $reviewRoot.SetColumnSpan($reviewHeader, 2)

    $reviewHeading = New-Object System.Windows.Forms.Label
    $reviewHeading.Text = Get-QdfUiString -Key 'reviewHeading' -DefaultValue ''
    $reviewHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
    $reviewHeading.ForeColor = $ink
    $reviewHeading.AutoSize = $true
    $reviewHeading.Location = New-Object System.Drawing.Point(4, 8)
    $reviewHeader.Controls.Add($reviewHeading)

    $reviewDescription = New-Object System.Windows.Forms.Label
    $reviewDescription.Text = Get-QdfUiString -Key 'reviewDescription' -DefaultValue ''
    $reviewDescription.ForeColor = $muted
    $reviewDescription.AutoSize = $true
    $reviewDescription.Location = New-Object System.Drawing.Point(6, 40)
    $reviewHeader.Controls.Add($reviewDescription)

    $reviewBody = New-Object System.Windows.Forms.TableLayoutPanel
    $reviewBody.Dock = 'Fill'
    $reviewBody.ColumnCount = 1
    $reviewBody.RowCount = 2
    $reviewBody.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $reviewBody.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 150)) | Out-Null
    $reviewRoot.Controls.Add($reviewBody, 0, 1)

    $rackScroll = New-Object System.Windows.Forms.Panel
    $rackScroll.Dock = 'Fill'
    $rackScroll.AutoScroll = $true
    $rackScroll.BackColor = [System.Drawing.Color]::Transparent
    $reviewBody.Controls.Add($rackScroll, 0, 0)

    $rackPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $rackPanel.Dock = 'Top'
    $rackPanel.AutoScroll = $false
    $rackPanel.WrapContents = $true
    $rackPanel.FlowDirection = 'LeftToRight'
    $rackPanel.AutoSize = $false
    $rackPanel.Height = 1000
    $rackPanel.Width = 800
    $rackScroll.Controls.Add($rackPanel)

    $details = New-Object System.Windows.Forms.RichTextBox
    $details.Dock = 'Fill'
    $details.ReadOnly = $true
    $details.BorderStyle = 'None'
    $details.BackColor = [System.Drawing.Color]::FromArgb(38, 45, 50)
    $details.ForeColor = $ink
    $details.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $details.WordWrap = $true
    $reviewBody.Controls.Add($details, 0, 1)

    $rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $rightPanel.Dock = 'Fill'
    $rightPanel.ColumnCount = 1
    $rightPanel.RowCount = 4
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 280)) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 92)) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 92)) | Out-Null
    $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $reviewRoot.Controls.Add($rightPanel, 1, 1)

    $leverTexture = Get-QdfResourceImage -Name 'lever-red-surface.png'
    $cleanButton = New-Object System.Windows.Forms.Button
    $cleanButton.Text = Get-QdfUiString -Key 'cleanButton' -DefaultValue 'Clean'
    $cleanButton.Size = New-Object System.Drawing.Size(260, 200)
    $cleanButton.BackColor = $warning
    $cleanButton.ForeColor = $ink
    $cleanButton.FlatStyle = 'Flat'
    $cleanButton.FlatAppearance.BorderSize = 0
    $cleanButton.BackgroundImage = $leverTexture
    $cleanButton.BackgroundImageLayout = 'Stretch'
    $cleanButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $rightPanel.Controls.Add($cleanButton, 0, 0)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = Get-QdfUiString -Key 'refreshButton' -DefaultValue 'Rescan'
    $refreshButton.Size = New-Object System.Drawing.Size(260, 68)
    $refreshButton.BackColor = $accent
    $refreshButton.ForeColor = $ink
    $refreshButton.FlatStyle = 'Flat'
    $refreshButton.FlatAppearance.BorderSize = 0
    $refreshButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $rightPanel.Controls.Add($refreshButton, 0, 1)

    $backButton = New-Object System.Windows.Forms.Button
    $backButton.Text = Get-QdfUiString -Key 'backButton' -DefaultValue 'Back'
    $backButton.Size = New-Object System.Drawing.Size(260, 68)
    $backButton.BackColor = $neutral
    $backButton.ForeColor = $ink
    $backButton.FlatStyle = 'Flat'
    $backButton.FlatAppearance.BorderSize = 0
    $backButton.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $rightPanel.Controls.Add($backButton, 0, 2)

    $targetSummary = New-Object System.Windows.Forms.TableLayoutPanel
    $targetSummary.Dock = 'Fill'
    $targetSummary.ColumnCount = 1
    $targetSummary.RowCount = 2
    $targetSummary.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 50)) | Out-Null
    $targetSummary.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 50)) | Out-Null
    $rightPanel.Controls.Add($targetSummary, 0, 3)

    $permanentSummary = New-Object System.Windows.Forms.Panel
    $permanentSummary.Dock = 'Fill'
    $permanentSummary.BackColor = [System.Drawing.Color]::FromArgb(48, 56, 62)
    $permanentSummary.Margin = New-QdfPadding -Left 0 -Top 8 -Right 0 -Bottom 6
    $targetSummary.Controls.Add($permanentSummary, 0, 0)

    $permanentTitle = New-Object System.Windows.Forms.Label
    $permanentTitle.Text = Get-QdfUiString -Key 'confirmPermanent' -DefaultValue 'Delete'
    $permanentTitle.ForeColor = $muted
    $permanentTitle.AutoSize = $true
    $permanentTitle.Location = New-Object System.Drawing.Point(14, 14)
    $permanentSummary.Controls.Add($permanentTitle)

    $permanentSummaryLabel = New-Object System.Windows.Forms.Label
    $permanentSummaryLabel.Text = '0 B'
    $permanentSummaryLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $permanentSummaryLabel.ForeColor = $ink
    $permanentSummaryLabel.AutoSize = $true
    $permanentSummaryLabel.Location = New-Object System.Drawing.Point(14, 36)
    $permanentSummary.Controls.Add($permanentSummaryLabel)

    $recycleSummary = New-Object System.Windows.Forms.Panel
    $recycleSummary.Dock = 'Fill'
    $recycleSummary.BackColor = [System.Drawing.Color]::FromArgb(48, 56, 62)
    $recycleSummary.Margin = New-QdfPadding -Left 0 -Top 6 -Right 0 -Bottom 0
    $targetSummary.Controls.Add($recycleSummary, 0, 1)

    $recycleTitle = New-Object System.Windows.Forms.Label
    $recycleTitle.Text = Get-QdfUiString -Key 'confirmRecycle' -DefaultValue 'Recycle'
    $recycleTitle.ForeColor = $muted
    $recycleTitle.AutoSize = $true
    $recycleTitle.Location = New-Object System.Drawing.Point(14, 14)
    $recycleSummary.Controls.Add($recycleTitle)

    $recycleSummaryLabel = New-Object System.Windows.Forms.Label
    $recycleSummaryLabel.Text = '0 B'
    $recycleSummaryLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $recycleSummaryLabel.ForeColor = $ink
    $recycleSummaryLabel.AutoSize = $true
    $recycleSummaryLabel.Location = New-Object System.Drawing.Point(14, 36)
    $recycleSummary.Controls.Add($recycleSummaryLabel)

    # Done stage
    $donePanel = New-Object System.Windows.Forms.Panel
    $donePanel.Dock = 'Fill'
    $donePanel.BackColor = [System.Drawing.Color]::Transparent
    $donePanel.Visible = $false
    $content.Controls.Add($donePanel)

    $doneRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $doneRoot.Dock = 'Fill'
    $doneRoot.ColumnCount = 1
    $doneRoot.RowCount = 3
    $doneRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 86)) | Out-Null
    $doneRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $doneRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 72)) | Out-Null
    $donePanel.Controls.Add($doneRoot)

    $doneHeading = New-Object System.Windows.Forms.Label
    $doneHeading.Text = Get-QdfUiString -Key 'doneHeading' -DefaultValue ''
    $doneHeading.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 20, [System.Drawing.FontStyle]::Bold)
    $doneHeading.ForeColor = $ink
    $doneHeading.AutoSize = $true
    $doneHeading.Location = New-Object System.Drawing.Point(6, 16)
    $doneRoot.Controls.Add($doneHeading, 0, 0)

    $doneText = New-Object System.Windows.Forms.RichTextBox
    $doneText.ReadOnly = $true
    $doneText.BorderStyle = 'None'
    $doneText.BackColor = [System.Drawing.Color]::FromArgb(38, 45, 50)
    $doneText.ForeColor = $ink
    $doneText.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $doneRoot.Controls.Add($doneText, 0, 1)

    $doneButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $doneButtons.Dock = 'Fill'
    $doneButtons.FlowDirection = 'RightToLeft'
    $doneRoot.Controls.Add($doneButtons, 0, 2)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = Get-QdfUiString -Key 'closeButton' -DefaultValue 'Close'
    $closeButton.Size = New-Object System.Drawing.Size(120, 44)
    $closeButton.BackColor = $neutral
    $closeButton.ForeColor = $ink
    $closeButton.FlatStyle = 'Flat'
    $closeButton.FlatAppearance.BorderSize = 0
    $doneButtons.Controls.Add($closeButton)

    $recycleButton = New-Object System.Windows.Forms.Button
    $recycleButton.Text = Get-QdfUiString -Key 'openRecycleBin' -DefaultValue 'Recycle Bin'
    $recycleButton.Size = New-Object System.Drawing.Size(150, 44)
    $recycleButton.BackColor = $accent
    $recycleButton.ForeColor = $ink
    $recycleButton.FlatStyle = 'Flat'
    $recycleButton.FlatAppearance.BorderSize = 0
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
        RackPanel = $rackPanel
        Details = $details
        DoneText = $doneText
        StatusLabel = $statusLabel
        Timer = $timer
        Job = $null
        JobKind = ''
        LastScan = $null
        LastCleanResult = $null
        CategoryToggles = @{}
        PermanentSummaryLabel = $permanentSummaryLabel
        RecycleSummaryLabel = $recycleSummaryLabel
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
        foreach ($category in @($script:QdfGuiState['LastScan'].Categories)) {
            if (-not $script:QdfGuiState['CategoryToggles'].ContainsKey($category.Id)) {
                continue
            }

            $toggle = $script:QdfGuiState['CategoryToggles'][$category.Id]
            if (-not $toggle.Checked) {
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
    Set-QdfStage -Stage 'Scan'
    Set-QdfStatus -Text (Get-QdfUiString -Key 'statusReady' -DefaultValue 'Ready')

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
        Set-QdfStage -Stage 'Review'
    }

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
