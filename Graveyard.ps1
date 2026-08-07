Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

try {
    $appData  = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"
    $gitExe   = "$appData\mingit\cmd\git.exe"
    $env:GIT_TERMINAL_PROMPT = "0"

    # Creator name
    $creatorFile = "$appData\creator.txt"
    $myName = if (Test-Path $creatorFile) { (Get-Content $creatorFile -Raw).Trim() } else { "Unknown" }

    # Set file
    $setFile = Get-ChildItem "$appData\Shared-Set" -Recurse -Filter "*.mse-set" |
        Where-Object { $_.Name -notlike "*.bak" } | Select-Object -First 1
    if (-not $setFile) { throw "Could not find the shared set file." }

    $setDir       = $setFile.DirectoryName
    $tombstoneFile= "$setDir\deleted_cards.txt"
    $draftFile    = "$setDir\draft_cards_$($myName -replace '[\\/:*?"<>|]','_').txt"

    # -------------------------------------------------------------------------
    # Build XAML
    # -------------------------------------------------------------------------
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="☠ Graveyard — $($setFile.BaseName)" Height="720" Width="600"
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

    <!-- Header -->
    <StackPanel Grid.Row="0" Margin="0,0,0,12">
      <TextBlock Text="☠  Graveyard" FontSize="22" FontWeight="Bold" Foreground="#E94560"/>
      <TextBlock Text="Cards that existed in the last 7 days but are no longer in your set."
                 FontSize="12" Foreground="#888" Margin="0,4,0,0"/>
    </StackPanel>

    <!-- Toolbar -->
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
      <TextBlock Name="StatusText" Text="Scanning git history..." VerticalAlignment="Center" Foreground="#AAA" FontSize="12"/>
      <Button Name="BtnRescan" Content="⟳ Rescan" Margin="12,0,0,0" Padding="10,4"/>
    </StackPanel>

    <!-- Tabs -->
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
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $statusText  = $window.FindName("StatusText")
    $panelDel    = $window.FindName("PanelDeleted")
    $panelLost   = $window.FindName("PanelLost")
    $btnRescan   = $window.FindName("BtnRescan")

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
    function Read-ZipSet ([string]$path) {
        try {
            $z = [System.IO.Compression.ZipFile]::OpenRead($path)
            $e = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
            if (-not $e) { $z.Dispose(); return $null }
            $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd(); $sr.Dispose(); $z.Dispose()
            return $txt
        } catch { return $null }
    }

    function Parse-Cards ([string]$content) {
        # Returns hashtable: time_created -> card block
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

    function Make-CardTile ($entry, $isDeleted) {
        $name    = if ($entry.CardBlock -match "(?m)^\s*name:\s*(.+)")    { $matches[1].Trim() } else { "(unnamed)" }
        $creator = if ($entry.CardBlock -match "(?m)^\s*creator:\s*(.+)") { $matches[1].Trim() } else { "?" }
        $rarity  = if ($entry.CardBlock -match "(?m)^\s*rarity:\s*(.+)")  { $matches[1].Trim() } else { "" }
        $tc      = $entry.TimeCreated
        $lastSeen= $entry.LastSeen

        $age = (Get-Date) - $lastSeen
        $ageStr = if ($age.TotalMinutes -lt 60) { "$([int]$age.TotalMinutes) min ago" }
                  elseif ($age.TotalHours -lt 24) { "$([int]$age.TotalHours)h ago" }
                  else { "$([int]$age.TotalDays)d ago" }

        $border = New-Object System.Windows.Controls.Border
        $border.Background  = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#16213E")
        $border.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString(
            if ($isDeleted) { "#E94560" } else { "#0F3460" })
        $border.BorderThickness = "0,0,0,2"
        $border.CornerRadius    = "6"
        $border.Margin   = "0,0,0,8"
        $border.Padding  = "14,10"

        $row = New-Object System.Windows.Controls.Grid
        $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width="*"}))
        $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width="Auto"}))

        $info = New-Object System.Windows.Controls.StackPanel

        $nameBlock = New-Object System.Windows.Controls.TextBlock
        $nameBlock.Text = $name
        $nameBlock.FontSize = 14
        $nameBlock.FontWeight = "SemiBold"
        $nameBlock.Foreground = "White"
        $info.Children.Add($nameBlock) | Out-Null

        $metaBlock = New-Object System.Windows.Controls.TextBlock
        $metaBlock.Text = "$creator  ·  $rarity"
        $metaBlock.FontSize = 11
        $metaBlock.Foreground = "#888"
        $metaBlock.Margin = "0,2,0,0"
        $info.Children.Add($metaBlock) | Out-Null

        $seenBlock = New-Object System.Windows.Controls.TextBlock
        $seenBlock.Text = "Last seen: $($lastSeen.ToString('MMM d') ) at $($lastSeen.ToString('h:mm tt'))  ($ageStr)"
        $seenBlock.FontSize = 11
        $seenBlock.Foreground = "#666"
        $seenBlock.Margin = "0,2,0,0"
        $info.Children.Add($seenBlock) | Out-Null

        [System.Windows.Controls.Grid]::SetColumn($info, 0)
        $row.Children.Add($info) | Out-Null

        $btnStack = New-Object System.Windows.Controls.StackPanel
        $btnStack.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($btnStack, 1)

        $btnRestore = New-Object System.Windows.Controls.Button
        $btnRestore.Content = "Restore"
        $btnRestore.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#27AE60")
        $btnRestore.Padding = "10,4"

        # Capture for closure
        $capturedBlock   = $entry.CardBlock
        $capturedTc      = $tc
        $capturedName    = $name

        $btnRestore.add_Click({
            try {
                # Remove from tombstone if present
                if (Test-Path $tombstoneFile) {
                    $lines = Get-Content $tombstoneFile | Where-Object { $_.Trim() -ne $capturedTc }
                    Set-Content $tombstoneFile -Value $lines -Encoding UTF8
                }
                # Append to draft file for next sync
                $existing = if (Test-Path $draftFile) { Get-Content $draftFile -Raw } else { "" }
                if ($existing -notmatch [regex]::Escape($capturedTc)) {
                    Add-Content $draftFile -Value ($capturedBlock.TrimEnd() + "`n")
                }
                [System.Windows.MessageBox]::Show(
                    "'$capturedName' queued for restoration.`nPress Sync Now in MSE2 to add it back.",
                    "Queued", "OK", "Information") | Out-Null
                # Disable the button
                $btnRestore.IsEnabled = $false
                $btnRestore.Content   = "Queued ✓"
                $btnRestore.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#555")
            } catch {
                [System.Windows.MessageBox]::Show($_.Exception.Message, "Restore Error") | Out-Null
            }
        }.GetNewClosure())

        $btnStack.Children.Add($btnRestore) | Out-Null
        $row.Children.Add($btnStack) | Out-Null

        $border.Child = $row
        return $border
    }

    function EmptyMsg ($text) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.Foreground = "#555"
        $tb.FontStyle = "Italic"
        $tb.Margin = "0,20,0,0"
        $tb.HorizontalAlignment = "Center"
        return $tb
    }

    # -------------------------------------------------------------------------
    # Main scan function
    # -------------------------------------------------------------------------
    function Invoke-Scan {
        $panelDel.Children.Clear()
        $panelLost.Children.Clear()
        $statusText.Text = "Scanning..."
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{})

        try {
            # Read current set
            $currentTxt = Read-ZipSet $setFile.FullName
            $currentMap = Parse-Cards $currentTxt

            # Load tombstone
            $tombstoned = New-Object System.Collections.Generic.HashSet[string]
            if (Test-Path $tombstoneFile) {
                Get-Content $tombstoneFile | ForEach-Object {
                    $l = $_.Trim(); if ($l) { $tombstoned.Add($l) | Out-Null }
                }
            }

            # Commits that touched the set file in last 7 days
            $setRelPath = $setFile.FullName.Replace("$appData\","").Replace("\","/")
            $commits = & $gitExe -C $appData log --since="7.days" --format="%h %ai" -- "$setRelPath" 2>$null
            if (-not $commits) {
                $statusText.Text = "No commits found in the last 7 days."
                return
            }

            # For each card not in current set, track latest commit it appeared in
            # key: time_created -> { CardBlock, LastSeen, CommitHash }
            $history = @{}

            foreach ($line in $commits) {
                if ($line -notmatch "^([a-f0-9]+)\s+(.+)$") { continue }
                $hash = $matches[1]
                $dateStr = $matches[2].Trim() -replace " [+-]\d{4}$",""
                try { $commitDate = [datetime]::Parse($dateStr) } catch { continue }

                $blobHash = (& $gitExe -C $appData rev-parse "${hash}:${setRelPath}" 2>$null).Trim()
                if (-not $blobHash) { continue }

                $tmpFile = "$env:TEMP\gy_scan_$hash.mse-set"
                cmd /c "`"$gitExe`" -C `"$appData`" cat-file blob $blobHash > `"$tmpFile`"" 2>$null
                $commitMap = Parse-Cards (Read-ZipSet $tmpFile)
                Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

                foreach ($tc in $commitMap.Keys) {
                    if (-not $currentMap.ContainsKey($tc)) {
                        if (-not $history.ContainsKey($tc) -or $commitDate -gt $history[$tc].LastSeen) {
                            $history[$tc] = @{
                                TimeCreated = $tc
                                CardBlock   = $commitMap[$tc]
                                LastSeen    = $commitDate
                            }
                        }
                    }
                }
            }

            # Split into tombstoned vs accidentally lost
            $deleted = $history.Keys | Where-Object {  $tombstoned.Contains($_) } | ForEach-Object { $history[$_] }
            $lost    = $history.Keys | Where-Object { -not $tombstoned.Contains($_) } | ForEach-Object { $history[$_] }

            # Sort both: most recently seen first
            $deleted = @($deleted | Sort-Object { $_.LastSeen } -Descending)
            $lost    = @($lost    | Sort-Object { $_.LastSeen } -Descending)

            $statusText.Text = "Scanned $($commits.Count) commits · $($deleted.Count) deleted · $($lost.Count) lost — $(Get-Date -Format 'HH:mm:ss')"

            # Populate panels
            if ($deleted.Count -eq 0) {
                $panelDel.Children.Add((EmptyMsg "No intentionally deleted cards in the last 7 days.")) | Out-Null
            } else {
                foreach ($e in $deleted) {
                    $panelDel.Children.Add((Make-CardTile $e $true)) | Out-Null
                }
            }

            if ($lost.Count -eq 0) {
                $panelLost.Children.Add((EmptyMsg "No accidentally lost cards found in the last 7 days.")) | Out-Null
            } else {
                foreach ($e in $lost) {
                    $panelLost.Children.Add((Make-CardTile $e $false)) | Out-Null
                }
            }

        } catch {
            $statusText.Text = "Error: $($_.Exception.Message)"
        }
    }

    # -------------------------------------------------------------------------
    # Events
    # -------------------------------------------------------------------------
    $btnRescan.add_Click({ Invoke-Scan })

    $window.add_Loaded({
        # Kick off scan on a background thread so the window shows first
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-Scan })
    })

    $window.ShowDialog() | Out-Null

} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Graveyard Error")
}
