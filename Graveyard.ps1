Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

try {
    $appData = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"
    $gitExe  = "$appData\mingit\cmd\git.exe"
    $env:GIT_TERMINAL_PROMPT = "0"

    $creatorFile = "$appData\creator.txt"
    $myName = if (Test-Path $creatorFile) { (Get-Content $creatorFile -Raw).Trim() } else { "Unknown" }

    $setFile = Get-ChildItem "$appData\Shared-Set" -Recurse -Filter "*.mse-set" |
        Where-Object { $_.Name -notlike "*.bak" } | Select-Object -First 1
    if (-not $setFile) { throw "Could not find the shared set file." }

    $setDir        = $setFile.DirectoryName
    $tombstoneFile = "$setDir\deleted_cards.txt"
    $safeUser      = $myName -replace '[\\/:*?"<>|]', '_'
    $draftFile     = "$setDir\draft_cards_${safeUser}.txt"

    # =========================================================================
    # XAML
    # =========================================================================
    $xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Graveyard" Height="720" Width="600"
        WindowStartupLocation="CenterScreen" Background="#1A1A2E" Foreground="White">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#3D3D5C"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Background" Value="#16213E"/>
      <Setter Property="Foreground" Value="#AAA"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border Name="Bd" Background="{TemplateBinding Background}" CornerRadius="4,4,0,0" Margin="0,0,2,0">
              <ContentPresenter ContentSource="Header" Margin="12,4"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E94560"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#2A2A5A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="&#x2620;  Graveyard" FontSize="22" FontWeight="Bold" Foreground="#E94560"/>
      <TextBlock Text="Cards that existed in the last 7 days but are no longer in your set."
                 FontSize="12" Foreground="#888" Margin="0,4,0,0"/>
    </StackPanel>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
      <TextBlock Name="StatusText" Text="Scanning git history..." VerticalAlignment="Center" Foreground="#AAA" FontSize="12"/>
      <Button Name="BtnRescan" Content="Rescan" Margin="12,0,0,0" Padding="10,4"/>
    </StackPanel>
    <TabControl Grid.Row="2" Name="Tabs" Background="#16213E" BorderThickness="0" Padding="8">
      <TabItem Header="Recently Deleted" Name="TabDeleted">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Name="PanelDeleted" Margin="0,8,0,0"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Accidentally Lost" Name="TabLost">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Name="PanelLost" Margin="0,8,0,0"/>
        </ScrollViewer>
      </TabItem>
    </TabControl>
  </Grid>
</Window>
'@

    $xaml   = [xml]$xamlStr
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $statusText = $window.FindName("StatusText")
    $panelDel   = $window.FindName("PanelDeleted")
    $panelLost  = $window.FindName("PanelLost")
    $btnRescan  = $window.FindName("BtnRescan")

    $window.Title = "Graveyard - $($setFile.BaseName)"

    # =========================================================================
    # Helpers
    # =========================================================================
    function Read-ZipSet([string]$path) {
        try {
            $z = [System.IO.Compression.ZipFile]::OpenRead($path)
            $e = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
            if (-not $e) { $z.Dispose(); return $null }
            $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $sr.Dispose(); $z.Dispose()
            return $txt
        } catch { return $null }
    }

    function Parse-Cards([string]$content) {
        $map = @{}
        if (-not $content) { return $map }
        $content -split "(?m)^(?=card:)" | Where-Object { $_ -match "^card:" } | ForEach-Object {
            $block = ($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            if ($block -match "(?m)^\s*time_created:\s*([^\r\n]+)") {
                $tc = $matches[1].Trim()
                if (-not $map.ContainsKey($tc)) { $map[$tc] = $block }
            }
        }
        return $map
    }

    function New-EmptyMsg([string]$text) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.Foreground = "#555"
        $tb.FontStyle = "Italic"
        $tb.Margin = "0,20,0,0"
        $tb.HorizontalAlignment = "Center"
        return $tb
    }

    function New-CardTile($entry, [bool]$isDeleted) {
        $name    = if ($entry.CardBlock -match "(?m)^\s*name:\s*(.+)")    { $matches[1].Trim() } else { "(unnamed)" }
        $creator = if ($entry.CardBlock -match "(?m)^\s*creator:\s*(.+)") { $matches[1].Trim() } else { "?" }
        $rarity  = if ($entry.CardBlock -match "(?m)^\s*rarity:\s*(.+)")  { $matches[1].Trim() } else { "" }
        $tc      = $entry.TimeCreated
        $lastSeen= $entry.LastSeen

        $age    = (Get-Date) - $lastSeen
        $ageStr = if ($age.TotalMinutes -lt 60) { "$([int]$age.TotalMinutes) min ago" }
                  elseif ($age.TotalHours -lt 24) { "$([int]$age.TotalHours)h ago" }
                  else { "$([int]$age.TotalDays)d ago" }

        $conv = New-Object System.Windows.Media.BrushConverter

        $border = New-Object System.Windows.Controls.Border
        $border.Background  = $conv.ConvertFromString("#16213E")
        $border.BorderBrush = $conv.ConvertFromString($(if ($isDeleted) { "#E94560" } else { "#0F3460" }))
        $border.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 2)
        $border.CornerRadius    = "6"
        $border.Margin   = [System.Windows.Thickness]::new(0, 0, 0, 8)
        $border.Padding  = [System.Windows.Thickness]::new(14, 10, 14, 10)

        $row = New-Object System.Windows.Controls.Grid
        $col1 = New-Object System.Windows.Controls.ColumnDefinition
        $col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $col2 = New-Object System.Windows.Controls.ColumnDefinition
        $col2.Width = [System.Windows.GridLength]::Auto
        $row.ColumnDefinitions.Add($col1)
        $row.ColumnDefinitions.Add($col2)

        $info = New-Object System.Windows.Controls.StackPanel

        $nameBlock = New-Object System.Windows.Controls.TextBlock
        $nameBlock.Text = $name; $nameBlock.FontSize = 14; $nameBlock.FontWeight = "SemiBold"
        $info.Children.Add($nameBlock) | Out-Null

        $metaBlock = New-Object System.Windows.Controls.TextBlock
        $metaBlock.Text = "$creator  ·  $rarity"; $metaBlock.FontSize = 11
        $metaBlock.Foreground = "#888"; $metaBlock.Margin = "0,2,0,0"
        $info.Children.Add($metaBlock) | Out-Null

        $seenBlock = New-Object System.Windows.Controls.TextBlock
        $seenBlock.Text = "Last seen: $($lastSeen.ToString('MMM d')) at $($lastSeen.ToString('h:mm tt'))  ($ageStr)"
        $seenBlock.FontSize = 11; $seenBlock.Foreground = "#666"; $seenBlock.Margin = "0,2,0,0"
        $info.Children.Add($seenBlock) | Out-Null

        [System.Windows.Controls.Grid]::SetColumn($info, 0)
        $row.Children.Add($info) | Out-Null

        $btnStack = New-Object System.Windows.Controls.StackPanel
        $btnStack.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($btnStack, 1)

        $btnRestore = New-Object System.Windows.Controls.Button
        $btnRestore.Content    = "Restore"
        $btnRestore.Background = $conv.ConvertFromString("#27AE60")
        $btnRestore.Padding    = [System.Windows.Thickness]::new(10, 4, 10, 4)

        # Capture variables for the closure
        $capturedBlock = $entry.CardBlock
        $capturedTc    = $tc
        $capturedName  = $name
        $capturedBtn   = $btnRestore

        $btnRestore.add_Click({
            try {
                # Remove from tombstone if present
                if (Test-Path $tombstoneFile) {
                    $lines = Get-Content $tombstoneFile | Where-Object { $_.Trim() -ne $capturedTc }
                    Set-Content $tombstoneFile -Value $lines -Encoding UTF8
                }
                # Append to draft file for next sync
                $existing = if (Test-Path $draftFile) { Get-Content $draftFile -Raw } else { "" }
                if (-not $existing -or ($existing -notmatch [regex]::Escape($capturedTc))) {
                    Add-Content $draftFile -Value ($capturedBlock.TrimEnd() + "`n")
                }
                [System.Windows.MessageBox]::Show(
                    "'$capturedName' has been queued for restoration.`nPress Sync Now in MSE2 to add it back to your set.",
                    "Card Queued", "OK", "Information") | Out-Null
                $capturedBtn.IsEnabled = $false
                $capturedBtn.Content   = "Queued"
                $capturedBtn.Background = $conv.ConvertFromString("#555")
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Restore Error") | Out-Null
            }
        }.GetNewClosure())

        $btnStack.Children.Add($btnRestore) | Out-Null
        $row.Children.Add($btnStack) | Out-Null
        $border.Child = $row
        return $border
    }

    # =========================================================================
    # Scan function
    # =========================================================================
    function Invoke-Scan {
        $panelDel.Children.Clear()
        $panelLost.Children.Clear()
        $statusText.Text = "Scanning git history..."
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{})

        try {
            $currentTxt = Read-ZipSet $setFile.FullName
            $currentMap = Parse-Cards $currentTxt

            $tombstoned = New-Object System.Collections.Generic.HashSet[string]
            if (Test-Path $tombstoneFile) {
                Get-Content $tombstoneFile | ForEach-Object {
                    $l = $_.Trim(); if ($l) { $tombstoned.Add($l) | Out-Null }
                }
            }

            # Get set path relative to repo root
            $setRelPath = $setFile.FullName.Substring($appData.Length + 1).Replace("\", "/")

            # Commits from the last 7 days that touched the set file
            $rawLog = & $gitExe -C $appData log --since="7.days" --format="%h %ai" -- $setRelPath 2>$null
            if (-not $rawLog) {
                $statusText.Text = "No commits found in the last 7 days."
                $panelDel.Children.Add((New-EmptyMsg "Nothing to show.")) | Out-Null
                $panelLost.Children.Add((New-EmptyMsg "Nothing to show.")) | Out-Null
                return
            }

            $commitLines = @($rawLog)
            $history = @{}

            foreach ($line in $commitLines) {
                if ($line -notmatch "^([a-f0-9]+)\s+(.+?)\s+[+-]\d{4}$") { continue }
                $hash    = $matches[1]
                $dateStr = $matches[2].Trim()
                try { $commitDate = [datetime]::Parse($dateStr) } catch { continue }

                $blobHash = (& $gitExe -C $appData rev-parse "${hash}:${setRelPath}" 2>$null).Trim()
                if (-not $blobHash) { continue }

                $tmpFile = "$env:TEMP\gy_$hash.mse-set"
                cmd /c ("`"" + $gitExe + "`" -C `"" + $appData + "`" cat-file blob " + $blobHash + " > `"" + $tmpFile + "`"") 2>$null
                $commitMap = Parse-Cards (Read-ZipSet $tmpFile)
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

                foreach ($tc in $commitMap.Keys) {
                    if (-not $currentMap.ContainsKey($tc)) {
                        if (-not $history.ContainsKey($tc) -or $commitDate -gt $history[$tc].LastSeen) {
                            $history[$tc] = [PSCustomObject]@{
                                TimeCreated = $tc
                                CardBlock   = $commitMap[$tc]
                                LastSeen    = $commitDate
                            }
                        }
                    }
                }
            }

            $deleted = @($history.Values | Where-Object {  $tombstoned.Contains($_.TimeCreated) } | Sort-Object LastSeen -Descending)
            $lost    = @($history.Values | Where-Object { -not $tombstoned.Contains($_.TimeCreated) } | Sort-Object LastSeen -Descending)

            $statusText.Text = "Scanned $($commitLines.Count) commits  ·  $($deleted.Count) deleted  ·  $($lost.Count) lost  ·  $(Get-Date -Format 'HH:mm:ss')"

            if ($deleted.Count -eq 0) {
                $panelDel.Children.Add((New-EmptyMsg "No intentionally deleted cards in the last 7 days.")) | Out-Null
            } else {
                foreach ($e in $deleted) { $panelDel.Children.Add((New-CardTile $e $true)) | Out-Null }
            }

            if ($lost.Count -eq 0) {
                $panelLost.Children.Add((New-EmptyMsg "No accidentally lost cards found in the last 7 days.")) | Out-Null
            } else {
                foreach ($e in $lost) { $panelLost.Children.Add((New-CardTile $e $false)) | Out-Null }
            }

        } catch {
            $statusText.Text = "Error during scan: $($_.Exception.Message)"
        }
    }

    # =========================================================================
    # Events
    # =========================================================================
    $btnRescan.add_Click({ Invoke-Scan })

    $window.add_Loaded({
        $window.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-Scan })
    })

    $window.ShowDialog() | Out-Null

} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Graveyard Error")
}
