Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web.Extensions # For JSON serialization

$appData = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"

# 1. Find running MSE2 process and extract set file path
$mseProcess = Get-Process -Name "magicseteditor" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $mseProcess) {
    [System.Windows.MessageBox]::Show("MSE2 is not running.")
    exit
}

$title = $mseProcess.MainWindowTitle
if (-not $title) {
    [System.Windows.MessageBox]::Show("Could not get MSE2 window title.")
    exit
}

$setName = $title -replace " - Magic Set Editor$", ""
$setFile = Get-ChildItem -Path "$appData\Shared-Set" -Filter "*.mse-set" -Recurse | Where-Object { $_.BaseName -eq $setName } | Select-Object -First 1

if (-not $setFile) {
    [System.Windows.MessageBox]::Show("Could not find set file for: $setName")
    exit
}

$goalsFile = "$($setFile.DirectoryName)\goals_$($setFile.BaseName).json"

# Default Goals
$goals = @{
    "White" = 10; "Blue" = 10; "Black" = 10; "Red" = 10; "Green" = 10; "Colorless" = 0; "Multicolor" = 0;
    "Creatures" = 15; "Enchantments" = 6; "Instants/Sorceries" = 10; "Artifacts" = 5; "Lands" = 8;
    "MV 0" = 2; "MV 1" = 5; "MV 2" = 8; "MV 3" = 8; "MV 4" = 6; "MV 5+" = 4
}

# Load from file if exists
if (Test-Path $goalsFile) {
    $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $jsonContent = Get-Content $goalsFile -Raw
    try {
        $loadedGoals = $jsSer.DeserializeObject($jsonContent)
        foreach ($key in $loadedGoals.Keys) {
            $goals[$key] = $loadedGoals[$key]
        }
    } catch {}
}

# 2. Extract and Parse set file
$actuals = @{
    "White" = 0; "Blue" = 0; "Black" = 0; "Red" = 0; "Green" = 0; "Colorless" = 0; "Multicolor" = 0;
    "Creatures" = 0; "Enchantments" = 0; "Instants/Sorceries" = 0; "Artifacts" = 0; "Lands" = 0;
    "MV 0" = 0; "MV 1" = 0; "MV 2" = 0; "MV 3" = 0; "MV 4" = 0; "MV 5+" = 0
}
$totalCards = 0

try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
    $entry = $zip.GetEntry("set")
    $stream = $entry.Open()
    $reader = New-Object System.IO.StreamReader($stream)
    $setContent = $reader.ReadToEnd()
    $reader.Close()
    $zip.Dispose()
    
    $cardBlocks = $setContent -split "`ncard:"
    # Skip the first element which is header info
    for ($i = 1; $i -lt $cardBlocks.Length; $i++) {
        $card = $cardBlocks[$i]
        $totalCards++
        
        $cc = ""
        $type = ""
        if ($card -match '(?m)^\s*casting_cost:\s*(.*)') { $cc = $matches[1].Trim() }
        if ($card -match '(?m)^\s*super_type:\s*(.*)') { $type = $matches[1] }
        if ($card -match '(?m)^\s*sub_type:\s*(.*)') { $type += $matches[1] }
        
        # Color
        $colors = @()
        if ($cc -match 'W') { $colors += "W" }
        if ($cc -match 'U') { $colors += "U" }
        if ($cc -match 'B') { $colors += "B" }
        if ($cc -match 'R') { $colors += "R" }
        if ($cc -match 'G') { $colors += "G" }
        
        if ($colors.Count -eq 0) { $actuals["Colorless"]++ }
        elseif ($colors.Count -gt 1) { $actuals["Multicolor"]++ }
        else {
            if ($colors[0] -eq "W") { $actuals["White"]++ }
            if ($colors[0] -eq "U") { $actuals["Blue"]++ }
            if ($colors[0] -eq "B") { $actuals["Black"]++ }
            if ($colors[0] -eq "R") { $actuals["Red"]++ }
            if ($colors[0] -eq "G") { $actuals["Green"]++ }
        }
        
        # Types
        if ($type -match "Creature") { $actuals["Creatures"]++ }
        elseif ($type -match "Enchantment") { $actuals["Enchantments"]++ }
        elseif ($type -match "Instant" -or $type -match "Sorcery") { $actuals["Instants/Sorceries"]++ }
        elseif ($type -match "Artifact") { $actuals["Artifacts"]++ }
        elseif ($type -match "Land") { $actuals["Lands"]++ }
        
        # MV
        $mv = 0
        $ccTemp = $cc -replace '(?i)[xy\(\)/]', '' # remove X, Y, parens, slashes (hybrid)
        if ($ccTemp -match '^(\d+)') {
            $mv += [int]$matches[1]
            $ccTemp = $ccTemp -replace '^\d+', ''
        }
        $mv += ($ccTemp.Length) # count remaining symbols
        
        if ($mv -eq 0) { $actuals["MV 0"]++ }
        elseif ($mv -eq 1) { $actuals["MV 1"]++ }
        elseif ($mv -eq 2) { $actuals["MV 2"]++ }
        elseif ($mv -eq 3) { $actuals["MV 3"]++ }
        elseif ($mv -eq 4) { $actuals["MV 4"]++ }
        else { $actuals["MV 5+"]++ }
    }
} catch {
    [System.Windows.MessageBox]::Show("Error reading set file.")
}

# 3. Build WPF Window
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Set Goal Tracker - $($setName)" Height="750" Width="450" Background="#1E1E1E" Foreground="White"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="White" />
            <Setter Property="FontFamily" Value="Segoe UI" />
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#333" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="BorderBrush" Value="#555" />
            <Setter Property="Padding" Value="2" />
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#007ACC" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Padding" Value="10,5" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Margin" Value="5" />
        </Style>
    </Window.Resources>
    
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        
        <StackPanel Grid.Row="0" Margin="0,0,0,15">
            <TextBlock Text="?? Set Goal Tracker" FontSize="20" FontWeight="Bold" />
            <TextBlock Text="$totalCards cards total  ·  Last refresh: $(Get-Date -Format 'HH:mm:ss')" FontSize="12" Foreground="#AAA" Margin="0,5,0,0" />
        </StackPanel>
        
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel Name="MainPanel" />
        </ScrollViewer>
        
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
            <TextBlock Name="SavedMsg" Text="? Saved" Foreground="#4CAF50" VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Hidden"/>
            <Button Name="BtnRefresh" Content="? Refresh" />
            <Button Name="BtnSave" Content="?? Save Goals" />
        </StackPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$mainPanel = $window.FindName("MainPanel")
$goalBoxes = @{}

function AddSection($title) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "-- $title " + ("-" * (35 - $title.Length))
    $tb.FontWeight = "Bold"
    $tb.Foreground = "#888"
    $tb.Margin = "0,15,0,10"
    $mainPanel.Children.Add($tb)
}

function AddRow($label, $key, $colorHex) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = "0,2,0,2"
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(110)}))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(120)}))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(70)}))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(60)}))
    
    # Label
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $label
    $lbl.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
    $grid.Children.Add($lbl)
    
    $act = $actuals[$key]
    $gol = $goals[$key]
    if ($gol -eq 0) { $pct = 0 } else { $pct = $act / $gol }
    
    # Progress Bar background
    $pbBg = New-Object System.Windows.Shapes.Rectangle
    $pbBg.Fill = "#333"
    $pbBg.Height = 12
    $pbBg.Width = 100
    $pbBg.HorizontalAlignment = "Left"
    [System.Windows.Controls.Grid]::SetColumn($pbBg, 1)
    $grid.Children.Add($pbBg)
    
    # Progress Bar fill
    $pbFg = New-Object System.Windows.Shapes.Rectangle
    $fillColor = "#4CAF50" # Green (>= 100%)
    if ($pct -lt 0.6) { $fillColor = "#9C27B0" } # Purple (< 60%)
    elseif ($pct -lt 1.0) { $fillColor = "#FFC107" } # Yellow
    
    $pbFg.Fill = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($fillColor)
    $pbFg.Height = 12
    $fillWidth = 100 * $pct
    if ($fillWidth -gt 100) { $fillWidth = 100 }
    $pbFg.Width = $fillWidth
    $pbFg.HorizontalAlignment = "Left"
    [System.Windows.Controls.Grid]::SetColumn($pbFg, 1)
    $grid.Children.Add($pbFg)
    
    # Text A/G
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.Text = "$act / $gol"
    $txt.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($txt, 2)
    $grid.Children.Add($txt)
    
    # Goal Input
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $gol.ToString()
    $box.Width = 40
    $box.HorizontalAlignment = "Left"
    $box.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($box, 3)
    $grid.Children.Add($box)
    
    $goalBoxes[$key] = $box
    $mainPanel.Children.Add($grid)
}

AddSection "COLORS"
AddRow "? White" "White" ""
AddRow "?? Blue" "Blue" ""
AddRow "? Black" "Black" ""
AddRow "?? Red" "Red" ""
AddRow "?? Green" "Green" ""
AddRow "? Colorless" "Colorless" ""
AddRow "?? Multicolor" "Multicolor" ""

AddSection "TYPES"
AddRow "Creatures" "Creatures" ""
AddRow "Enchantments" "Enchantments" ""
AddRow "Instants/Sorcs" "Instants/Sorceries" ""
AddRow "Artifacts" "Artifacts" ""
AddRow "Lands" "Lands" ""

AddSection "MANA VALUE"
AddRow "MV 0" "MV 0" ""
AddRow "MV 1" "MV 1" ""
AddRow "MV 2" "MV 2" ""
AddRow "MV 3" "MV 3" ""
AddRow "MV 4" "MV 4" ""
AddRow "MV 5+" "MV 5+" ""

$window.FindName("BtnSave").add_Click({
    foreach ($key in $goalBoxes.Keys) {
        $val = 0
        if ([int]::TryParse($goalBoxes[$key].Text, [ref]$val)) {
            $goals[$key] = $val
        }
    }
    
    $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $json = $jsSer.Serialize($goals)
    Set-Content -Path $goalsFile -Value $json
    
    $window.FindName("SavedMsg").Visibility = "Visible"
})

$window.FindName("BtnRefresh").add_Click({
    $window.Close()
    Start-Process "wscript.exe" -ArgumentList "`"$appData\MSE2-Shared-Editor\GoalTracker.vbs`""
})

$window.ShowDialog()
