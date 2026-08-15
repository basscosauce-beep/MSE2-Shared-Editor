
# DedupPreview.ps1
# Grid-style duplicate picker: rows = card names, columns = each copy/slot.
# Click a column header to choose which slot to KEEP for that card.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinFocus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
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
    $sr = New-Object System.IO.StreamReader(
        ($z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1).Open(),
        [System.Text.Encoding]::UTF8)
    $setContent = $sr.ReadToEnd(); $sr.Dispose()

    # Extract images to temp folder
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

    if ($groups.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No duplicate cards found in your set.`nEverything looks clean!",
            "No Duplicates", "OK", "Information") | Out-Null
        Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue
        exit
    }

    # keepChoice[gi] = slot index the user chose for group gi (defaults to 0 = newest)
    $keepChoice = @{}
    for ($gi = 0; $gi -lt $groups.Count; $gi++) {
        $keepChoice[$gi] = [int]$groups[$gi].DefaultKeepSlot
    }

    # -----------------------------------------------------------------------
    # XAML shell
    # -----------------------------------------------------------------------
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Delete Duplicates" Height="720" Width="900"
        WindowStartupLocation="CenterScreen" Background="#0C0C14" Foreground="White"
        Topmost="True">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
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
    <Border Grid.Row="0" Background="#12121E" Padding="22,16">
      <StackPanel>
        <TextBlock Text="Delete Duplicates" FontSize="20" FontWeight="Bold" Foreground="#FCA5A5"/>
        <TextBlock Name="SubText" FontSize="12" Foreground="#888" Margin="0,4,0,0"/>
      </StackPanel>
    </Border>

    <!-- Legend -->
    <Border Grid.Row="1" Background="#0E0E18" Padding="22,8">
      <StackPanel Orientation="Horizontal">
        <Border Background="#14532D" CornerRadius="4" Padding="8,3" Margin="0,0,10,0">
          <TextBlock Text="GREEN = KEEP" FontSize="10" FontWeight="Bold" Foreground="#4ADE80"/>
        </Border>
        <Border Background="#4A1414" CornerRadius="4" Padding="8,3" Margin="0,0,16,0">
          <TextBlock Text="RED = DELETE" FontSize="10" FontWeight="Bold" Foreground="#FCA5A5"/>
        </Border>
        <TextBlock Text="Click any column to choose which copy to keep. Hover card art to preview." FontSize="11" Foreground="#666" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>

    <!-- Card grid -->
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="14,12">
      <StackPanel Name="GroupList"/>
    </ScrollViewer>

    <!-- Footer -->
    <Border Grid.Row="3" Background="#10101C" Padding="22,14">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Name="StatusText" Grid.Column="0" VerticalAlignment="Center"
                   Foreground="#888" FontSize="11"/>
        <Button Name="BtnCancel" Grid.Column="1" Content="Cancel"
                Background="#2D2D3D" Padding="18,10" Margin="0,0,10,0" FontSize="13"/>
        <Button Name="BtnConfirm" Grid.Column="2" Content="Confirm and Sync"
                Background="#7F1D1D" FontWeight="Bold" Padding="22,10" FontSize="13"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $xml    = [xml]$xaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $subText    = $window.FindName("SubText")
    $groupList  = $window.FindName("GroupList")
    $statusText = $window.FindName("StatusText")
    $btnCancel  = $window.FindName("BtnCancel")
    $btnConfirm = $window.FindName("BtnConfirm")

    $totalCopies = ($groups | ForEach-Object { $_.AllCopies.Count } | Measure-Object -Sum).Sum
    $totalDeleted = $totalCopies - $groups.Count   # one kept per group
    $subText.Text = "$($groups.Count) duplicate group(s)  --  $totalDeleted redundant cop$(if($totalDeleted -ne 1){'ies'}else{'y'}) found"

    $conv = New-Object System.Windows.Media.BrushConverter

    # Drop Topmost after load
    $window.add_Loaded({
        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Start-Sleep -Milliseconds 300; $window.Topmost = $false })
    })

    # -----------------------------------------------------------------------
    # Load a card art bitmap from temp folder
    # -----------------------------------------------------------------------
    function Get-CardBitmap([string]$imgFile, [int]$decodeH) {
        if (-not $imgFile) { return $null }
        $path = "$imgTmp\$imgFile"
        if (-not (Test-Path $path)) { return $null }
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource       = [Uri]::new($path)
            $bmp.DecodePixelHeight = $decodeH
            $bmp.CacheOption     = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            return $bmp
        } catch { return $null }
    }

    # -----------------------------------------------------------------------
    # Build one card cell (for a single copy/slot)
    # Returns a Border that lights up green or red based on selection
    # -----------------------------------------------------------------------
    $allCells = [System.Collections.Generic.List[object]]::new()   # @{ Border; gi; si }

    function New-CardCell($copy, [int]$gi, [int]$si) {

        $cell = New-Object System.Windows.Controls.Border
        $cell.CornerRadius   = "6"
        $cell.Margin         = [System.Windows.Thickness]::new(4, 0, 4, 0)
        $cell.Padding        = [System.Windows.Thickness]::new(10, 10, 10, 12)
        $cell.Cursor         = [System.Windows.Input.Cursors]::Hand
        $cell.BorderThickness = "2"
        $cell.MinWidth       = 120

        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.HorizontalAlignment = "Center"

        # --- Card art ---
        $thumb = New-Object System.Windows.Controls.Border
        $thumb.Width = 80; $thumb.Height = 112
        $thumb.CornerRadius = "4"
        $thumb.Background = $conv.ConvertFromString("#1A1A2E")
        $thumb.HorizontalAlignment = "Center"
        $thumb.Margin = [System.Windows.Thickness]::new(0,0,0,8)

        $bmp = Get-CardBitmap $copy.ImageFile 112
        if ($bmp) {
            $img = New-Object System.Windows.Controls.Image
            $img.Source  = $bmp
            $img.Stretch = "UniformToFill"
            $img.HorizontalAlignment = "Center"
            $img.VerticalAlignment   = "Center"
            $thumb.Child = $img

            # Hover popup for full-size preview
            $popup = New-Object System.Windows.Controls.Primitives.Popup
            $popup.Placement = "MousePoint"
            $popup.AllowsTransparency = $true
            $popup.StaysOpen = $false

            $largeBmp = Get-CardBitmap $copy.ImageFile 420
            if ($largeBmp) {
                $largeImg = New-Object System.Windows.Controls.Image
                $largeImg.Source = $largeBmp; $largeImg.Width = 300; $largeImg.Height = 420
                $shadow = New-Object System.Windows.Controls.Border
                $shadow.Child = $largeImg; $shadow.CornerRadius = "8"
                $eff = New-Object System.Windows.Media.Effects.DropShadowEffect
                $eff.Color = [System.Windows.Media.Colors]::Black
                $eff.BlurRadius = 24; $eff.Opacity = 0.85
                $shadow.Effect = $eff
                $popup.Child = $shadow
            }
            $cap_popup = $popup
            $thumb.add_MouseEnter({ $cap_popup.IsOpen = $true  }.GetNewClosure())
            $thumb.add_MouseLeave({ $cap_popup.IsOpen = $false }.GetNewClosure())
        }
        $sp.Children.Add($thumb) | Out-Null

        # --- Slot number label ---
        $slotLabel = New-Object System.Windows.Controls.TextBlock
        $slotLabel.Text = "Slot $($si + 1)"
        $slotLabel.FontSize = 10; $slotLabel.FontWeight = "Bold"
        $slotLabel.HorizontalAlignment = "Center"
        $slotLabel.Margin = [System.Windows.Thickness]::new(0,0,0,4)
        $sp.Children.Add($slotLabel) | Out-Null

        # --- Creator ---
        $creatorTB = New-Object System.Windows.Controls.TextBlock
        $creatorTB.Text = $copy.Creator
        $creatorTB.FontSize = 10
        $creatorTB.HorizontalAlignment = "Center"
        $creatorTB.TextWrapping = "Wrap"
        $creatorTB.MaxWidth = 110
        $sp.Children.Add($creatorTB) | Out-Null

        # --- Modified date (short) ---
        $modRaw = $copy.TimeModified
        $modShort = if ($modRaw -match "(\d{4}-\d{2}-\d{2})") { $matches[1] } else { $modRaw }
        $modTB = New-Object System.Windows.Controls.TextBlock
        $modTB.Text = $modShort; $modTB.FontSize = 10
        $modTB.Foreground = $conv.ConvertFromString("#888")
        $modTB.HorizontalAlignment = "Center"
        $modTB.Margin = [System.Windows.Thickness]::new(0,2,0,0)
        $sp.Children.Add($modTB) | Out-Null

        # --- KEEP badge (shown when selected) ---
        $keepBadge = New-Object System.Windows.Controls.Border
        $keepBadge.Background   = $conv.ConvertFromString("#14532D")
        $keepBadge.CornerRadius = "8"
        $keepBadge.Padding      = [System.Windows.Thickness]::new(8,2,8,2)
        $keepBadge.Margin       = [System.Windows.Thickness]::new(0,6,0,0)
        $keepBadge.HorizontalAlignment = "Center"
        $keepBadgeTB = New-Object System.Windows.Controls.TextBlock
        $keepBadgeTB.Text = ">> KEEP"
        $keepBadgeTB.FontSize = 10; $keepBadgeTB.FontWeight = "Bold"
        $keepBadgeTB.Foreground = $conv.ConvertFromString("#4ADE80")
        $keepBadge.Child = $keepBadgeTB
        $sp.Children.Add($keepBadge) | Out-Null

        $cell.Child = $sp

        # Store references for refresh
        $cellObj = @{
            Border    = $cell
            KeepBadge = $keepBadge
            SlotLabel = $slotLabel
            gi        = $gi
            si        = $si
        }
        $allCells.Add($cellObj) | Out-Null

        return $cell
    }

    # -----------------------------------------------------------------------
    # Refresh all cells in a group to show which is kept vs deleted
    # -----------------------------------------------------------------------
    function Refresh-Group([int]$gi) {
        $chosen = $keepChoice[$gi]
        foreach ($cellObj in $allCells) {
            if ($cellObj.gi -ne $gi) { continue }
            $si = $cellObj.si
            $border = $cellObj.Border
            $badge  = $cellObj.KeepBadge
            $lbl    = $cellObj.SlotLabel

            if ($si -eq $chosen) {
                $border.Background   = $conv.ConvertFromString("#071A0F")
                $border.BorderBrush  = $conv.ConvertFromString("#4ADE80")
                $lbl.Foreground      = $conv.ConvertFromString("#4ADE80")
                $badge.Visibility    = "Visible"
            } else {
                $border.Background   = $conv.ConvertFromString("#1A0A0A")
                $border.BorderBrush  = $conv.ConvertFromString("#4A1414")
                $lbl.Foreground      = $conv.ConvertFromString("#EF4444")
                $badge.Visibility    = "Collapsed"
            }
        }
    }

    function Update-Status {
        $deleteCount = $groups.Count  # one deleted per group minimum
        for ($gi = 0; $gi -lt $groups.Count; $gi++) {
            $deleteCount += $groups[$gi].AllCopies.Count - 1  # all but the keeper
        }
        $deleteCount = ($groups | ForEach-Object { $_.AllCopies.Count - 1 } | Measure-Object -Sum).Sum
        $statusText.Text = "$deleteCount card(s) will be deleted -- one copy of each kept"
    }

    # -----------------------------------------------------------------------
    # Build the grid UI
    # -----------------------------------------------------------------------
    $groupList.Children.Clear()
    $allCells.Clear()

    for ($gi = 0; $gi -lt $groups.Count; $gi++) {
        $g = $groups[$gi]

        # Outer group container
        $groupBorder = New-Object System.Windows.Controls.Border
        $groupBorder.Background      = $conv.ConvertFromString("#0E0E1E")
        $groupBorder.Margin          = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $groupBorder.CornerRadius    = "8"
        $groupBorder.BorderBrush     = $conv.ConvertFromString("#1E1E3A")
        $groupBorder.BorderThickness = "1"
        $groupBorder.Padding         = [System.Windows.Thickness]::new(16, 14, 16, 14)

        $groupSP = New-Object System.Windows.Controls.StackPanel

        # Card name header
        $nameRow = New-Object System.Windows.Controls.StackPanel
        $nameRow.Orientation = "Horizontal"
        $nameRow.Margin      = [System.Windows.Thickness]::new(0,0,0,12)

        $nameTB = New-Object System.Windows.Controls.TextBlock
        $nameTB.Text       = $g.CardName
        $nameTB.FontSize   = 15
        $nameTB.FontWeight = "SemiBold"
        $nameTB.VerticalAlignment = "Center"
        $nameRow.Children.Add($nameTB) | Out-Null

        $countBadge = New-Object System.Windows.Controls.Border
        $countBadge.Background   = $conv.ConvertFromString("#1E1E3A")
        $countBadge.CornerRadius = "10"
        $countBadge.Padding      = [System.Windows.Thickness]::new(8,2,8,2)
        $countBadge.Margin       = [System.Windows.Thickness]::new(10,0,0,0)
        $countBadge.VerticalAlignment = "Center"
        $countTB = New-Object System.Windows.Controls.TextBlock
        $countTB.Text       = "$($g.AllCopies.Count) copies"
        $countTB.FontSize   = 10
        $countTB.Foreground = $conv.ConvertFromString("#888")
        $countBadge.Child   = $countTB
        $nameRow.Children.Add($countBadge) | Out-Null

        $instructTB = New-Object System.Windows.Controls.TextBlock
        $instructTB.Text       = "  <- click a column to choose which to keep"
        $instructTB.FontSize   = 10
        $instructTB.Foreground = $conv.ConvertFromString("#555")
        $instructTB.VerticalAlignment = "Center"
        $nameRow.Children.Add($instructTB) | Out-Null

        $groupSP.Children.Add($nameRow) | Out-Null

        # Horizontal row of card cells
        $cellRow = New-Object System.Windows.Controls.WrapPanel
        $cellRow.Orientation = "Horizontal"

        for ($si = 0; $si -lt $g.AllCopies.Count; $si++) {
            $copy = $g.AllCopies[$si]
            $cell = New-CardCell $copy $gi $si

            # Click = choose this slot
            $cap_gi = $gi; $cap_si = $si
            $cell.add_MouseLeftButtonDown({
                $keepChoice[$cap_gi] = $cap_si
                Refresh-Group $cap_gi
                Update-Status
            }.GetNewClosure())

            $cellRow.Children.Add($cell) | Out-Null
        }

        $groupSP.Children.Add($cellRow) | Out-Null
        $groupBorder.Child = $groupSP
        $groupList.Children.Add($groupBorder) | Out-Null

        Refresh-Group $gi
    }

    Update-Status

    # -----------------------------------------------------------------------
    # Cancel
    # -----------------------------------------------------------------------
    $btnCancel.add_Click({
        Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue
        $window.Close()
    })

    # -----------------------------------------------------------------------
    # Confirm and Sync
    # -----------------------------------------------------------------------
    $btnConfirm.add_Click({
        try {
            $finalGroups = [System.Collections.Generic.List[object]]::new()
            for ($gi = 0; $gi -lt $groups.Count; $gi++) {
                $g = $groups[$gi]
                $finalGroups.Add(@{
                    TC              = $g.TC
                    CardName        = $g.CardName
                    AllCopies       = $g.AllCopies
                    ChosenKeepSlot  = [int]$keepChoice[$gi]
                })
            }

            Write-PendingDedup $setDir $myName @($finalGroups)

            $btnConfirm.IsEnabled = $false
            $btnCancel.IsEnabled  = $false
            $statusText.Text      = "Syncing..."

            Start-Process "powershell.exe" -ArgumentList @(
                "-ExecutionPolicy","Bypass","-WindowStyle","Normal","-File",$syncScript)

            Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue
            $window.Close()
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Error") | Out-Null
        }
    })

    $window.ShowDialog() | Out-Null
    Remove-Item $imgTmp -Recurse -Force -ErrorAction SilentlyContinue

} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Delete Duplicates Error")
}
