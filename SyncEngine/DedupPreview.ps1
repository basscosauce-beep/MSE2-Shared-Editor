
# DedupPreview.ps1
# Standalone Delete Duplicates preview window.
# Launched from GoalTracker. Shows all duplicate groups, lets the user
# restore individual cards, toggle visibility of pending deletions,
# and either confirm (writes pending_dedup.json + syncs) or undo everything.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web.Extensions

try {
    $appData    = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"
    $syncScript = "$appData\SyncEngine\SyncNow.ps1"
    . "$appData\SyncEngine\DedupManager.ps1"

    $creatorFile = "$appData\creator.txt"
    $myName = if (Test-Path $creatorFile) { (Get-Content $creatorFile -Raw).Trim() } else { "Unknown" }

    $setFile = Get-ChildItem "$appData\Shared-Set" -Recurse -Filter "*.mse-set" |
        Where-Object { $_.Name -notlike "*.bak" -and $_.FullName -notlike "*\_pre_sync_backups\*" } |
        Select-Object -First 1
    if (-not $setFile) { throw "Could not find the shared set file." }

    $setDir = $setFile.DirectoryName

    # Read and parse the set
    $z  = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
    $sr = New-Object System.IO.StreamReader(($z.Entries | Where-Object { $_.Name -eq "set" }).Open(), [System.Text.Encoding]::UTF8)
    $setContent = $sr.ReadToEnd(); $sr.Dispose(); $z.Dispose()

    # Find duplicate groups
    $groups = Find-DuplicateGroups $setContent
    $totalDupes = ($groups | ForEach-Object { $_.Dupes.Count } | Measure-Object -Sum).Sum

    if ($groups.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No duplicate cards found in your set.`nEverything looks clean!",
            "No Duplicates", "OK", "Information") | Out-Null
        exit
    }

    # ---------------------------------------------------------------------------
    # State: per-group, track which dupes have been restored
    # restoreSet = HashSet of (groupIndex_dupeIndex) strings that are restored
    # ---------------------------------------------------------------------------
    $restoreSet = New-Object System.Collections.Generic.HashSet[string]

    # ---------------------------------------------------------------------------
    # XAML
    # ---------------------------------------------------------------------------
    $xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Delete Duplicates Preview" Height="680" Width="760"
        WindowStartupLocation="CenterScreen" Background="#0A0A14" Foreground="White">
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
      <Setter Property="FontFamily" Value="Segoe UI"/>
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
    <Border Grid.Row="0" Background="#1A0A0A" Padding="20,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Name="TitleText" Text="Delete Duplicates" FontSize="18" FontWeight="Bold" Foreground="#FCA5A5"/>
          <TextBlock Name="SubText" FontSize="11" Foreground="#888" Margin="0,3,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox Name="ChkShowDeleted" Content="Show pending deletions" IsChecked="True"
                    Foreground="#AAA" VerticalAlignment="Center" Margin="0,0,14,0" FontSize="12"/>
          <Button Name="BtnUndoAll" Content="Undo All" Background="#374151" Padding="12,6"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Info bar -->
    <Border Grid.Row="1" Background="#111" Padding="20,7">
      <TextBlock Name="InfoBar" FontSize="11" Foreground="#888"
                 Text="Green = kept (most recently modified).  Gray = will be deleted.  Click Restore to rescue a card."/>
    </Border>

    <!-- Card list -->
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="16,10,16,10">
      <StackPanel Name="GroupList"/>
    </ScrollViewer>

    <!-- Footer -->
    <Border Grid.Row="3" Background="#0F1629" Padding="20,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Name="StatusText" Grid.Column="0" VerticalAlignment="Center"
                   Foreground="#888" FontSize="11"/>
        <Button Name="BtnCancel" Grid.Column="1" Content="Cancel" Background="#374151"
                Padding="16,9" Margin="0,0,10,0"/>
        <Button Name="BtnConfirm" Grid.Column="2" Content="Confirm and Sync"
                Background="#B91C1C" FontWeight="Bold" Padding="20,9"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $xml    = [xml]$xamlStr
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $titleText    = $window.FindName("TitleText")
    $subText      = $window.FindName("SubText")
    $infoBar      = $window.FindName("InfoBar")
    $groupList    = $window.FindName("GroupList")
    $statusText   = $window.FindName("StatusText")
    $btnCancel    = $window.FindName("BtnCancel")
    $btnConfirm   = $window.FindName("BtnConfirm")
    $btnUndoAll   = $window.FindName("BtnUndoAll")
    $chkShowDel   = $window.FindName("ChkShowDeleted")

    $subText.Text = "$($groups.Count) duplicate group(s) found  -  $totalDupes card(s) queued for deletion"
    $conv = New-Object System.Windows.Media.BrushConverter

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------
    function Get-PendingDeleteCount {
        $n = 0
        for ($gi = 0; $gi -lt $groups.Count; $gi++) {
            for ($di = 0; $di -lt $groups[$gi].Dupes.Count; $di++) {
                if (-not $restoreSet.Contains("${gi}_${di}")) { $n++ }
            }
        }
        return $n
    }

    function Update-Status {
        $pending = Get-PendingDeleteCount
        $statusText.Text = "$pending card(s) will be deleted  |  $($restoreSet.Count) rescued"
    }

    # ---------------------------------------------------------------------------
    # Build the card rows — called once, but restore buttons update state live
    # ---------------------------------------------------------------------------
    $allDupeRows  = [System.Collections.Generic.List[object]]::new()   # track all dupe row borders for toggle

    function Build-UI {
        $groupList.Children.Clear()
        $allDupeRows.Clear()

        for ($gi = 0; $gi -lt $groups.Count; $gi++) {
            $g = $groups[$gi]
            $capturedGi = $gi

            # Group container
            $groupBorder = New-Object System.Windows.Controls.Border
            $groupBorder.Background   = $conv.ConvertFromString("#0D1526")
            $groupBorder.Margin       = [System.Windows.Thickness]::new(0,4,0,4)
            $groupBorder.Padding      = [System.Windows.Thickness]::new(0)
            $groupBorder.CornerRadius = "6"
            $groupBorder.BorderBrush  = $conv.ConvertFromString("#1E2A4A")
            $groupBorder.BorderThickness = "1"
            $groupSP = New-Object System.Windows.Controls.StackPanel

            # --- KEEPER row ---
            $keeperRow = New-Object System.Windows.Controls.Border
            $keeperRow.Background   = $conv.ConvertFromString("#071A0F")
            $keeperRow.Padding      = [System.Windows.Thickness]::new(14,10,14,10)
            $keeperRow.CornerRadius = "6,6,0,0"
            $keeperGrid = New-Object System.Windows.Controls.Grid
            $kc1 = New-Object System.Windows.Controls.ColumnDefinition
            $kc1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $kc2 = New-Object System.Windows.Controls.ColumnDefinition
            $kc2.Width = [System.Windows.GridLength]::Auto
            $keeperGrid.ColumnDefinitions.Add($kc1); $keeperGrid.ColumnDefinitions.Add($kc2)

            $keeperInfo = New-Object System.Windows.Controls.StackPanel
            $keeperLabel = New-Object System.Windows.Controls.TextBlock
            $keeperLabel.Text = "[KEEPER]"
            $keeperLabel.Foreground = $conv.ConvertFromString("#4ADE80")
            $keeperLabel.FontSize = 10; $keeperLabel.FontWeight = "Bold"
            $keeperName = New-Object System.Windows.Controls.TextBlock
            $keeperName.Text = $g.KeeperName
            $keeperName.FontSize = 14; $keeperName.FontWeight = "SemiBold"
            $keeperMeta = New-Object System.Windows.Controls.TextBlock
            $keeperMeta.Text = "creator: $($g.KeeperCreator)   modified: $($g.KeeperModified)"
            $keeperMeta.FontSize = 10; $keeperMeta.Foreground = $conv.ConvertFromString("#4B7A5A")
            $keeperInfo.Children.Add($keeperLabel) | Out-Null
            $keeperInfo.Children.Add($keeperName)  | Out-Null
            $keeperInfo.Children.Add($keeperMeta)  | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($keeperInfo, 0)
            $keeperGrid.Children.Add($keeperInfo) | Out-Null

            $keeperBadge = New-Object System.Windows.Controls.Border
            $keeperBadge.Background   = $conv.ConvertFromString("#14532D")
            $keeperBadge.CornerRadius = "10"
            $keeperBadge.Padding      = [System.Windows.Thickness]::new(10,3,10,3)
            $keeperBadge.VerticalAlignment = "Center"
            $kb = New-Object System.Windows.Controls.TextBlock
            $kb.Text = "Kept"; $kb.FontSize = 11; $kb.FontWeight = "Bold"
            $kb.Foreground = $conv.ConvertFromString("#4ADE80")
            $keeperBadge.Child = $kb
            [System.Windows.Controls.Grid]::SetColumn($keeperBadge, 1)
            $keeperGrid.Children.Add($keeperBadge) | Out-Null

            $keeperRow.Child = $keeperGrid
            $groupSP.Children.Add($keeperRow) | Out-Null

            # Separator
            $sep = New-Object System.Windows.Controls.Border
            $sep.Background = $conv.ConvertFromString("#1E2A4A")
            $sep.Height = 1
            $groupSP.Children.Add($sep) | Out-Null

            # --- DUPE rows ---
            for ($di = 0; $di -lt $g.Dupes.Count; $di++) {
                $d = $g.Dupes[$di]
                $capturedDi = $di
                $rowKey = "${capturedGi}_${capturedDi}"

                $dupeRow = New-Object System.Windows.Controls.Border
                $dupeRow.Padding = [System.Windows.Thickness]::new(14,10,14,10)
                $allDupeRows.Add($dupeRow) | Out-Null

                $dupeGrid = New-Object System.Windows.Controls.Grid
                $dc1 = New-Object System.Windows.Controls.ColumnDefinition
                $dc1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
                $dc2 = New-Object System.Windows.Controls.ColumnDefinition
                $dc2.Width = [System.Windows.GridLength]::Auto
                $dupeGrid.ColumnDefinitions.Add($dc1); $dupeGrid.ColumnDefinitions.Add($dc2)

                $dupeInfo = New-Object System.Windows.Controls.StackPanel
                $dupeLabel = New-Object System.Windows.Controls.TextBlock
                $dupeLabel.FontSize = 10; $dupeLabel.FontWeight = "Bold"
                $dupeName = New-Object System.Windows.Controls.TextBlock
                $dupeName.FontSize = 14; $dupeName.FontWeight = "SemiBold"
                $dupeMeta = New-Object System.Windows.Controls.TextBlock
                $dupeMeta.Text = "creator: $($d.Creator)   modified: $($d.TimeModified)"
                $dupeMeta.FontSize = 10
                $dupeInfo.Children.Add($dupeLabel) | Out-Null
                $dupeInfo.Children.Add($dupeName)  | Out-Null
                $dupeInfo.Children.Add($dupeMeta)  | Out-Null
                [System.Windows.Controls.Grid]::SetColumn($dupeInfo, 0)
                $dupeGrid.Children.Add($dupeInfo) | Out-Null

                $restoreBtn = New-Object System.Windows.Controls.Button
                $restoreBtn.Padding    = [System.Windows.Thickness]::new(12,5,12,5)
                $restoreBtn.FontSize   = 11
                $restoreBtn.VerticalAlignment = "Center"
                [System.Windows.Controls.Grid]::SetColumn($restoreBtn, 1)
                $dupeGrid.Children.Add($restoreBtn) | Out-Null
                $dupeRow.Child = $dupeGrid
                $groupSP.Children.Add($dupeRow) | Out-Null

                # Closure captures
                $capturedRowKey     = $rowKey
                $capturedDupeRow    = $dupeRow
                $capturedRestoreBtn = $restoreBtn
                $capturedDupeLabel  = $dupeLabel
                $capturedDupeName   = $dupeName
                $capturedDupeMeta   = $dupeMeta
                $capturedDupeNameStr= $d.Name

                # Function to refresh this row's appearance based on restore state
                $refreshRow = {
                    param($rk, $dr, $rb, $dl, $dn, $dm, $nameStr)
                    $isRestored = $restoreSet.Contains($rk)
                    if ($isRestored) {
                        $dr.Background = $conv.ConvertFromString("#071A0F")
                        $dl.Text = "[RESTORED]"
                        $dl.Foreground = $conv.ConvertFromString("#4ADE80")
                        $dn.Text = $nameStr
                        $dn.Foreground = "White"
                        $dn.TextDecorations = $null
                        $dm.Foreground = $conv.ConvertFromString("#4B7A5A")
                        $rb.Content = "Re-delete"
                        $rb.Background = $conv.ConvertFromString("#7F1D1D")
                        $rb.Foreground = $conv.ConvertFromString("#FCA5A5")
                    } else {
                        $dr.Background = $conv.ConvertFromString("#1A0C0C")
                        $dl.Text = "[DELETE]"
                        $dl.Foreground = $conv.ConvertFromString("#EF4444")
                        $dn.Text = $nameStr
                        $dn.Foreground = $conv.ConvertFromString("#6B7280")
                        # Strikethrough
                        $td = New-Object System.Windows.TextDecorationCollection
                        $td.Add([System.Windows.TextDecorations]::Strikethrough)
                        $dn.TextDecorations = $td
                        $dm.Foreground = $conv.ConvertFromString("#4B3333")
                        $rb.Content = "Restore"
                        $rb.Background = $conv.ConvertFromString("#14532D")
                        $rb.Foreground = $conv.ConvertFromString("#4ADE80")
                    }
                }.GetNewClosure()

                # Initial render
                & $refreshRow $capturedRowKey $capturedDupeRow $capturedRestoreBtn $capturedDupeLabel $capturedDupeName $capturedDupeMeta $capturedDupeNameStr

                $restoreBtn.add_Click({
                    if ($restoreSet.Contains($capturedRowKey)) {
                        $restoreSet.Remove($capturedRowKey) | Out-Null
                    } else {
                        $restoreSet.Add($capturedRowKey) | Out-Null
                    }
                    & $refreshRow $capturedRowKey $capturedDupeRow $capturedRestoreBtn $capturedDupeLabel $capturedDupeName $capturedDupeMeta $capturedDupeNameStr
                    Update-Status
                }.GetNewClosure())
            }

            $groupBorder.Child = $groupSP
            $groupList.Children.Add($groupBorder) | Out-Null
        }

        Update-Status
    }

    # Build initial UI
    Build-UI

    # ---------------------------------------------------------------------------
    # Toggle: Show/Hide pending deletions
    # ---------------------------------------------------------------------------
    $chkShowDel.add_Checked({
        foreach ($row in $allDupeRows) {
            $row.Visibility = "Visible"
        }
    })
    $chkShowDel.add_Unchecked({
        foreach ($row in $allDupeRows) {
            # Only hide rows that are still marked for deletion (not restored)
            $row.Visibility = "Collapsed"
        }
    })

    # ---------------------------------------------------------------------------
    # Undo All
    # ---------------------------------------------------------------------------
    $btnUndoAll.add_Click({
        $restoreSet.Clear()
        Build-UI   # rebuild from scratch
        Update-Status
    })

    # ---------------------------------------------------------------------------
    # Cancel
    # ---------------------------------------------------------------------------
    $btnCancel.add_Click({ $window.Close() })

    # ---------------------------------------------------------------------------
    # Confirm and Sync
    # ---------------------------------------------------------------------------
    $btnConfirm.add_Click({
        try {
            # Build final groups: remove any dupes that were restored
            $finalGroups = [System.Collections.Generic.List[object]]::new()
            for ($gi = 0; $gi -lt $groups.Count; $gi++) {
                $g = $groups[$gi]
                $finalDupes = [System.Collections.Generic.List[object]]::new()
                for ($di = 0; $di -lt $g.Dupes.Count; $di++) {
                    $rk = "${gi}_${di}"
                    if (-not $restoreSet.Contains($rk)) {
                        $finalDupes.Add($g.Dupes[$di])
                    }
                }
                if ($finalDupes.Count -gt 0) {
                    $finalGroups.Add(@{
                        TC             = $g.TC
                        KeeperName     = $g.KeeperName
                        KeeperCreator  = $g.KeeperCreator
                        KeeperModified = $g.KeeperModified
                        KeeperBlock    = $g.KeeperBlock
                        Dupes          = @($finalDupes)
                    })
                }
            }

            if ($finalGroups.Count -eq 0) {
                [System.Windows.MessageBox]::Show("You restored all duplicates - nothing to delete!", "Nothing to do") | Out-Null
                return
            }

            # Write pending_dedup.json
            Write-PendingDedup $setDir $myName @($finalGroups)

            # Launch sync immediately
            $btnConfirm.IsEnabled = $false
            $btnCancel.IsEnabled  = $false
            $statusText.Text = "Syncing..."
            $syncArgs = @(
                "-ExecutionPolicy", "Bypass",
                "-WindowStyle",     "Normal",
                "-File",            $syncScript
            )
            Start-Process "powershell.exe" -ArgumentList $syncArgs
            $window.Close()
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Error") | Out-Null
        }
    })

    $window.ShowDialog() | Out-Null

} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Delete Duplicates Error")
}
