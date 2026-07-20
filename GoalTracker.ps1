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
    $colors = @("Total Set", "Baseline", "White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")
    $types = @("Creatures", "Enchantments", "Instants/Sorceries", "Artifacts", "Lands")
    $mvs = @("MV 0", "MV 1", "MV 2", "MV 3", "MV 4", "MV 5+")
    $rarities = @("Common", "Uncommon", "Rare", "Mythic Rare")
    $allCats = $types + $mvs + $rarities

    $goals = @{}
    $actuals = @{}
    $locks = @{}
    foreach ($c in $colors) {
        foreach ($cat in $allCats) {
            $goals["${c}_${cat}"] = 0
            $actuals["${c}_${cat}"] = 0
            $locks["${c}_${cat}"] = $false
        }
    }

    if (Test-Path $goalsFile) {
        $jsSer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $loadedGoals = $jsSer.DeserializeObject((Get-Content $goalsFile -Raw))
        if ($loadedGoals) { 
            foreach ($k in $loadedGoals.Keys) { 
                if ($k -match "_Locked$") {
                    $baseK = $k -replace "_Locked$", ""
                    $locks[$baseK] = $loadedGoals[$k]
                } else {
                    $goals[$k] = $loadedGoals[$k] 
                }
            } 
        }
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
        $rarityRaw = ""
        if ($card -match '(?m)^\s*casting_cost:\s*(.*)') { $cc = $matches[1].Trim() }
        if ($card -match '(?m)^\s*super_type:\s*(.*)') { $type = $matches[1] }
        if ($card -match '(?m)^\s*sub_type:\s*(.*)') { $type += $matches[1] }
        if ($card -match '(?m)^\s*rarity:\s*(.*)') { $rarityRaw = $matches[1].Trim().ToLower() }
        
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

        $cardRarity = ""
        if ($rarityRaw -match "mythic") { $cardRarity = "Mythic Rare" }
        elseif ($rarityRaw -match "rare") { $cardRarity = "Rare" }
        elseif ($rarityRaw -match "uncommon") { $cardRarity = "Uncommon" }
        elseif ($rarityRaw -match "common" -or $rarityRaw -match "basic") { $cardRarity = "Common" }
        
        if ($cardType) { 
            $actuals["${cardColor}_${cardType}"]++ 
            $actuals["Total Set_${cardType}"]++
        }
        if ($cardMv) { 
            $actuals["${cardColor}_${cardMv}"]++ 
            $actuals["Total Set_${cardMv}"]++
        }
        if ($cardRarity) {
            $actuals["${cardColor}_${cardRarity}"]++
            $actuals["Total Set_${cardRarity}"]++
        }
    }

    # Sum Total Goals for UI display
    foreach ($cat in $allCats) {
        $sum = 0
        foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
            $sum += $goals["${c}_${cat}"]
        }
        $goals["Total Set_${cat}"] = $sum
    }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Set Goal Tracker - $($setName)" Height="820" Width="550" Background="#1E1E1E" Foreground="White"
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
        <Style TargetType="ToggleButton">
            <Setter Property="Background" Value="#333" />
            <Setter Property="Foreground" Value="#AAA" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="BorderBrush" Value="#555" />
            <Setter Property="Cursor" Value="Hand" />
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
            <TextBlock Text="[ Set Goal Tracker ]" FontSize="20" FontWeight="Bold" />
            <TextBlock Text="$totalCards cards total  ·  Last refresh: $(Get-Date -Format 'HH:mm:ss')" FontSize="12" Foreground="#AAA" Margin="0,5,0,0" />
        </StackPanel>
        
        <TabControl Name="ColorTabs" Grid.Row="1" Background="#3D3D3D" BorderThickness="0" Padding="10">
"@

    $emojis = @{
        "Baseline" = "[ Baseline ]"; "Total Set" = "[ Total Set ]"; "White" = "W White"; "Blue" = "U Blue"; 
        "Black" = "B Black"; "Red" = "R Red"; "Green" = "G Green"; "Colorless" = "C Colorless"; "Multicolor" = "M Multicolor"
    }

    foreach ($c in $colors) {
        $cNameEscaped = $c -replace " ", "_"
        $xaml += @"
            <TabItem Header="$($emojis[$c])">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Name="Panel_${cNameEscaped}" />
                </ScrollViewer>
            </TabItem>
"@
    }

    $xaml += @"
        </TabControl>
        
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,15,0,0">
            <TextBlock Name="SavedMsg" Text="Saved!" Foreground="#4CAF50" VerticalAlignment="Center" Margin="0,0,10,0" Visibility="Hidden"/>
            <Button Name="BtnRefresh" Content="Refresh" />
            <Button Name="BtnSave" Content="Save Goals" />
        </StackPanel>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $goalBoxes = @{}
    $lockBoxes = @{}

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
        $isTypeCategory = ($types -contains $category)
        
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = "0,2,0,2"
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(120)}))
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(150)}))
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(70)}))
        $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(50)}))
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
        
        # Read-only state
        if ($color -eq "Total Set" -or ($color -ne "Baseline" -and -not $isTypeCategory)) {
            $box.IsReadOnly = $true
            $box.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#222")
            $box.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#888")
            $box.BorderThickness = 0
        }
        [System.Windows.Controls.Grid]::SetColumn($box, 3)
        $grid.Children.Add($box)
        $goalBoxes[$key] = $box

        # Lock Button or Percent Label
        if ($color -eq "Baseline" -and -not $isTypeCategory) {
            $lblPct = New-Object System.Windows.Controls.TextBlock
            $lblPct.Text = "%"
            $lblPct.Foreground = "#888"
            $lblPct.VerticalAlignment = "Center"
            $lblPct.Margin = "5,0,0,0"
            [System.Windows.Controls.Grid]::SetColumn($lblPct, 4)
            $grid.Children.Add($lblPct)
        }
        elseif ($color -ne "Baseline" -and $color -ne "Total Set" -and $isTypeCategory) {
            $btnLock = New-Object System.Windows.Controls.Primitives.ToggleButton
            $btnLock.Width = 50
            $btnLock.Height = 22
            $btnLock.HorizontalAlignment = "Left"
            $btnLock.IsChecked = $locks[$key]
            $btnLock.FontSize = 10
            
            if ($locks[$key]) { $btnLock.Content = "Locked"; $btnLock.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#FFF") } 
            else { $btnLock.Content = "Unlock"; $btnLock.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#666") }
            
            $btnLock.add_Click({
                if ($this.IsChecked -eq $true) {
                    $this.Content = "Locked"
                    $this.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#FFF")
                } else {
                    $this.Content = "Unlock"
                    $this.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#666")
                }
            })

            [System.Windows.Controls.Grid]::SetColumn($btnLock, 4)
            $grid.Children.Add($btnLock)
            $lockBoxes[$key] = $btnLock
        }

        $panel.Children.Add($grid)
    }

    foreach ($c in $colors) {
        $cNameEscaped = $c -replace " ", "_"
        $panel = $window.FindName("Panel_${cNameEscaped}")
        
        if ($c -eq "Baseline") {
            $desc = New-Object System.Windows.Controls.TextBlock
            $desc.Text = "Types are raw card counts applied to WUBRG colors. MV and Rarity are percentages applied to the total size of each color across all tabs."
            $desc.Foreground = "#888"
            $desc.TextWrapping = "Wrap"
            $desc.Margin = "0,0,0,10"
            $panel.Children.Add($desc)
        }

        AddSection $panel "TYPES"
        foreach ($t in $types) { AddRow $panel $c $t }
        
        AddSection $panel "MANA VALUE"
        foreach ($m in $mvs) { AddRow $panel $c $m }

        AddSection $panel "RARITY"
        foreach ($r in $rarities) { AddRow $panel $c $r }
    }

    $window.FindName("BtnSave").add_Click({
        # 1. Read Baseline values
        $baseline = @{}
        foreach ($cat in $allCats) {
            $val = 0
            if ([int]::TryParse($goalBoxes["Baseline_${cat}"].Text, [ref]$val)) {
                $baseline[$cat] = $val
                $goals["Baseline_${cat}"] = $val
            }
        }
        
        # 2. Read lock states and manually entered Type goals
        foreach ($key in $lockBoxes.Keys) {
            $locks[$key] = $lockBoxes[$key].IsChecked
            $goals["${key}_Locked"] = $locks[$key]
        }
        foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
            foreach ($t in $types) {
                $val = 0
                if ([int]::TryParse($goalBoxes["${c}_${t}"].Text, [ref]$val)) {
                    $goals["${c}_${t}"] = $val
                }
            }
        }

        # 3. Apply Baseline Types to WUBRG (if not locked)
        foreach ($t in $types) {
            foreach ($c in @("White", "Blue", "Black", "Red", "Green")) {
                if (-not $locks["${c}_${t}"]) {
                    $goals["${c}_${t}"] = $baseline[$t]
                }
            }
        }

        # 4. Calculate total sizes per color (from Type goals)
        $colorSizes = @{}
        foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
            $colorSizes[$c] = 0
            foreach ($t in $types) {
                $colorSizes[$c] += $goals["${c}_${t}"]
            }
        }

        # 5. Apply Baseline Percentages to MV and Rarities for ALL colors based on their size
        foreach ($cat in ($mvs + $rarities)) {
            $pct = $baseline[$cat]
            foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
                $calc = [math]::Round($colorSizes[$c] * ($pct / 100))
                $goals["${c}_${cat}"] = $calc
            }
        }

        # 6. Calculate Total Set tab sums
        foreach ($cat in $allCats) {
            $sum = 0
            foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
                $sum += $goals["${c}_${cat}"]
            }
            $goals["Total Set_${cat}"] = $sum
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
