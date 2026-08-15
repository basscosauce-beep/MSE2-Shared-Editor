
# DedupPreview.ps1
# Launched from GoalTracker. Shows duplicate groups with:
#  - Card art thumbnails (extracted from the .mse-set zip) on each row
#  - Per-card Restore button
#  - Toggle to show/hide delete-pending rows
#  - Undo All button
#  - Confirm and Sync

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Window focus API
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmd);
}
"@

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

    # Read set content
    $z  = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
    $sr = New-Object System.IO.StreamReader(($z.Entries | Where-Object { $_.Name -eq "set" }).Open(), [System.Text.Encoding]::UTF8)
    $setContent = $sr.ReadToEnd(); $sr.Dispose()

    # Extract all images to a temp folder for display
    $imgTmp = "$env:TEMP\mse_dedup_imgs_$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $imgTmp -Force | Out-Null
    foreach ($entry in ($z.Entries | Where-Object { $_.Name -match "\.(png|jpg|jpeg)$" })) {
        $dest = "$imgTmp\$($entry.Name)"
        $s = $entry.Open()
        $fs = [System.IO.File]::Create($dest)
        $s.CopyTo($fs); $fs.Dispose(); $s.Dispose()
    }
    $z.Dispose()

    # Find duplicates
    $groups = Find-DuplicateGroups $setContent
    $totalDupes = ($groups | ForEach-Object { $_.Dupes.Count } | Measure-Object -Sum).Sum

    if ($groups.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No duplicate cards found in your set.`nEverything looks clean!",
            "No Duplicates", "OK", "Information") | Out-Null
        Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue
        exit
    }

    # Restore state: set of "groupIndex_dupeIndex" strings rescued from deletion
    $restoreSet = New-Object System.Collections.Generic.HashSet[string]

    # ---------------------------------------------------------------------------
    # XAML
    # ---------------------------------------------------------------------------
    $xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Delete Duplicates Preview" Height="700" Width="800"
        WindowStartupLocation="CenterScreen" Background="#0A0A14" Foreground="White"
        Topmost="True">
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

    <Border Grid.Row="1" Background="#111" Padding="20,7">
      <TextBlock Name="InfoBar" FontSize="11" Foreground="#888"
         Text="Green = kept (most recently modified).  Dimmed = will be deleted.  Hover card art for a larger view.  Click Restore to rescue a card."/>
    </Border>

    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="14,10,14,10">
      <StackPanel Name="GroupList"/>
    </ScrollViewer>

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

    $subText      = $window.FindName("SubText")
    $groupList    = $window.FindName("GroupList")
    $statusText   = $window.FindName("StatusText")
    $btnCancel    = $window.FindName("BtnCancel")
    $btnConfirm   = $window.FindName("BtnConfirm")
    $btnUndoAll   = $window.FindName("BtnUndoAll")
    $chkShowDel   = $window.FindName("ChkShowDeleted")

    $subText.Text = "$($groups.Count) duplicate group(s) found  -  $totalDupes card(s) queued for deletion"
    $conv = New-Object System.Windows.Media.BrushConverter

    # Drop Topmost after window shows (so it doesn't stay permanently on top)
    $window.add_Loaded({
        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{
                Start-Sleep -Milliseconds 400
                $window.Topmost = $false
            })
    })

    # ---------------------------------------------------------------------------
    # Load a BitmapImage from extracted temp folder
    # ---------------------------------------------------------------------------
    function Get-CardBitmap([string]$imgFile) {
        if (-not $imgFile) { return $null }
        $path = "$imgTmp\$imgFile"
        if (-not (Test-Path $path)) { return $null }
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource  = [Uri]::new($path)
            $bmp.DecodePixelHeight = 180   # thumbnail size
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            return $bmp
        } catch { return $null }
    }

    # ---------------------------------------------------------------------------
    # Build a card art thumbnail + popup on hover
    # ---------------------------------------------------------------------------
    function New-ArtThumbnail([string]$imgFile) {
        $bmp = Get-CardBitmap $imgFile
        if (-not $bmp) {
            $placeholder = New-Object System.Windows.Controls.Border
            $placeholder.Width = 50; $placeholder.Height = 70
            $placeholder.Background = $conv.ConvertFromString("#1E293B")
            $placeholder.CornerRadius = "4"
            $placeholder.Margin = [System.Windows.Thickness]::new(0,0,10,0)
            $placeholder.ToolTip = "No image"
            return $placeholder
        }

        $thumb = New-Object System.Windows.Controls.Image
        $thumb.Source = $bmp
        $thumb.Width  = 50; $thumb.Height = 70
        $thumb.Margin = [System.Windows.Thickness]::new(0,0,10,0)
        $thumb.Cursor = [System.Windows.Input.Cursors]::Hand
        $thumb.SnapsToDevicePixels = $true
        $thumb.RenderOptions.SetBitmapScalingMode($thumb, [System.Windows.Media.BitmapScalingMode]::HighQuality)

        # Large popup on hover
        $popup   = New-Object System.Windows.Controls.Primitives.Popup
        $popup.Placement = "MousePoint"
        $popup.AllowsTransparency = $true
        $popup.StaysOpen = $false

        $largeBmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $imgPath = "$imgTmp\$imgFile"
        try {
            $largeBmp.BeginInit()
            $largeBmp.UriSource = [Uri]::new($imgPath)
            $largeBmp.DecodePixelHeight = 420
            $largeBmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $largeBmp.EndInit()
        } catch { $largeBmp = $bmp }

        $largeImg = New-Object System.Windows.Controls.Image
        $largeImg.Source = $largeBmp; $largeImg.Width = 300; $largeImg.Height = 420
        $shadow = New-Object System.Windows.Controls.Border
        $shadow.Child = $largeImg; $shadow.CornerRadius = "8"
        $shadow.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
        $shadow.Effect.Color = [System.Windows.Media.Colors]::Black
        $shadow.Effect.BlurRadius = 20; $shadow.Effect.Opacity = 0.8
        $popup.Child = $shadow

        $thumb.add_MouseEnter({ $popup.IsOpen = $true  }.GetNewClosure())
        $thumb.add_MouseLeave({ $popup.IsOpen = $false }.GetNewClosure())
        $thumb.add_MouseLeftButtonDown({ $popup.IsOpen = -not $popup.IsOpen }.GetNewClosure())

        return $thumb
    }

    # ---------------------------------------------------------------------------
    # State helpers
    # ---------------------------------------------------------------------------
    $allDupeRows = [System.Collections.Generic.List[object]]::new()

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
    # Build UI
    # ---------------------------------------------------------------------------
    function Build-UI {
        $groupList.Children.Clear()
        $allDupeRows.Clear()

        for ($gi = 0; $gi -lt $groups.Count; $gi++) {
            $g = $groups[$gi]

            # Group container
            $groupBorder = New-Object System.Windows.Controls.Border
            $groupBorder.Background   = $conv.ConvertFromString("#0D1526")
            $groupBorder.Margin       = [System.Windows.Thickness]::new(0,4,0,4)
            $groupBorder.CornerRadius = "6"
            $groupBorder.BorderBrush  = $conv.ConvertFromString("#1E2A4A")
            $groupBorder.BorderThickness = "1"
            $groupSP = New-Object System.Windows.Controls.StackPanel

            # --- KEEPER row ---
            $keeperRow = New-Object System.Windows.Controls.Border
            $keeperRow.Background = $conv.ConvertFromString("#071A0F")
            $keeperRow.Padding    = [System.Windows.Thickness]::new(14,10,14,10)
            $keeperRow.CornerRadius = "6,6,0,0"

            $keeperGrid = New-Object System.Windows.Controls.Grid
            $kc1 = New-Object System.Windows.Controls.ColumnDefinition; $kc1.Width = [System.Windows.GridLength]::Auto
            $kc2 = New-Object System.Windows.Controls.ColumnDefinition; $kc2.Width = [System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)
            $kc3 = New-Object System.Windows.Controls.ColumnDefinition; $kc3.Width = [System.Windows.GridLength]::Auto
            $keeperGrid.ColumnDefinitions.Add($kc1); $keeperGrid.ColumnDefinitions.Add($kc2); $keeperGrid.ColumnDefinitions.Add($kc3)

            # Art thumbnail
            $kArt = New-ArtThumbnail $g.KeeperImageFile
            [System.Windows.Controls.Grid]::SetColumn($kArt, 0)
            $keeperGrid.Children.Add($kArt) | Out-Null

            # Info
            $keeperInfo = New-Object System.Windows.Controls.StackPanel
            $keeperInfo.VerticalAlignment = "Center"
            $kLabel = New-Object System.Windows.Controls.TextBlock
            $kLabel.Text = "[KEEPER]"; $kLabel.Foreground = $conv.ConvertFromString("#4ADE80")
            $kLabel.FontSize = 10; $kLabel.FontWeight = "Bold"
            $kName = New-Object System.Windows.Controls.TextBlock
            $kName.Text = $g.KeeperName; $kName.FontSize = 14; $kName.FontWeight = "SemiBold"
            $kMeta = New-Object System.Windows.Controls.TextBlock
            $kMeta.Text = "creator: $($g.KeeperCreator)   modified: $($g.KeeperModified)"
            $kMeta.FontSize = 10; $kMeta.Foreground = $conv.ConvertFromString("#4B7A5A")
            $keeperInfo.Children.Add($kLabel) | Out-Null
            $keeperInfo.Children.Add($kName)  | Out-Null
            $keeperInfo.Children.Add($kMeta)  | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($keeperInfo, 1)
            $keeperGrid.Children.Add($keeperInfo) | Out-Null

            # Badge
            $badge = New-Object System.Windows.Controls.Border
            $badge.Background   = $conv.ConvertFromString("#14532D")
            $badge.CornerRadius = "10"; $badge.Padding = [System.Windows.Thickness]::new(10,3,10,3)
            $badge.VerticalAlignment = "Center"
            $badgeTB = New-Object System.Windows.Controls.TextBlock
            $badgeTB.Text = "Kept"; $badgeTB.FontSize = 11; $badgeTB.FontWeight = "Bold"
            $badgeTB.Foreground = $conv.ConvertFromString("#4ADE80")
            $badge.Child = $badgeTB
            [System.Windows.Controls.Grid]::SetColumn($badge, 2)
            $keeperGrid.Children.Add($badge) | Out-Null

            $keeperRow.Child = $keeperGrid
            $groupSP.Children.Add($keeperRow) | Out-Null

            # Separator
            $sep = New-Object System.Windows.Controls.Border
            $sep.Background = $conv.ConvertFromString("#1E2A4A"); $sep.Height = 1
            $groupSP.Children.Add($sep) | Out-Null

            # --- DUPE rows ---
            for ($di = 0; $di -lt $g.Dupes.Count; $di++) {
                $d = $g.Dupes[$di]
                $rowKey = "${gi}_${di}"

                $dupeRow = New-Object System.Windows.Controls.Border
                $dupeRow.Padding = [System.Windows.Thickness]::new(14,10,14,10)
                $allDupeRows.Add($dupeRow) | Out-Null

                $dupeGrid = New-Object System.Windows.Controls.Grid
                $dc1 = New-Object System.Windows.Controls.ColumnDefinition; $dc1.Width = [System.Windows.GridLength]::Auto
                $dc2 = New-Object System.Windows.Controls.ColumnDefinition; $dc2.Width = [System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)
                $dc3 = New-Object System.Windows.Controls.ColumnDefinition; $dc3.Width = [System.Windows.GridLength]::Auto
                $dupeGrid.ColumnDefinitions.Add($dc1); $dupeGrid.ColumnDefinitions.Add($dc2); $dupeGrid.ColumnDefinitions.Add($dc3)

                # Art thumbnail
                $dArt = New-ArtThumbnail $d.ImageFile
                [System.Windows.Controls.Grid]::SetColumn($dArt, 0)
                $dupeGrid.Children.Add($dArt) | Out-Null

                # Info
                $dupeInfo = New-Object System.Windows.Controls.StackPanel
                $dupeInfo.VerticalAlignment = "Center"
                $dLabel = New-Object System.Windows.Controls.TextBlock; $dLabel.FontSize = 10; $dLabel.FontWeight = "Bold"
                $dName  = New-Object System.Windows.Controls.TextBlock; $dName.FontSize = 14; $dName.FontWeight = "SemiBold"
                $dMeta  = New-Object System.Windows.Controls.TextBlock; $dMeta.FontSize = 10
                $dMeta.Text = "creator: $($d.Creator)   modified: $($d.TimeModified)"
                $dupeInfo.Children.Add($dLabel) | Out-Null
                $dupeInfo.Children.Add($dName)  | Out-Null
                $dupeInfo.Children.Add($dMeta)  | Out-Null
                [System.Windows.Controls.Grid]::SetColumn($dupeInfo, 1)
                $dupeGrid.Children.Add($dupeInfo) | Out-Null

                # Restore button
                $restBtn = New-Object System.Windows.Controls.Button
                $restBtn.Padding = [System.Windows.Thickness]::new(12,5,12,5)
                $restBtn.FontSize = 11; $restBtn.VerticalAlignment = "Center"
                [System.Windows.Controls.Grid]::SetColumn($restBtn, 2)
                $dupeGrid.Children.Add($restBtn) | Out-Null

                $dupeRow.Child = $dupeGrid
                $groupSP.Children.Add($dupeRow) | Out-Null

                # Captured variables for closures
                $cap_rk    = $rowKey
                $cap_dr    = $dupeRow
                $cap_rb    = $restBtn
                $cap_dl    = $dLabel
                $cap_dn    = $dName
                $cap_dm    = $dMeta
                $cap_str   = $d.Name

                $refreshRow = {
                    param($rk,$dr,$rb,$dl,$dn,$dm,$nameStr)
                    $isRestored = $restoreSet.Contains($rk)
                    if ($isRestored) {
                        $dr.Background   = $conv.ConvertFromString("#071A0F")
                        $dl.Text         = "[RESTORED]"
                        $dl.Foreground   = $conv.ConvertFromString("#4ADE80")
                        $dn.Text         = $nameStr
                        $dn.Foreground   = "White"
                        $dn.TextDecorations = $null
                        $dm.Foreground   = $conv.ConvertFromString("#4B7A5A")
                        $rb.Content      = "Re-delete"
                        $rb.Background   = $conv.ConvertFromString("#7F1D1D")
                        $rb.Foreground   = $conv.ConvertFromString("#FCA5A5")
                    } else {
                        $dr.Background   = $conv.ConvertFromString("#1A0C0C")
                        $dl.Text         = "[DELETE]"
                        $dl.Foreground   = $conv.ConvertFromString("#EF4444")
                        $dn.Text         = $nameStr
                        $dn.Foreground   = $conv.ConvertFromString("#6B7280")
                        $td = New-Object System.Windows.TextDecorationCollection
                        $td.Add([System.Windows.TextDecorations]::Strikethrough)
                        $dn.TextDecorations = $td
                        $dm.Foreground   = $conv.ConvertFromString("#4B3333")
                        $rb.Content      = "Restore"
                        $rb.Background   = $conv.ConvertFromString("#14532D")
                        $rb.Foreground   = $conv.ConvertFromString("#4ADE80")
                    }
                }.GetNewClosure()

                # Initial render
                & $refreshRow $cap_rk $cap_dr $cap_rb $cap_dl $cap_dn $cap_dm $cap_str

                $restBtn.add_Click({
                    if ($restoreSet.Contains($cap_rk)) { $restoreSet.Remove($cap_rk) | Out-Null }
                    else                               { $restoreSet.Add($cap_rk)    | Out-Null }
                    & $refreshRow $cap_rk $cap_dr $cap_rb $cap_dl $cap_dn $cap_dm $cap_str
                    Update-Status
                }.GetNewClosure())
            }

            $groupBorder.Child = $groupSP
            $groupList.Children.Add($groupBorder) | Out-Null
        }

        Update-Status
    }

    Build-UI

    # ---------------------------------------------------------------------------
    # Toggle
    # ---------------------------------------------------------------------------
    $chkShowDel.add_Checked({
        foreach ($r in $allDupeRows) { $r.Visibility = "Visible" }
    })
    $chkShowDel.add_Unchecked({
        foreach ($r in $allDupeRows) { $r.Visibility = "Collapsed" }
    })

    # ---------------------------------------------------------------------------
    # Undo All / Cancel
    # ---------------------------------------------------------------------------
    $btnUndoAll.add_Click({ $restoreSet.Clear(); Build-UI })
    $btnCancel.add_Click({
        Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue
        $window.Close()
    })

    # ---------------------------------------------------------------------------
    # Confirm and Sync
    # ---------------------------------------------------------------------------
    $btnConfirm.add_Click({
        try {
            $finalGroups = [System.Collections.Generic.List[object]]::new()
            for ($gi = 0; $gi -lt $groups.Count; $gi++) {
                $g = $groups[$gi]
                $finalDupes = [System.Collections.Generic.List[object]]::new()
                for ($di = 0; $di -lt $g.Dupes.Count; $di++) {
                    if (-not $restoreSet.Contains("${gi}_${di}")) { $finalDupes.Add($g.Dupes[$di]) }
                }
                if ($finalDupes.Count -gt 0) {
                    $finalGroups.Add(@{
                        TC              = $g.TC
                        KeeperName      = $g.KeeperName
                        KeeperCreator   = $g.KeeperCreator
                        KeeperModified  = $g.KeeperModified
                        KeeperImageFile = $g.KeeperImageFile
                        Dupes           = @($finalDupes)
                    })
                }
            }

            if ($finalGroups.Count -eq 0) {
                [System.Windows.MessageBox]::Show("You restored all duplicates - nothing to delete!", "Nothing to do") | Out-Null
                return
            }

            Write-PendingDedup $setDir $myName @($finalGroups)

            $btnConfirm.IsEnabled = $false; $btnCancel.IsEnabled = $false
            $statusText.Text = "Syncing..."
            Start-Process "powershell.exe" -ArgumentList @(
                "-ExecutionPolicy","Bypass","-WindowStyle","Normal","-File",$syncScript
            )
            Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue
            $window.Close()
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Error") | Out-Null
        }
    })

    $window.ShowDialog() | Out-Null

    # Cleanup temp images if window closed without syncing
    Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue

} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Delete Duplicates Error")
}
