# CloudSync.ps1
# Standalone Cloud Sync review window. The user opens this from the MSE2 menu bar,
# reviews what will change, ticks the confirmation checkbox, then clicks Sync Now.
# Sync Now writes decisions to a temp file and launches SyncNow.ps1 -SkipPreview.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.Web.Extensions

try {
    $appData  = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"
    $gitExe   = "$appData\mingit\cmd\git.exe"
    $syncScript = "$appData\SyncEngine\SyncNow.ps1"
    . "$appData\SyncEngine\DedupManager.ps1"   # Delete Duplicates helpers
    $env:GIT_TERMINAL_PROMPT = "0"
    $env:GIT_ASKPASS         = "echo"

    $p1 = "ghp_2g4dOrh3klYwVMo6o"
    $p2 = "FNfD8iUKfATTq3ezyS4"
    $remoteUrl = "https://basscosauce-beep:$p1$p2@github.com/basscosauce-beep/MSE2-Shared-Editor.git"

    # Read local user name
    $creatorFile = "$appData\creator.txt"
    $myName = if (Test-Path $creatorFile) { (Get-Content $creatorFile -Raw).Trim() } else { "Unknown" }
    $safeUser = $myName -replace '[\\/:*?"<>|]', '_'

    # Find set file (exclude backups)
    $setFile = Get-ChildItem "$appData\Shared-Set" -Recurse -Filter "*.mse-set" |
        Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*\_pre_sync_backups\*" } |
        Select-Object -First 1
    if (-not $setFile) { throw "Could not find the shared set file." }

    $setDir      = $setFile.DirectoryName
    $draftFile   = "$setDir\draft_cards_${safeUser}.txt"
    $tombstoneFile = "$setDir\deleted_cards.txt"

    # =========================================================================
    # XAML
    # =========================================================================
    $xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Cloud Sync" Height="720" Width="660"
        WindowStartupLocation="CenterScreen" Background="#0A0A14" Foreground="White">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Background" Value="#111124"/>
      <Setter Property="Foreground" Value="#888"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4,4,0,0" Margin="0,0,2,0">
              <ContentPresenter ContentSource="Header" Margin="14,5"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2563EB"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E2A4A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#0F1629" Padding="20,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Name="TitleText" Text="Cloud Sync" FontSize="20" FontWeight="Bold" Foreground="#60A5FA"/>
          <TextBlock Name="SetNameText" Text="Loading..." FontSize="11" Foreground="#555" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Name="LastCheckedText" Text="" Foreground="#555" FontSize="11" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <Button Name="BtnRefresh" Content="Refresh" Background="#1E293B"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Summary bar -->
    <Border Grid.Row="1" Background="#0C1022" Padding="20,9" Name="SummaryBar">
      <StackPanel Name="SummaryPanel" Orientation="Horizontal"/>
    </Border>

    <!-- Tabs -->
    <TabControl Grid.Row="2" Name="Tabs" Background="#0A0A14" BorderThickness="0" Padding="0">
      <TabItem Header="Changes" Name="TabChanges">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,8,16,8">
          <StackPanel Name="CardList"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="History" Name="TabHistory">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,8,16,8">
          <StackPanel Name="HistoryList"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Import Set" Name="TabImport">
        <Grid Margin="16,10,16,10">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,8">
            <TextBlock Text="Source .mse-set file:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="12"/>
            <TextBox Name="ImportPathBox" Width="310" IsReadOnly="True"
                     Background="#0F1629" Foreground="#9CA3AF" Padding="6,4"
                     VerticalAlignment="Center" FontSize="11" BorderBrush="#374151"/>
            <Button Name="BtnBrowse" Content="Browse..." Margin="8,0,0,0"
                    Background="#1E3A5F" Foreground="White" Padding="12,5" FontSize="12"/>
          </StackPanel>
          <TextBlock Name="ImportStatusText" Grid.Row="1" Foreground="#6B7280"
                     FontSize="11" Margin="0,0,0,8" TextWrapping="Wrap"/>
          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
            <StackPanel Name="ImportList"/>
          </ScrollViewer>
          <Button Name="BtnImport" Grid.Row="3"
                  Content="Import Cards into Shared Set" Margin="0,10,0,0"
                  Background="#1D4ED8" Foreground="#666" FontWeight="Bold" FontSize="13"
                  Padding="18,9" HorizontalAlignment="Right" IsEnabled="False"/>
        </Grid>
      </TabItem>
    </TabControl>

    <!-- Footer -->
    <Border Grid.Row="3" Background="#0F1629" Padding="20,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <CheckBox Name="ChkReviewed" Grid.Column="0" VerticalAlignment="Center"
                  Content="I have reviewed all changes above" IsEnabled="False"/>
        <Button Name="BtnSync" Grid.Column="1" Content="Sync Now" IsEnabled="False"
                Background="#1E3A1E" Foreground="#666" FontWeight="Bold" FontSize="14"
                Padding="24,10"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $xaml   = [xml]$xamlStr
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $titleText      = $window.FindName("TitleText")
    $setNameText    = $window.FindName("SetNameText")
    $lastCheckedText= $window.FindName("LastCheckedText")
    $summaryPanel   = $window.FindName("SummaryPanel")
    $cardList       = $window.FindName("CardList")
    $historyList    = $window.FindName("HistoryList")
    $chkReviewed    = $window.FindName("ChkReviewed")
    $btnSync        = $window.FindName("BtnSync")
    $btnRefresh     = $window.FindName("BtnRefresh")
    $summaryBar     = $window.FindName("SummaryBar")

    # Import tab controls
    $importPathBox    = $window.FindName("ImportPathBox")
    $btnBrowse        = $window.FindName("BtnBrowse")
    $importStatusText = $window.FindName("ImportStatusText")
    $importList       = $window.FindName("ImportList")
    $btnImport        = $window.FindName("BtnImport")

    $window.Title    = "Cloud Sync"
    $setNameText.Text = $setFile.BaseName

    $conv = New-Object System.Windows.Media.BrushConverter

    # State shared across scan/sync -- defined at outer scope so all functions can reach them
    $commitMap  = $null
    $mergedMap  = $null
    $cloudMap   = $null
    $hasChanges = $false

    # Import tab state
    $script:importCards = $null  # array of @{Block=<text>; Name=<string>; Status="ADD"|"OVERRIDE"}

    # =========================================================================
    # IMPORT TAB LOGIC
    # =========================================================================
    # Helper: get the 'name:' field from a card block
    function Get-ImportCardName([string]$block) {
        if ($block -match "(?m)^\s*name:\s*(.+)") { return $matches[1].Trim() }
        return ""
    }

    # Build a name->block map from local shared set text
    function Get-NameMap([string]$content) {
        $map = [System.Collections.Specialized.OrderedDictionary]::new()
        $content -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
            $block = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            $name  = Get-ImportCardName $block
            if ($name -and -not $map.Contains($name.ToLower())) {
                $map[$name.ToLower()] = $block
            }
        }
        return $map
    }

    # Stamp time_modified = NOW on a card block so it beats cloud in merge
    function Set-ImportTimestamp([string]$block) {
        $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        if ($block -match "(?m)^\s*time_modified:\s*([^\r\n]+)") {
            return $block -replace "(?m)(^\s*time_modified:\s*)([^\r\n]+)", ('${1}' + $now)
        }
        # No time_modified field -- insert after time_created
        if ($block -match "(?m)(^\s*time_created:\s*[^\r\n]+)") {
            return $block -replace "(?m)(^\s*time_created:\s*[^\r\n]+)", ('$1' + "`n`ttime_modified: $now")
        }
        return $block
    }

    # Run the import preview after a file is chosen
    function Invoke-ImportPreview([string]$sourcePath) {
        $importList.Children.Clear()
        $btnImport.IsEnabled    = $false
        $btnImport.Foreground   = "#666"
        $importStatusText.Text  = "Reading file..."
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{})

        try {
            # Read source set
            $srcContent = Read-ZipSet $sourcePath
            if (-not $srcContent) { $importStatusText.Text = "Could not read the selected file."; return }

            # Read local shared set
            $localContent = Read-ZipSet $setFile.FullName
            if (-not $localContent) { $importStatusText.Text = "Could not read the shared set file."; return }

            $localNameMap = Get-NameMap $localContent

            # Parse source cards
            $srcCards = @(
                $srcContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
                    $block = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
                    $name  = Get-ImportCardName $block
                    if ($name) {
                        $status = if ($localNameMap.Contains($name.ToLower())) { "OVERRIDE" } else { "ADD" }
                        [pscustomobject]@{ Block=$block; Name=$name; Status=$status }
                    }
                }
            )

            if ($srcCards.Count -eq 0) { $importStatusText.Text = "No valid cards found in the selected file."; return }

            $script:importCards = $srcCards
            $addCount      = ($srcCards | Where-Object { $_.Status -eq "ADD" }).Count
            $overrideCount = ($srcCards | Where-Object { $_.Status -eq "OVERRIDE" }).Count
            $importStatusText.Text = "$($srcCards.Count) cards found: +$addCount new, ~$overrideCount replacing existing (matched by name)"

            # Build preview rows
            foreach ($card in $srcCards) {
                $row = New-Object System.Windows.Controls.Border
                $row.Margin  = [System.Windows.Thickness]::new(0,2,0,2)
                $row.Padding = [System.Windows.Thickness]::new(10,6,10,6)
                $row.CornerRadius = "4"
                if ($card.Status -eq "ADD") {
                    $row.Background  = $conv.ConvertFromString("#0F2A1A")
                    $row.BorderBrush = $conv.ConvertFromString("#15803D")
                } else {
                    $row.Background  = $conv.ConvertFromString("#131A30")
                    $row.BorderBrush = $conv.ConvertFromString("#1D4ED8")
                }
                $row.BorderThickness = "1"

                $sp = New-Object System.Windows.Controls.StackPanel
                $sp.Orientation = "Horizontal"

                $badge = New-Object System.Windows.Controls.Border
                $badge.CornerRadius = "3"
                $badge.Padding = [System.Windows.Thickness]::new(6,2,6,2)
                $badge.Margin  = [System.Windows.Thickness]::new(0,0,10,0)
                $badge.VerticalAlignment = "Center"
                if ($card.Status -eq "ADD") {
                    $badge.Background = $conv.ConvertFromString("#15803D")
                    $btb = New-Object System.Windows.Controls.TextBlock
                    $btb.Text = "+ ADD"; $btb.FontSize = 10; $btb.FontWeight = "Bold"; $btb.Foreground = "White"
                } else {
                    $badge.Background = $conv.ConvertFromString("#1D4ED8")
                    $btb = New-Object System.Windows.Controls.TextBlock
                    $btb.Text = "~ OVERRIDE"; $btb.FontSize = 10; $btb.FontWeight = "Bold"; $btb.Foreground = "White"
                }
                $badge.Child = $btb

                $nameTB = New-Object System.Windows.Controls.TextBlock
                $nameTB.Text = $card.Name; $nameTB.FontSize = 12; $nameTB.Foreground = "White"
                $nameTB.VerticalAlignment = "Center"

                $sp.Children.Add($badge)  | Out-Null
                $sp.Children.Add($nameTB) | Out-Null
                $row.Child = $sp
                $importList.Children.Add($row) | Out-Null
            }

            $btnImport.IsEnabled  = $true
            $btnImport.Foreground = "White"

        } catch {
            $importStatusText.Text = "Error: $($_.Exception.Message)"
        }
    }

    # Browse button
    $btnBrowse.add_Click({
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title  = "Select an MSE2 set file to import from"
        $dlg.Filter = "MSE Set files (*.mse-set)|*.mse-set|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $importPathBox.Text = $dlg.FileName
            Invoke-ImportPreview $dlg.FileName
        }
    })

    # Import button -- merges source cards into the local shared set and writes the result
    $btnImport.add_Click({
        if (-not $script:importCards -or $script:importCards.Count -eq 0) { return }
        $btnImport.IsEnabled = $false
        $importStatusText.Text = "Importing..."
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{})

        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            Add-Type -AssemblyName System.IO.Compression

            # Read current shared set
            $localContent = Read-ZipSet $setFile.FullName
            if (-not $localContent) { throw "Could not read the shared set file." }

            # Build an ordered name->block map of the local set (preserves card order)
            $orderedMap = [System.Collections.Specialized.OrderedDictionary]::new()
            $localContent -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
                $block = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
                $name  = Get-ImportCardName $block
                if ($name -and -not $orderedMap.Contains($name.ToLower())) {
                    $orderedMap[$name.ToLower()] = $block
                } elseif ($name) {
                    # Duplicate name -- keep it with a suffix key so it's not lost
                    $orderedMap["$($name.ToLower())__dup_$($orderedMap.Count)"] = $block
                }
            }

            # Apply imports -- override same-name, add new ones
            $addCount = 0; $overrideCount = 0
            foreach ($card in $script:importCards) {
                $key = $card.Name.ToLower()
                $stamped = Set-ImportTimestamp $card.Block
                if ($orderedMap.Contains($key)) {
                    $orderedMap[$key] = $stamped
                    $overrideCount++
                } else {
                    $orderedMap[$key] = $stamped
                    $addCount++
                }
            }

            # Rebuild set text: header + all cards + original trailing section (keywords etc.)
            $headerIdx = $localContent.IndexOf("`ncard:")
            $header    = if ($headerIdx -ge 0) { $localContent.Substring(0, $headerIdx + 1) } else { "" }

            $lastCardIdx = $localContent.LastIndexOf("`ncard:")
            $trail = ""
            if ($lastCardIdx -ge 0) {
                $after = $localContent.Substring($lastCardIdx)
                if ($after -match "(?s)`r?`n(keyword:|version_control:|apprentice_code:)") {
                    $ts = $after.IndexOf("`r`n" + $matches[1])
                    if ($ts -lt 0) { $ts = $after.IndexOf("`n" + $matches[1]) }
                    if ($ts -ge 0) { $trail = "`r`n" + $after.Substring($ts).TrimStart("`r","`n") }
                }
            }

            $newContent = $header
            foreach ($key in $orderedMap.Keys) { $newContent += $orderedMap[$key].TrimEnd() + "`r`n" }
            $newContent += $trail

            # Write back into the zip
            $tmpZip = [System.IO.Path]::GetTempFileName() + ".mse-set"
            $srcZip = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
            $dstZip = [System.IO.Compression.ZipFile]::Open($tmpZip, [System.IO.Compression.ZipArchiveMode]::Create)

            $se = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
            $sw = New-Object System.IO.StreamWriter($se.Open(), [System.Text.Encoding]::UTF8)
            $sw.Write($newContent); $sw.Flush(); $sw.Dispose()

            foreach ($img in ($srcZip.Entries | Where-Object { $_.Name -ne "set" })) {
                $de = $dstZip.CreateEntry($img.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                $s2 = $img.Open(); $d2 = $de.Open()
                $s2.CopyTo($d2); $s2.Dispose(); $d2.Dispose()
            }
            $srcZip.Dispose(); $dstZip.Dispose()
            Copy-Item $tmpZip $setFile.FullName -Force
            Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue

            $importStatusText.Text = "Done! +$addCount added, ~$overrideCount overridden. Switch to the Changes tab and sync to upload."
            $importStatusText.Foreground = $conv.ConvertFromString("#4ADE80")
            $btnImport.Content  = "Import Complete"
            $btnImport.Background = $conv.ConvertFromString("#14532D")

            # Invalidate the Changes tab so Refresh shows the new state
            $script:importCards = $null

        } catch {
            $importStatusText.Text = "Import failed: $($_.Exception.Message)"
            $importStatusText.Foreground = $conv.ConvertFromString("#F87171")
            $btnImport.IsEnabled = $true
        }
    })


    # =========================================================================
    # Helpers
    # =========================================================================
    function Read-ZipSet([string]$path) {
        try {
            $z  = [System.IO.Compression.ZipFile]::OpenRead($path)
            $e  = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
            if (-not $e) { $z.Dispose(); return $null }
            $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd(); $sr.Dispose(); $z.Dispose()
            return $txt
        } catch { return $null }
    }

    function Parse-CardMap([string]$content) {
        $map = [System.Collections.Specialized.OrderedDictionary]::new()
        if (-not $content) { return $map }
        $content -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
            $block = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            if ($block -match "(?m)^\s*time_created:\s*([^\r\n]+)") {
                $tc = $matches[1].Trim()
                if (-not $map.Contains($tc)) { $map[$tc] = $block }
            }
        }
        return $map
    }

    function Get-Field([string]$block, [string]$field) {
        if ($block -match "(?m)^\s*${field}:\s*(.+)") { return $matches[1].Trim() }
        return ""
    }

    function New-SummaryPill([string]$text, [string]$color) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background   = $conv.ConvertFromString($color)
        $b.CornerRadius = "12"
        $b.Padding      = [System.Windows.Thickness]::new(12, 4, 12, 4)
        $b.Margin       = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text; $tb.FontSize = 12; $tb.FontWeight = "SemiBold"; $tb.Foreground = "White"
        $b.Child = $tb
        return $b
    }

    function New-SectionHeader([string]$text, [string]$bgColor) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background   = $conv.ConvertFromString($bgColor)
        $b.CornerRadius = "4"
        $b.Margin       = [System.Windows.Thickness]::new(0, 14, 0, 4)
        $b.Padding      = [System.Windows.Thickness]::new(12, 6, 12, 6)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text; $tb.FontWeight = "Bold"; $tb.FontSize = 12; $tb.Foreground = "White"
        $b.Child = $tb
        return $b
    }

    function New-CardRow($entry, [string]$category, $sharedCommitMap, [string]$sharedDraftFile) {
        $name    = Get-Field $entry.Block "name";    if (-not $name)    { $name    = "(unnamed)" }
        $creator = Get-Field $entry.Block "creator"; if (-not $creator) { $creator = "?" }
        $rarity  = Get-Field $entry.Block "rarity"

        $capturedTC    = $entry.TC
        $capturedBlock = $entry.Block
        $capturedConv  = $conv
        $capturedMap   = $sharedCommitMap    # reference to the SAME dict object
        $capturedDraft = $sharedDraftFile

        $outer = New-Object System.Windows.Controls.Border
        $outer.Background   = $conv.ConvertFromString("#0F1A2E")
        $outer.Margin       = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $outer.Padding      = [System.Windows.Thickness]::new(14, 10, 14, 10)
        $outer.CornerRadius = "5"
        $capturedOuter = $outer

        $grid = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

        # Left: card info
        $info = New-Object System.Windows.Controls.StackPanel
        $nameBlock = New-Object System.Windows.Controls.TextBlock
        $nameBlock.Text = $name; $nameBlock.FontSize = 13; $nameBlock.FontWeight = "SemiBold"
        $info.Children.Add($nameBlock) | Out-Null
        $meta = New-Object System.Windows.Controls.TextBlock
        $meta.Text = "$creator  |  $rarity"
        $meta.FontSize = 11; $meta.Foreground = "#667"; $meta.Margin = [System.Windows.Thickness]::new(0,2,0,0)
        $info.Children.Add($meta) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($info, 0)
        $grid.Children.Add($info) | Out-Null

        # Right: action button
        $btnPanel = New-Object System.Windows.Controls.StackPanel
        $btnPanel.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($btnPanel, 1)

        if ($category -eq "adding") {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content    = "Remove"
            $btn.Background = $conv.ConvertFromString("#7F1D1D")
            $btn.ToolTip    = "Defer this card - it will appear in the next sync instead"
            $capturedBtn    = $btn
            $btn.add_Click({
                try {
                    if ($capturedMap -and $capturedMap.Contains($capturedTC)) { $capturedMap.Remove($capturedTC) }
                    if ($capturedDraft) { Add-Content $capturedDraft -Value ($capturedBlock.TrimEnd() + "`n") -Encoding UTF8 }
                    if ($capturedOuter -and $capturedConv) {
                        $capturedOuter.Background = $capturedConv.ConvertFromString("#0A0A0A")
                        $capturedOuter.Opacity    = 0.4
                    }
                    if ($capturedBtn) { $capturedBtn.IsEnabled = $false; $capturedBtn.Content = "Deferred" }
                } catch {
                    # Silently absorb - prevents exception from propagating to ShowDialog
                    [System.Diagnostics.Debug]::WriteLine("Remove click error: $($_.Exception.Message)")
                }
            }.GetNewClosure())
            $btnPanel.Children.Add($btn) | Out-Null
        }
        elseif ($category -eq "deleting") {
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content    = "Keep"
            $btn.Background = $conv.ConvertFromString("#14532D")
            $btn.ToolTip    = "Rescue this card - restore it into the set"
            $capturedBtn    = $btn
            $btn.add_Click({
                try {
                    if ($capturedMap -and -not $capturedMap.Contains($capturedTC)) { $capturedMap[$capturedTC] = $capturedBlock }
                    if ($capturedOuter -and $capturedConv) {
                        $capturedOuter.Background = $capturedConv.ConvertFromString("#0A1A0A")
                        $capturedOuter.Opacity    = 0.6
                    }
                    if ($capturedBtn -and $capturedConv) {
                        $capturedBtn.IsEnabled    = $false
                        $capturedBtn.Content      = "Kept"
                        $capturedBtn.Background   = $capturedConv.ConvertFromString("#333")
                    }
                } catch {
                    [System.Diagnostics.Debug]::WriteLine("Keep click error: $($_.Exception.Message)")
                }
            }.GetNewClosure())
            $btnPanel.Children.Add($btn) | Out-Null
        }

        $grid.Children.Add($btnPanel) | Out-Null
        $outer.Child = $grid
        return $outer
    }

    function New-HistoryRow([string]$hash, [string]$dateStr, [string]$msg) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background   = $conv.ConvertFromString("#0F1A2E")
        $b.Margin       = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $b.Padding      = [System.Windows.Thickness]::new(14, 8, 14, 8)
        $b.CornerRadius = "4"
        $sp = New-Object System.Windows.Controls.StackPanel
        $t1 = New-Object System.Windows.Controls.TextBlock
        $t1.Text = $msg; $t1.FontSize = 12; $t1.FontWeight = "SemiBold"
        $sp.Children.Add($t1) | Out-Null
        $t2 = New-Object System.Windows.Controls.TextBlock
        $t2.Text = "$dateStr  [$hash]"; $t2.FontSize = 10; $t2.Foreground = "#555"
        $t2.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        $sp.Children.Add($t2) | Out-Null
        $b.Child = $sp
        return $b
    }

    # =========================================================================
    # Update checkbox and sync button state
    # =========================================================================
    function Update-SyncButton {
        if ($hasChanges) {
            if ($chkReviewed.IsChecked -eq $true) {
                $btnSync.IsEnabled   = $true
                $btnSync.Background  = $conv.ConvertFromString("#16A34A")
                $btnSync.Foreground  = "White"
            } else {
                $btnSync.IsEnabled   = $false
                $btnSync.Background  = $conv.ConvertFromString("#1E3A1E")
                $btnSync.Foreground  = "#666"
            }
        } else {
            # No changes: sync is always ready (just pulls)
            $btnSync.IsEnabled   = $true
            $btnSync.Background  = $conv.ConvertFromString("#1D4ED8")
            $btnSync.Foreground  = "White"
        }
    }

    # =========================================================================
    # Main scan function
    # =========================================================================
    function Invoke-Scan {
        $cardList.Children.Clear()
        $summaryPanel.Children.Clear()
        $historyList.Children.Clear()
        $chkReviewed.IsChecked  = $false
        $chkReviewed.IsEnabled  = $false
        $btnSync.IsEnabled      = $false
        $btnSync.Background     = $conv.ConvertFromString("#1E3A1E")
        $btnSync.Foreground     = "#666"
        $lastCheckedText.Text   = "Fetching..."
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{})

        try {
            # ----------------------------------------------------------------
            # Auto-save MSE2 so unsaved cards appear in the diff.
            # Uses GetForegroundWindow() to verify MSE2 actually got focus
            # before sending Ctrl+S. AppActivate() silently fails when Windows'
            # foreground-stealing prevention kicks in right after this WPF
            # window opened -- Ctrl+S would go to Cloud Sync, not MSE2.
            # ----------------------------------------------------------------
            $saveWarning = $false   # shown as a banner in the diff if save couldn't be verified
            $mseProc = Get-Process "magicseteditor" -ErrorAction SilentlyContinue |
                       Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
            if ($mseProc) {
                $lastCheckedText.Text = "Saving..."
                $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{})
                Add-Type -AssemblyName Microsoft.VisualBasic
                Add-Type -AssemblyName System.Windows.Forms

                # Load GetForegroundWindow so we can verify focus before Ctrl+S
                $user32CS = $null
                try {
                    $user32CS = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();' `
                        -Name "Win32FG2" -Namespace "MSECSSync" -PassThru -ErrorAction SilentlyContinue
                } catch {}

                $preTs      = $setFile.LastWriteTime
                $saveDone   = $false

                for ($att = 1; $att -le 3 -and -not $saveDone; $att++) {
                    try { [Microsoft.VisualBasic.Interaction]::AppActivate($mseProc.Id) } catch {}
                    Start-Sleep -Milliseconds 600
                    $fg = if ($user32CS) { $user32CS::GetForegroundWindow() } else { $mseProc.MainWindowHandle }
                    if ($fg -eq $mseProc.MainWindowHandle) {
                        [System.Windows.Forms.SendKeys]::SendWait("^s")
                        for ($sw = 0; $sw -lt 14; $sw++) {
                            Start-Sleep -Milliseconds 300
                            $setFile.Refresh()
                            if ($setFile.LastWriteTime -gt $preTs) { $saveDone = $true; break }
                        }
                    }
                    if (-not $saveDone -and $att -lt 3) { Start-Sleep -Milliseconds 400 }
                }

                if (-not $saveDone -and $setFile.LastWriteTime -le $preTs) {
                    $saveWarning = $true   # diff may be incomplete -- shown as banner below
                }
                try { $window.Activate() } catch {}
            }

            # Fetch latest from remote (read-only, no file changes)
            & $gitExe -C $appData -c "credential.helper=" remote set-url origin $remoteUrl *>$null
            & $gitExe -C $appData -c "credential.helper=" fetch origin *>$null

            $lastCheckedText.Text = "Last checked: $(Get-Date -Format 'h:mm tt')"

            # Get the set path relative to repo
            $setRelPath = $setFile.FullName.Substring($appData.TrimEnd('\').Length + 1).Replace("\", "/")

            # Extract cloud (origin/main) version into a temp file
            $cloudBlob = (& $gitExe -C $appData rev-parse "origin/main:$setRelPath" 2>$null).Trim()
            $cloudTmp  = "$env:TEMP\cloudsync_cloud_$([System.IO.Path]::GetRandomFileName()).mse-set"
            if ($cloudBlob) {
                cmd /c ("`"" + $gitExe + "`" -C `"" + $appData + "`" cat-file blob " + $cloudBlob + " > `"" + $cloudTmp + "`"") 2>$null
            }

            $localContent = Read-ZipSet $setFile.FullName
            $cloudContent = if ((Test-Path $cloudTmp) -and (Get-Item $cloudTmp).Length -gt 0) {
                Read-ZipSet $cloudTmp
            } else { $null }
            Remove-Item $cloudTmp -Force -ErrorAction SilentlyContinue

            if (-not $localContent) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $tb.Text = "Could not read local set file."; $tb.Foreground = "#E74C3C"
                $cardList.Children.Add($tb) | Out-Null
                return
            }
            if (-not $cloudContent) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $tb.Text = "Could not fetch cloud set. Check your internet connection."; $tb.Foreground = "#E74C3C"
                $cardList.Children.Add($tb) | Out-Null
                return
            }

            $mergedMap = Parse-CardMap $localContent
            $cloudMap  = Parse-CardMap $cloudContent

            # commitMap starts as a copy of the local state -- plain var, not $script:
            # New-CardRow receives this by reference so button clicks modify the same dict
            $commitMap = [System.Collections.Specialized.OrderedDictionary]::new()
            foreach ($k in $mergedMap.Keys) { $commitMap[$k] = $mergedMap[$k] }

            # Categorize
            $adding   = @()
            $deleting = @()
            $changed  = @()
            foreach ($tc in $mergedMap.Keys) {
                if (-not $cloudMap.Contains($tc)) {
                    $adding += @{ TC=$tc; Block=$mergedMap[$tc] }
                } elseif ($mergedMap[$tc] -ne $cloudMap[$tc]) {
                    $changed += @{ TC=$tc; Block=$mergedMap[$tc]; CloudBlock=$cloudMap[$tc] }
                }
            }
            foreach ($tc in $cloudMap.Keys) {
                if (-not $mergedMap.Contains($tc)) {
                    $deleting += @{ TC=$tc; Block=$cloudMap[$tc] }
                }
            }

            $totalChanges = $adding.Count + $deleting.Count + $changed.Count
            $hasChanges   = $totalChanges -gt 0

            # ----------------------------------------------------------------
            # PENDING DEDUP BANNER -- show vote UI if pending_dedup.json on cloud
            # ----------------------------------------------------------------
            try {
                $cloudDedupBlob = (& $gitExe -C $appData rev-parse "origin/main:$($setRelPath -replace '[^/]+$','')pending_dedup.json" 2>$null).Trim()
                if ($cloudDedupBlob) {
                    $dedupTmp = "$env:TEMP\cloudsync_dedup_$([System.IO.Path]::GetRandomFileName()).json"
                    cmd /c ("`"" + $gitExe + "`" -C `"" + $appData + "`" cat-file blob " + $cloudDedupBlob + " > `"" + $dedupTmp + "`"") 2>$null
                    if ((Test-Path $dedupTmp) -and (Get-Item $dedupTmp).Length -gt 0) {
                        $jsSer   = New-Object System.Web.Script.Serialization.JavaScriptSerializer
                        $jsSer.MaxJsonLength = 20MB
                        $dedupData = $jsSer.DeserializeObject((Get-Content $dedupTmp -Raw))
                        Remove-Item $dedupTmp -Force -ErrorAction SilentlyContinue

                        if ($dedupData -and $dedupData["status"] -notin @("done","cancelled")) {
                            # Banner border
                            $bannerBorder = New-Object System.Windows.Controls.Border
                            $bannerBorder.Background   = $conv.ConvertFromString("#1A0800")
                            $bannerBorder.BorderBrush  = $conv.ConvertFromString("#92400E")
                            $bannerBorder.BorderThickness = "1"
                            $bannerBorder.CornerRadius = "6"
                            $bannerBorder.Margin       = [System.Windows.Thickness]::new(0,0,0,14)
                            $bannerBorder.Padding      = [System.Windows.Thickness]::new(14,12,14,12)
                            $bannerSP = New-Object System.Windows.Controls.StackPanel

                            $bannerTitle = New-Object System.Windows.Controls.TextBlock
                            $bannerTitle.Text = "[!] Delete Duplicates Pending -- vote required"
                            $bannerTitle.FontSize = 13; $bannerTitle.FontWeight = "Bold"
                            $bannerTitle.Foreground = $conv.ConvertFromString("#FCD34D")
                            $bannerSP.Children.Add($bannerTitle) | Out-Null

                            $initiator   = $dedupData["initiated_by"]
                            $remaining   = $dedupData["syncs_remaining"]
                            $groupCount  = if ($dedupData["groups"]) { $dedupData["groups"].Count } else { 0 }
                            $totalDupeCount = if ($dedupData["groups"]) {
                                ($dedupData["groups"] | ForEach-Object { if ($_.ContainsKey("dupes")) { $_.dupes.Count } else { 0 } } | Measure-Object -Sum).Sum
                            } else { 0 }

                            $bannerSub = New-Object System.Windows.Controls.TextBlock
                            $bannerSub.Text = "$initiator wants to remove $totalDupeCount duplicate card(s) across $groupCount group(s). Purges in $remaining more sync(s). Any 'No' vote cancels it for everyone."
                            $bannerSub.FontSize = 11; $bannerSub.Foreground = $conv.ConvertFromString("#D97706")
                            $bannerSub.TextWrapping = "Wrap"; $bannerSub.Margin = [System.Windows.Thickness]::new(0,4,0,8)
                            $bannerSP.Children.Add($bannerSub) | Out-Null

                            # Show existing votes
                            if ($dedupData["votes"] -and $dedupData["votes"].Count -gt 0) {
                                $voteStr = ($dedupData["votes"].Keys | ForEach-Object { ($_ + ": " + $dedupData["votes"][$_]) }) -join "  |  "
                                $voteTB = New-Object System.Windows.Controls.TextBlock
                                $voteTB.Text = ("Votes so far: " + $voteStr)
                                $voteTB.FontSize = 10; $voteTB.Foreground = $conv.ConvertFromString("#9CA3AF")
                                $voteTB.Margin = [System.Windows.Thickness]::new(0,0,0,8)
                                $bannerSP.Children.Add($voteTB) | Out-Null
                            }

                            # Show duplicate groups collapsible list
                            if ($dedupData["groups"]) {
                                foreach ($g in $dedupData["groups"]) {
                                    $gBorder = New-Object System.Windows.Controls.Border
                                    $gBorder.Background   = $conv.ConvertFromString("#0F1A2E")
                                    $gBorder.CornerRadius = "4"; $gBorder.Padding = [System.Windows.Thickness]::new(10,6,10,6)
                                    $gBorder.Margin = [System.Windows.Thickness]::new(0,2,0,2)
                                    $gSP = New-Object System.Windows.Controls.StackPanel
                                    $kTB = New-Object System.Windows.Controls.TextBlock
                                    $kTB.Text = ("[KEEP] " + $g["keeper_name"] + " (by " + $g["keeper_creator"] + ", modified " + $g["keeper_modified"] + ")")
                                    $kTB.FontSize = 11; $kTB.Foreground = $conv.ConvertFromString("#4ADE80")
                                    $gSP.Children.Add($kTB) | Out-Null
                                    foreach ($d in $g["dupes"]) {
                                        $dTB = New-Object System.Windows.Controls.TextBlock
                                        $dTB.Text = ("  [REMOVE] " + $d["name"] + " (by " + $d["creator"] + ", modified " + $d["time_modified"] + ")")
                                        $dTB.FontSize = 11; $dTB.Foreground = $conv.ConvertFromString("#F87171")
                                        $gSP.Children.Add($dTB) | Out-Null
                                    }
                                    $gBorder.Child = $gSP
                                    $bannerSP.Children.Add($gBorder) | Out-Null
                                }
                            }

                            # Vote buttons (only show if this user hasn't voted yet)
                            $alreadyVoted = $dedupData["votes"] -and $dedupData["votes"].ContainsKey($myName)
                            if (-not $alreadyVoted) {
                                $voteSP = New-Object System.Windows.Controls.StackPanel
                                $voteSP.Orientation = "Horizontal"
                                $voteSP.Margin = [System.Windows.Thickness]::new(0,10,0,0)

                                $capturedMyName    = $myName
                                $capturedSyncScript= $syncScript
                                $capturedWindow    = $window

                                $btnYes = New-Object System.Windows.Controls.Button
                                $btnYes.Content = "[Yes] Remove duplicates"
                                $btnYes.Background = $conv.ConvertFromString("#14532D")
                                $btnYes.Foreground = "White"; $btnYes.Padding = [System.Windows.Thickness]::new(14,7,14,7)
                                $btnYes.Margin = [System.Windows.Thickness]::new(0,0,8,0); $btnYes.FontSize = 12
                                $btnYes.add_Click({
                                    Set-Content "$env:TEMP\mse_dedup_vote_${capturedMyName}.txt" -Value "yes" -Encoding UTF8
                                    $syncA = @("-ExecutionPolicy","Bypass","-WindowStyle","Normal","-File",$capturedSyncScript)
                                    Start-Process "powershell.exe" -ArgumentList $syncA
                                    $capturedWindow.Close()
                                }.GetNewClosure())
                                $voteSP.Children.Add($btnYes) | Out-Null

                                $btnNo = New-Object System.Windows.Controls.Button
                                $btnNo.Content = "[No] Cancel this"
                                $btnNo.Background = $conv.ConvertFromString("#7F1D1D")
                                $btnNo.Foreground = "White"; $btnNo.Padding = [System.Windows.Thickness]::new(14,7,14,7)
                                $btnNo.Margin = [System.Windows.Thickness]::new(0,0,8,0); $btnNo.FontSize = 12
                                $btnNo.add_Click({
                                    Set-Content "$env:TEMP\mse_dedup_vote_${capturedMyName}.txt" -Value "no" -Encoding UTF8
                                    $syncA = @("-ExecutionPolicy","Bypass","-WindowStyle","Normal","-File",$capturedSyncScript)
                                    Start-Process "powershell.exe" -ArgumentList $syncA
                                    $capturedWindow.Close()
                                }.GetNewClosure())
                                $voteSP.Children.Add($btnNo) | Out-Null

                                $btnSkip = New-Object System.Windows.Controls.Button
                                $btnSkip.Content = "Skip for now"
                                $btnSkip.Background = $conv.ConvertFromString("#1E293B")
                                $btnSkip.Foreground = "#AAA"; $btnSkip.Padding = [System.Windows.Thickness]::new(14,7,14,7)
                                $btnSkip.FontSize = 12
                                $btnSkip.add_Click({ $bannerBorder.Visibility = "Collapsed" }.GetNewClosure())
                                $voteSP.Children.Add($btnSkip) | Out-Null

                                $bannerSP.Children.Add($voteSP) | Out-Null
                            } else {
                                $votedTB = New-Object System.Windows.Controls.TextBlock
                                $votedTB.Text = ("[OK] You have already voted: " + $dedupData["votes"][$myName])
                                $votedTB.FontSize = 11; $votedTB.Foreground = $conv.ConvertFromString("#6EE7B7")
                                $votedTB.Margin = [System.Windows.Thickness]::new(0,8,0,0)
                                $bannerSP.Children.Add($votedTB) | Out-Null
                            }

                            $bannerBorder.Child = $bannerSP
                            $cardList.Children.Add($bannerBorder) | Out-Null
                        }
                    } else {
                        Remove-Item $dedupTmp -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                # Pending dedup check is non-fatal
                [System.Diagnostics.Debug]::WriteLine("Dedup banner error: $($_.Exception.Message)")
            }

            # SAVE WARNING banner -- shown when the auto-save couldn't be verified.
            # This is the most common reason the diff shows "Up to date" even when
            # the user has unsaved edits in MSE2.
            if ($saveWarning) {
                $warnBorder = New-Object System.Windows.Controls.Border
                $warnBorder.Background  = $conv.ConvertFromString("#2D0000")
                $warnBorder.BorderBrush = $conv.ConvertFromString("#EF4444")
                $warnBorder.BorderThickness = "1"
                $warnBorder.CornerRadius = "6"
                $warnBorder.Padding  = [System.Windows.Thickness]::new(14, 10, 14, 10)
                $warnBorder.Margin   = [System.Windows.Thickness]::new(0, 0, 0, 12)
                $warnSP  = New-Object System.Windows.Controls.StackPanel
                $warnTB1 = New-Object System.Windows.Controls.TextBlock
                $warnTB1.Text       = "[!] MSE2 could not be auto-saved"
                $warnTB1.FontSize   = 13; $warnTB1.FontWeight = "Bold"
                $warnTB1.Foreground = $conv.ConvertFromString("#FCA5A5")
                $warnTB2 = New-Object System.Windows.Controls.TextBlock
                $warnTB2.Text       = "The diff below may be missing your latest edits. Please press Ctrl+S in Magic Set Editor, then click Refresh."
                $warnTB2.FontSize   = 11
                $warnTB2.Foreground = $conv.ConvertFromString("#FCA5A5")
                $warnTB2.TextWrapping = "Wrap"
                $warnTB2.Margin     = [System.Windows.Thickness]::new(0, 4, 0, 0)
                $warnSP.Children.Add($warnTB1) | Out-Null
                $warnSP.Children.Add($warnTB2) | Out-Null
                $warnBorder.Child = $warnSP
                $cardList.Children.Add($warnBorder) | Out-Null
            }

            # Summary pills

            if ($adding.Count -gt 0)  { $summaryPanel.Children.Add((New-SummaryPill "+$($adding.Count) adding" "#15803D"))  | Out-Null }
            if ($deleting.Count -gt 0) { $summaryPanel.Children.Add((New-SummaryPill "-$($deleting.Count) deleting" "#B91C1C")) | Out-Null }
            if ($changed.Count -gt 0)  { $summaryPanel.Children.Add((New-SummaryPill "~$($changed.Count) changed" "#1D4ED8"))  | Out-Null }
            if ($totalChanges -eq 0)   { $summaryPanel.Children.Add((New-SummaryPill "Up to date" "#374151"))                   | Out-Null }

            # Card sections -- pass commitMap and draftFile explicitly to New-CardRow
            if ($adding.Count -gt 0) {
                $cardList.Children.Add((New-SectionHeader "ADDING - Your new cards going up" "#14532D")) | Out-Null
                foreach ($e in $adding) { $cardList.Children.Add((New-CardRow $e "adding" $commitMap $draftFile)) | Out-Null }
            }
            if ($deleting.Count -gt 0) {
                $cardList.Children.Add((New-SectionHeader "DELETING - Will be removed for everyone" "#7F1D1D")) | Out-Null
                foreach ($e in $deleting) { $cardList.Children.Add((New-CardRow $e "deleting" $commitMap $draftFile)) | Out-Null }
            }
            if ($changed.Count -gt 0) {
                $cardList.Children.Add((New-SectionHeader "CHANGED - Edits since last sync" "#1E3A5F")) | Out-Null
                foreach ($e in $changed) { $cardList.Children.Add((New-CardRow $e "changed" $commitMap $draftFile)) | Out-Null }
            }
            if ($totalChanges -eq 0) {
                $tb = New-Object System.Windows.Controls.TextBlock
                $tb.Text = "Your set is up to date with the cloud. Safe to sync."
                $tb.Foreground = "#4B5563"; $tb.FontStyle = "Italic"; $tb.FontSize = 13
                $tb.HorizontalAlignment = "Center"; $tb.Margin = [System.Windows.Thickness]::new(0,30,0,0)
                $cardList.Children.Add($tb) | Out-Null
            }

            # Checkbox visibility
            if ($hasChanges) {
                $chkReviewed.IsEnabled = $true
                $chkReviewed.Content   = "I have reviewed all $totalChanges change(s) above"
            } else {
                $chkReviewed.IsEnabled = $false
                $chkReviewed.Content   = "I have reviewed all changes above"
            }

            # History tab - log origin/main (not HEAD) so all users see the full
            # history even before they've personally synced.
            $logLines = @(& $gitExe -C $appData log origin/main --format="%h|%ai|%cn|%s" -30 2>$null)
            if ($logLines) {
                foreach ($line in $logLines) {
                    $parts = $line -split "\|", 4
                    if ($parts.Count -ge 4) {
                        $hsh  = $parts[0].Trim()
                        $dt   = $parts[1].Trim()
                        $who  = $parts[2].Trim()
                        $msg  = $parts[3].Trim()
                        $label = if ($who) { "$who  --  $msg" } else { $msg }
                        try { $dtParsed = [datetime]::Parse($dt); $dt = $dtParsed.ToString("MMM d, h:mm tt") } catch {}
                        $historyList.Children.Add((New-HistoryRow $hsh $dt $label)) | Out-Null
                    }
                }
            } else {
                $tb = New-Object System.Windows.Controls.TextBlock
                $tb.Text = "No sync history found."; $tb.Foreground = "#4B5563"; $tb.FontStyle = "Italic"
                $historyList.Children.Add($tb) | Out-Null
            }

        } catch {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "Scan error: $($_.Exception.Message)"; $tb.Foreground = "#E74C3C"
            $cardList.Children.Add($tb) | Out-Null
        }

        Update-SyncButton
    }

    # =========================================================================
    # Events
    # =========================================================================
    $chkReviewed.add_Checked({   Update-SyncButton })
    $chkReviewed.add_Unchecked({ Update-SyncButton })

    $btnRefresh.add_Click({ Invoke-Scan })
    $btnSync.add_Click({
        # Disable buttons immediately to prevent double-click
        $btnSync.IsEnabled    = $false
        $btnRefresh.IsEnabled = $false
        $btnSync.Content      = "Syncing..."

        try {
            # Write predecided Remove/Keep state to a temp file for SyncNow to consume
            $predecidedFile = "$env:TEMP\cloudsync_decisions_$([System.IO.Path]::GetRandomFileName()).txt"
            $lines = @()
            foreach ($tc in $commitMap.Keys) { $lines += "KEEP:$tc" }
            # Cards in mergedMap but NOT in commitMap were Removed by user
            foreach ($tc in $mergedMap.Keys) {
                if (-not $commitMap.Contains($tc)) { $lines += "REMOVE:$tc" }
            }
            # Cards in commitMap but NOT in mergedMap were Kept (rescued deletions)
            foreach ($tc in $commitMap.Keys) {
                if (-not $mergedMap.Contains($tc)) { $lines += "RESTORE:$tc|$($commitMap[$tc])" }
            }
            Set-Content $predecidedFile -Value $lines -Encoding UTF8

            # Launch SyncNow with -SkipPreview flag
            $syncArgs = @(
                "-ExecutionPolicy", "Bypass",
                "-WindowStyle",     "Normal",
                "-File",            $syncScript,
                "-SkipPreview",
                "-PredecidedFile",  $predecidedFile
            )
            Start-Process "powershell.exe" -ArgumentList $syncArgs

            # Close this window - SyncNow will kill MSE2 and reopen it
            $window.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Sync Launch Error") | Out-Null
            $btnSync.IsEnabled    = $true
            $btnRefresh.IsEnabled = $true
            $btnSync.Content      = "Sync Now"
        }
    })

    $window.add_Loaded({
        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-Scan })
    })

    $window.ShowDialog() | Out-Null

} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cloud Sync Error")
}
