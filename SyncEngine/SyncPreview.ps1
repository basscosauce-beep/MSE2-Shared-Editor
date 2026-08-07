# SyncPreview.ps1 - Shows a preview of sync changes before committing
# Called by SyncNow.ps1 after merge, before git commit/push
# Args: -MergedFile <path> -CloudFile <path> -ResultFile <path> -DraftFile <path> -UserName <name>
param(
    [string]$MergedFile,   # The merged .mse-set on disk (what WILL be committed)
    [string]$CloudFile,    # The cloud .mse-set (what is currently on GitHub = origin/main)
    [string]$ResultFile,   # Write "OK" or "CANCEL" here when done
    [string]$DraftFile,    # draft_cards_<user>.txt for deferred cards
    [string]$UserName = "Unknown"
)

if (-not $MergedFile -or -not $CloudFile -or -not $ResultFile) {
    # If called without args, write OK so sync proceeds
    if ($ResultFile) { Set-Content $ResultFile "OK" }
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# Write CANCEL by default (if window is force-closed)
Set-Content $ResultFile "CANCEL" -Encoding UTF8

# =========================================================================
# Helpers
# =========================================================================
function Read-ZipSet([string]$path) {
    try {
        $z = [System.IO.Compression.ZipFile]::OpenRead($path)
        $e = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
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

function Write-ZipSet([string]$zipPath, [string]$newSetText) {
    # Write new "set" text into the zip, preserving all other entries (images etc.)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression
    $tmpPath = [System.IO.Path]::GetTempFileName() + ".mse-set"
    $srcZip  = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $dstZip  = [System.IO.Compression.ZipFile]::Open($tmpPath, [System.IO.Compression.ZipArchiveMode]::Create)
    # Write new set text
    $setEnt  = $dstZip.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
    $sw      = New-Object System.IO.StreamWriter($setEnt.Open(), [System.Text.Encoding]::UTF8)
    $sw.Write($newSetText); $sw.Flush(); $sw.Dispose()
    # Copy all non-"set" entries
    foreach ($ent in ($srcZip.Entries | Where-Object { $_.Name -ne "set" })) {
        $dstEnt = $dstZip.CreateEntry($ent.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
        $si = $ent.Open(); $di = $dstEnt.Open()
        $si.CopyTo($di); $si.Dispose(); $di.Dispose()
    }
    $srcZip.Dispose(); $dstZip.Dispose()
    Copy-Item $tmpPath $zipPath -Force
    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
}

# =========================================================================
# Compute diff
# =========================================================================
$mergedContent = Read-ZipSet $MergedFile
$cloudContent  = Read-ZipSet $CloudFile

$mergedMap = Parse-CardMap $mergedContent
$cloudMap  = Parse-CardMap $cloudContent

# Track what we're going to actually commit (starts as a copy of mergedMap)
$commitMap = [System.Collections.Specialized.OrderedDictionary]::new()
foreach ($k in $mergedMap.Keys) { $commitMap[$k] = $mergedMap[$k] }

# Categorize cards
$adding   = @()  # in merged, NOT in cloud (your new cards going up)
$deleting = @()  # in cloud, NOT in merged  (being removed for everyone)
$edited   = @()  # in both but content differs
$incoming = @()  # in both, content differs, and creator != UserName (friend's change)

foreach ($tc in $mergedMap.Keys) {
    if (-not $cloudMap.Contains($tc)) {
        $adding += @{ TC=$tc; Block=$mergedMap[$tc] }
    } elseif ($mergedMap[$tc] -ne $cloudMap[$tc]) {
        $creator = Get-Field $mergedMap[$tc] "creator"
        if ($creator -eq $UserName) {
            $edited += @{ TC=$tc; Block=$mergedMap[$tc]; CloudBlock=$cloudMap[$tc] }
        } else {
            $incoming += @{ TC=$tc; Block=$mergedMap[$tc]; CloudBlock=$cloudMap[$tc] }
        }
    }
}
foreach ($tc in $cloudMap.Keys) {
    if (-not $mergedMap.Contains($tc)) {
        $deleting += @{ TC=$tc; Block=$cloudMap[$tc] }
    }
}

# =========================================================================
# XAML
# =========================================================================
$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sync Preview" Height="700" Width="640"
        WindowStartupLocation="CenterScreen" Background="#0F0F1A" Foreground="White">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
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
    <Border Grid.Row="0" Background="#1A1A2E" Padding="20,16">
      <StackPanel>
        <TextBlock Name="TitleText" Text="Sync Preview" FontSize="20" FontWeight="Bold" Foreground="#7EC8E3"/>
        <TextBlock Name="SubText" Text="Review changes before uploading" FontSize="12" Foreground="#666" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <!-- Summary bar -->
    <Border Grid.Row="1" Background="#141428" Padding="20,10">
      <StackPanel Name="SummaryPanel" Orientation="Horizontal"/>
    </Border>

    <!-- Card list -->
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="16,8">
      <StackPanel Name="CardList"/>
    </ScrollViewer>

    <!-- Footer buttons -->
    <Border Grid.Row="3" Background="#1A1A2E" Padding="20,14">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <TextBlock Name="NoteText" Text="MSE2 will reopen after sync." Foreground="#555"
                   FontSize="11" VerticalAlignment="Center" Margin="0,0,16,0"/>
        <Button Name="BtnCancel" Content="Cancel" Background="#3D3D3D" Margin="0,0,8,0"/>
        <Button Name="BtnSync"   Content="Sync Now" Background="#2ECC71" FontWeight="Bold"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$xaml   = [xml]$xamlStr
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$titleText   = $window.FindName("TitleText")
$subText     = $window.FindName("SubText")
$summaryPanel= $window.FindName("SummaryPanel")
$cardList    = $window.FindName("CardList")
$btnCancel   = $window.FindName("BtnCancel")
$btnSync     = $window.FindName("BtnSync")
$noteText    = $window.FindName("NoteText")

# =========================================================================
# UI helpers
# =========================================================================
$conv = New-Object System.Windows.Media.BrushConverter

function New-SummaryPill([string]$text, [string]$color) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background   = $conv.ConvertFromString($color)
    $b.CornerRadius = "12"
    $b.Padding      = [System.Windows.Thickness]::new(10, 3, 10, 3)
    $b.Margin       = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text       = $text
    $tb.FontSize   = 11
    $tb.FontWeight = "SemiBold"
    $tb.Foreground = "White"
    $b.Child = $tb
    return $b
}

function New-SectionHeader([string]$text, [string]$color) {
    $b = New-Object System.Windows.Controls.Border
    $b.Margin = [System.Windows.Thickness]::new(0, 12, 0, 4)
    $b.Padding = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $b.Background = $conv.ConvertFromString($color)
    $b.CornerRadius = "4"
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontWeight = "Bold"; $tb.FontSize = 12; $tb.Foreground = "White"
    $b.Child = $tb
    return $b
}

function New-CardRow($entry, [string]$category) {
    $name    = Get-Field $entry.Block "name"
    if (-not $name) { $name = "(unnamed)" }
    $creator = Get-Field $entry.Block "creator"
    if (-not $creator) { $creator = "?" }
    $rarity  = Get-Field $entry.Block "rarity"

    $outer = New-Object System.Windows.Controls.Border
    $outer.Background = $conv.ConvertFromString("#16213E")
    $outer.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
    $outer.Padding = [System.Windows.Thickness]::new(14, 9, 14, 9)
    $outer.CornerRadius = "5"

    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $info = New-Object System.Windows.Controls.StackPanel
    $nameBlock = New-Object System.Windows.Controls.TextBlock
    $nameBlock.Text = $name; $nameBlock.FontSize = 13; $nameBlock.FontWeight = "SemiBold"
    $info.Children.Add($nameBlock) | Out-Null

    $meta = New-Object System.Windows.Controls.TextBlock
    $meta.Text = "$creator  |  $rarity"; $meta.FontSize = 11; $meta.Foreground = "#777"
    $meta.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $info.Children.Add($meta) | Out-Null

    [System.Windows.Controls.Grid]::SetColumn($info, 0)
    $grid.Children.Add($info) | Out-Null

    $btnPanel = New-Object System.Windows.Controls.StackPanel
    $btnPanel.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($btnPanel, 1)

    if ($category -eq "adding") {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content    = "Remove"
        $btn.Background = $conv.ConvertFromString("#E74C3C")
        $btn.ToolTip    = "Defer this card - it will sync next time instead"
        $capturedTC    = $entry.TC
        $capturedBlock = $entry.Block
        $capturedOuter = $outer
        $btn.add_Click({
            # Remove from commitMap
            if ($commitMap.Contains($capturedTC)) { $commitMap.Remove($capturedTC) }
            # Write to draft file so it syncs next time
            if ($DraftFile) {
                Add-Content $DraftFile -Value ($capturedBlock.TrimEnd() + "`n") -Encoding UTF8
            }
            $capturedOuter.Background = $conv.ConvertFromString("#1A1A1A")
            $capturedOuter.Opacity = 0.4
            $btn.IsEnabled = $false
            $btn.Content = "Deferred"
        }.GetNewClosure())
        $btnPanel.Children.Add($btn) | Out-Null
    }
    elseif ($category -eq "deleting") {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content    = "Keep"
        $btn.Background = $conv.ConvertFromString("#27AE60")
        $btn.ToolTip    = "Restore this card - put it back in the set"
        $capturedTC    = $entry.TC
        $capturedBlock = $entry.Block
        $capturedOuter = $outer
        $btn.add_Click({
            # Add back to commitMap (restore from cloud block)
            if (-not $commitMap.Contains($capturedTC)) { $commitMap[$capturedTC] = $capturedBlock }
            $capturedOuter.Background = $conv.ConvertFromString("#1A2E1A")
            $capturedOuter.Opacity = 0.6
            $btn.IsEnabled = $false
            $btn.Content = "Kept"
            $btn.Background = $conv.ConvertFromString("#555")
        }.GetNewClosure())
        $btnPanel.Children.Add($btn) | Out-Null
    }

    $grid.Children.Add($btnPanel) | Out-Null
    $outer.Child = $grid
    return $outer
}

# =========================================================================
# Populate summary bar + card list
# =========================================================================
$totalChanges = $adding.Count + $deleting.Count + $edited.Count + $incoming.Count

if ($totalChanges -eq 0) {
    $subText.Text = "No changes - your set is already in sync with the cloud."
    $btnSync.Content = "Sync (No Changes)"
} else {
    $subText.Text = "Review the changes below before uploading to the cloud."
}

if ($adding.Count -gt 0) {
    $summaryPanel.Children.Add((New-SummaryPill "+$($adding.Count) adding" "#27AE60")) | Out-Null
}
if ($deleting.Count -gt 0) {
    $summaryPanel.Children.Add((New-SummaryPill "-$($deleting.Count) deleting" "#E74C3C")) | Out-Null
}
if ($edited.Count -gt 0) {
    $summaryPanel.Children.Add((New-SummaryPill "~$($edited.Count) edited" "#3498DB")) | Out-Null
}
if ($incoming.Count -gt 0) {
    $summaryPanel.Children.Add((New-SummaryPill "$($incoming.Count) from friends" "#9B59B6")) | Out-Null
}
if ($totalChanges -eq 0) {
    $summaryPanel.Children.Add((New-SummaryPill "No changes" "#555")) | Out-Null
}

# Adding section
if ($adding.Count -gt 0) {
    $cardList.Children.Add((New-SectionHeader "ADDING - Your new cards going up" "#1E5C2A")) | Out-Null
    foreach ($e in $adding) { $cardList.Children.Add((New-CardRow $e "adding")) | Out-Null }
}

# Deleting section
if ($deleting.Count -gt 0) {
    $cardList.Children.Add((New-SectionHeader "DELETING - Will be removed for everyone" "#5C1E1E")) | Out-Null
    foreach ($e in $deleting) { $cardList.Children.Add((New-CardRow $e "deleting")) | Out-Null }
}

# Edited section
if ($edited.Count -gt 0) {
    $cardList.Children.Add((New-SectionHeader "EDITED - Your changes to existing cards" "#1E3D5C")) | Out-Null
    foreach ($e in $edited) { $cardList.Children.Add((New-CardRow $e "edited")) | Out-Null }
}

# Incoming section
if ($incoming.Count -gt 0) {
    $cardList.Children.Add((New-SectionHeader "INCOMING - Friends changes coming down" "#3D1E5C")) | Out-Null
    foreach ($e in $incoming) { $cardList.Children.Add((New-CardRow $e "incoming")) | Out-Null }
}

if ($totalChanges -eq 0) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "Everything is already in sync. Click Sync Now to confirm."
    $tb.Foreground = "#555"; $tb.FontStyle = "Italic"; $tb.Margin = "0,24,0,0"
    $tb.HorizontalAlignment = "Center"
    $cardList.Children.Add($tb) | Out-Null
}

# =========================================================================
# Button handlers
# =========================================================================
$btnCancel.add_Click({
    Set-Content $ResultFile "CANCEL" -Encoding UTF8
    $window.Close()
})

$btnSync.add_Click({
    # Rebuild the merged file from commitMap (respecting any Remove/Keep actions)
    try {
        $mergedHeader  = $mergedContent -replace "(?ms)^card:.*", "" -split "(?m)^card:" | Select-Object -First 1
        # Actually: extract the header (everything before first "card:" block)
        $headerMatch = if ($mergedContent -match "(?s)^(.*?)\ncard:") { $matches[1] + "`n" } else { $mergedContent }

        # Rebuild set text: header + all commitMap cards
        $newText = $headerMatch
        foreach ($tc in $commitMap.Keys) {
            $block = $commitMap[$tc]
            if (-not $block.StartsWith("card:")) { $block = "card:`n" + $block }
            $newText += $block.TrimEnd() + "`n"
        }

        # Append trailing metadata that was in merged (keywords, version_control, etc.)
        $trailingMatch = if ($mergedContent -match "(?ms)\n(keyword:.*|version_control:.*)$") {
            "`n" + $matches[1]
        } else { "" }
        $newText += $trailingMatch

        Write-ZipSet $MergedFile $newText
    } catch {
        # If rebuild fails, just use the merged file as-is
        Write-Host "Preview: could not rebuild set text: $($_.Exception.Message)"
    }

    Set-Content $ResultFile "OK" -Encoding UTF8
    $window.Close()
})

$window.ShowDialog() | Out-Null
