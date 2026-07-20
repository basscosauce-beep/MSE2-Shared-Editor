Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web.Extensions

try {
    $appData = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"

    $mseProcess = Get-Process -Name "magicseteditor" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mseProcess) { throw "MSE2 is not running. Please open your set in Magic Set Editor first." }

    $title = $mseProcess.MainWindowTitle
    if (-not $title) { throw "Could not get MSE2 window title." }

    $setName = $title -replace " - Magic Set Editor$", ""
    $setFile = Get-ChildItem -Path "$appData\Shared-Set" -Filter "*.mse-set" -Recurse | Where-Object { $_.BaseName -eq $setName } | Select-Object -First 1
    if (-not $setFile) { throw "Could not find set file for: $setName" }

    $goalsFile = "$($setFile.DirectoryName)\goals_$($setFile.BaseName).json"

    # Data Model
    # Added 'Baseline'
    $colors = @("Baseline", "Total Set", "White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")
    $types = @("Creatures", "Enchantments", "Instants/Sorceries", "Artifacts", "Lands")
    $mvs = @("MV 0", "MV 1", "MV 2", "MV 3", "MV 4", "MV 5+")

    $goals = @{}
    $actuals = @{}
    foreach ($c in $colors) {
        foreach ($t in $types) { $goals["${c}_${t}"] = 0; $actuals["${c}_${t}"] = 0 }
        foreach ($m in $mvs) { $goals["${c}_${m}"] = 0; $actuals["${c}_${m}"] = 0 }
    }

    if (Test-Path $goalsFile) {
        $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $loadedGoals = $jsSer.DeserializeObject((Get-Content $goalsFile -Raw))
        if ($loadedGoals) { foreach ($k in $loadedGoals.Keys) { $goals[$k] = $loadedGoals[$k] } }
    }

    $totalCards = 0
    $zip = [System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
    $entry = $zip.GetEntry("set")
    $stream = $entry.Open()
    $reader = New-Object System.IO.StreamReader($stream)
    $setContent = $reader.ReadToEnd()
    $reader.Close()
    $zip.Dispose()

    $cardBlocks = $setContent -split "`ncard:"
    for ($i = 1; $i -lt $cardBlocks.Length; $i++) {
        $card = $cardBlocks[$i]
        $totalCards++
        
        $cc = ""
        $type = ""
        if ($card -match '(?m)^\s*casting_cost:\s*(.*)') { $cc = $matches[1].Trim() }
        if ($card -match '(?m)^\s*super_type:\s*(.*)') { $type = $matches[1] }
        if ($card -match '(?m)^\s*sub_type:\s*(.*)') { $type += $matches[1] }
        
        $cList = @()
        if ($cc -match 'W') { $cList += "W" }
        if ($cc -match 'U') { $cList += "U" }
        if ($cc -match 'B') { $cList += "B" }
        if ($cc -match 'R') { $cList += "R" }
        if ($cc -match 'G') { $cList += "G" }
        
        $cardColor = ""
        if ($cList.Count -eq 0) { $cardColor = "Colorless" }
        elseif ($cList.Count -gt 1) { $cardColor = "Multicolor" }
        else {
            if ($cList[0] -eq "W") { $cardColor = "White" }
            if ($cList[0] -eq "U") { $cardColor = "Blue" }
            if ($cList[0] -eq "B") { $cardColor = "Black" }
            if ($cList[0] -eq "R") { $cardColor = "Red" }
            if ($cList[0] -eq "G") { $cardColor = "Green" }
        }
        
        $cardType = ""
        if ($type -match "Creature") { $cardType = "Creatures" }
        elseif ($type -match "Enchantment") { $cardType = "Enchantments" }
        elseif ($type -match "Instant" -or $type -match "Sorcery") { $cardType = "Instants/Sorceries" }
        elseif ($type -match "Artifact") { $cardType = "Artifacts" }
        elseif ($type -match "Land") { $cardType = "Lands" }
        
        $mv = 0
        $ccTemp = $cc -replace '(?i)[xy\(\)/]', ''
        if ($ccTemp -match '^(\d+)') {
            $mv += [int]$matches[1]
            $ccTemp = $ccTemp -replace '^\d+', ''
        }
        $mv += ($ccTemp.Length)
        
        $cardMv = ""
        if ($mv -ge 5) { $cardMv = "MV 5+" }
        else { $cardMv = "MV $mv" }
        
        if ($cardType) { $actuals["${cardColor}_${cardType}"]++ }
        if ($cardMv) { $actuals["${cardColor}_${cardMv}"]++ }
        if ($cardType) { $actuals["Total Set_${cardType}"]++ }
        if ($cardMv) { $actuals["Total Set_${cardMv}"]++ }
    }

    # Sum Total Goals
    foreach ($cat in ($types + $mvs)) {
        $sum = 0
        foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
            $sum += $goals["${c}_${cat}"]
        }
        $goals["Total Set_${cat}"] = $sum
    }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Set Goal Tracker - $($setName)" Height="750" Width="550" Background="#1E1E1E" Foreground="White"
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
        <Style TargetType="TabItem">
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Margin" Value="0,0,1,0"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border Name="Border" Background="{TemplateBinding Background}" BorderThickness="0" CornerRadius="3,3,0,0">
                            <ContentPresenter x:Name="ContentSite" VerticalAlignment="Center" HorizontalAlignment="Center" ContentSource="Header" Margin="10,2"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#3D3D3D" />
                                <Setter Property="TextElement.Foreground" Value="White" />
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#444" />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
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
        
        <TabControl Name="ColorTabs" Grid.Row="1" Background="#3D3D3D" BorderThickness="0" Padding="10">
"@

    $emojis = @{
        "Baseline" = "???"; "Total Set" = "??"; "White" = "?"; "Blue" = "??"; 
        "Black" = "?"; "Red" = "??"; "Green" = "??"; "Colorless" = "?"; "Multicolor" = "??"
    }

    foreach ($c in $colors) {
        $cNameEscaped = $c -replace " ", "_"
        $xaml += @"
            <TabItem Header="$($emojis[$c]) $c">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Name="Panel_${cNameEscaped}" />
                </ScrollViewer>
            </TabItem>
"@
    }

    $xaml += @"
        </TabControl>
        
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
            <TextBlock Name="SavedMsg" Text="? Saved" Foreground="#4CAF50" VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Hidden"/>
            <Button Name="BtnRefresh" Content="? Refresh" />
            <Button Name="BtnSave" Content="?? Save Goals" />
        </StackPanel>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $goalBoxes = @{}

    function AddSection($panel, $title) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "-- $title " + ("-" * (35 - $title.Length))
        $tb.FontWeight = "Bold"
        $tb.Foreground = "#AAA"
        $tb.Margin = "0,15,0,10"
        $panel.Children.Add($tb)
    }

    function AddRow($panel, $color, $category) {
        $key = "${color}_${category}"
        
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = "0,2,0,2"
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(120)}))
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(150)}))
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(70)}))
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(60)}))
        
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = $category
        $lbl.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
        $grid.Children.Add($lbl)
        
        $act = $actuals[$key]
        $gol = $goals[$key]
        if ($gol -eq 0) { $pct = 0 } else { $pct = $act / $gol }
        
        if ($color -ne "Baseline") {
            $pbBg = New-Object System.Windows.Shapes.Rectangle
            $pbBg.Fill = "#222"
            $pbBg.Height = 12
            $pbBg.Width = 130
            $pbBg.HorizontalAlignment = "Left"
            [System.Windows.Controls.Grid]::SetColumn($pbBg, 1)
            $grid.Children.Add($pbBg)
            
            $pbFg = New-Object System.Windows.Shapes.Rectangle
            $fillColor = "#4CAF50"
            if ($pct -lt 0.6) { $fillColor = "#9C27B0" }
            elseif ($pct -lt 1.0) { $fillColor = "#FFC107" }
            
            $pbFg.Fill = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($fillColor)
            $pbFg.Height = 12
            $fillWidth = 130 * $pct
            if ($fillWidth -gt 130) { $fillWidth = 130 }
            $pbFg.Width = $fillWidth
            $pbFg.HorizontalAlignment = "Left"
            [System.Windows.Controls.Grid]::SetColumn($pbFg, 1)
            $grid.Children.Add($pbFg)
            
            $txt = New-Object System.Windows.Controls.TextBlock
            $txt.Text = "$act / $gol"
            $txt.VerticalAlignment = "Center"
            [System.Windows.Controls.Grid]::SetColumn($txt, 2)
            $grid.Children.Add($txt)
        }
        
        $box = New-Object System.Windows.Controls.TextBox
        $box.Text = $gol.ToString()
        $box.Width = 40
        $box.HorizontalAlignment = "Left"
        $box.VerticalAlignment = "Center"
        
        # Make Total Set read-only
        if ($color -eq "Total Set") {
            $box.IsReadOnly = $true
            $box.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#222")
            $box.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#888")
            $box.BorderThickness = 0
        }
        
        [System.Windows.Controls.Grid]::SetColumn($box, 3)
        $grid.Children.Add($box)
        
        $goalBoxes[$key] = $box
        $panel.Children.Add($grid)
    }

    foreach ($c in $colors) {
        $cNameEscaped = $c -replace " ", "_"
        $panel = $window.FindName("Panel_${cNameEscaped}")
        
        if ($c -eq "Baseline") {
            $desc = New-Object System.Windows.Controls.TextBlock
            $desc.Text = "Goals set here will be automatically applied to White, Blue, Black, Red, and Green. (Colorless and Multicolor are excluded)."
            $desc.Foreground = "#888"
            $desc.TextWrapping = "Wrap"
            $desc.Margin = "0,0,0,10"
            $panel.Children.Add($desc)
        }

        AddSection $panel "TYPES"
        foreach ($t in $types) { AddRow $panel $c $t }
        
        AddSection $panel "MANA VALUE"
        foreach ($m in $mvs) { AddRow $panel $c $m }
    }

    $window.FindName("BtnSave").add_Click({
        # First read the baseline values
        $baseline = @{}
        foreach ($cat in ($types + $mvs)) {
            $val = 0
            if ([int]::TryParse($goalBoxes["Baseline_${cat}"].Text, [ref]$val)) {
                $baseline[$cat] = $val
            }
        }
        
        # Update colors from baseline if they were modified just now
        $baseChanged = $false
        foreach ($cat in ($types + $mvs)) {
            if ($baseline[$cat] -ne $goals["Baseline_${cat}"]) {
                $baseChanged = $true
                foreach ($c in @("White", "Blue", "Black", "Red", "Green")) {
                    $goalBoxes["${c}_${cat}"].Text = $baseline[$cat].ToString()
                }
            }
        }

        # Read all textboxes and update goals
        foreach ($key in $goalBoxes.Keys) {
            $val = 0
            if ([int]::TryParse($goalBoxes[$key].Text, [ref]$val)) {
                $goals[$key] = $val
            }
        }
        
        # Save to file
        $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        Set-Content -Path $goalsFile -Value ($jsSer.Serialize($goals))
        
        # Refresh window immediately to update progress bars and totals
        $window.Close()
        Start-Process "wscript.exe" -ArgumentList "`"$appData\GoalTracker.vbs`""
    })

    $window.FindName("BtnRefresh").add_Click({
        $window.Close()
        Start-Process "wscript.exe" -ArgumentList "`"$appData\GoalTracker.vbs`""
    })

    $window.ShowDialog() | Out-Null
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Goal Tracker Error")
}
