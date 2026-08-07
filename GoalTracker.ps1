Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Web.Extensions

# -- Single-instance guard: only one Goal Tracker per PC at a time -------------
$_gtMutex   = New-Object System.Threading.Mutex($false, "MSE2_GoalTracker_SingleInstance")
$_ownsMutex = $false
try   { $_ownsMutex = $_gtMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $_ownsMutex = $true }  # previous crash: take it

if (-not $_ownsMutex) {
    # Bring the existing window to front and quit
    $existing = Get-Process | Where-Object { $_.MainWindowTitle -match "Set Goal Tracker" } | Select-Object -First 1
    if ($existing -and $existing.MainWindowHandle -ne 0) {
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic
            [Microsoft.VisualBasic.Interaction]::AppActivate($existing.Id)
        } catch {}
    }
    exit
}
# Release the Mutex when this PowerShell process exits
Register-EngineEvent PowerShell.Exiting -Action { try { $_gtMutex.ReleaseMutex() } catch {} } | Out-Null
# ------------------------------------------------------------------------------

try {
    $appData = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"

    $mseProcess = Get-Process -Name "magicseteditor" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mseProcess) { throw "MSE2 is not running. Please open your set in Magic Set Editor first." }

    $mseExePath = $mseProcess.MainModule.FileName
    $mseDir = [System.IO.Path]::GetDirectoryName($mseExePath)
    $manaDir = "$mseDir\data\magic-mana-large.mse-symbol-font"

    $title = $mseProcess.MainWindowTitle
    if (-not $title) { throw "Could not get MSE2 window title." }

    $setName = $title -replace " - Magic Set Editor$", ""
    $setFile = Get-ChildItem -Path "$appData\Shared-Set" -Filter "*.mse-set" -Recurse | Where-Object { $_.BaseName -eq $setName } | Select-Object -First 1
    if (-not $setFile) { throw "Could not find set file for: $setName" }

    $goalsFile = "$($setFile.DirectoryName)\goals_$($setFile.BaseName).json"

    # Data Model
    $colors = @("Total Set", "Baseline", "White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")
    $types = @("Creatures", "Enchantments", "Instants/Sorceries", "Artifacts", "Lands")
    $mvs = @("MV 0", "MV 1", "MV 2", "MV 3", "MV 4", "MV 5", "MV 6", "MV 7+")
    $rarities = @("Common", "Uncommon", "Rare", "Mythic Rare")
    $allCats = $types + $mvs + $rarities

    $goals = @{}
    $actuals = @{}
    $locks = @{}
    foreach ($mc in @("White", "Blue", "Black", "Red", "Green")) {
        $actuals["MulticolorDist_$mc"] = 0
    }
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
        elseif ($cList.Count -gt 1) { 
            $cardColor = "Multicolor"
            if ($cList -contains "W") { $actuals["MulticolorDist_White"]++ }
            if ($cList -contains "U") { $actuals["MulticolorDist_Blue"]++ }
            if ($cList -contains "B") { $actuals["MulticolorDist_Black"]++ }
            if ($cList -contains "R") { $actuals["MulticolorDist_Red"]++ }
            if ($cList -contains "G") { $actuals["MulticolorDist_Green"]++ }
        }
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
        if ($mv -ge 7) { $cardMv = "MV 7+" }
        else { $cardMv = "MV $mv" }

        $cardRarity = ""
        if     ($rarityRaw -match "mythic")   { $cardRarity = "Mythic Rare" }
        elseif ($rarityRaw -match "rare")     { $cardRarity = "Rare" }
        elseif ($rarityRaw -match "uncommon") { $cardRarity = "Uncommon" }
        elseif ($rarityRaw -match "common" -or $rarityRaw -match "basic") { $cardRarity = "Common" }
        elseif ($rarityRaw -eq "")            { $cardRarity = "Common" }  # blank = Common (MSE2 default)
        
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
        Title="Set Goal Tracker - $($setName)" Height="880" Width="550" Background="#1E1E1E" Foreground="White"
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

    $tabLabels = @{
        "Baseline" = "[ Baseline ]"; "Total Set" = "[ Total Set ]"; "White" = "White"; "Blue" = "Blue"; 
        "Black" = "Black"; "Red" = "Red"; "Green" = "Green"; "Colorless" = "Colorless"; "Multicolor" = "Multicolor"
    }

    $iconFiles = @{
        "White" = "mana_w.png"; "Blue" = "mana_u.png"; "Black" = "mana_b.png";
        "Red" = "mana_r.png"; "Green" = "mana_g.png"; "Colorless" = "mana_c.png";
        "Multicolor" = "mana_wubrg.png"
    }

    foreach ($c in $colors) {
        $cNameEscaped = $c -replace " ", "_"
        
        $headerXaml = ""
        if ($iconFiles.ContainsKey($c)) {
            $imgPath = "$manaDir\$($iconFiles[$c])"
            # Ensure WPF handles paths correctly by using forward slashes or URI format
            $imgUri = "file:///" + ($imgPath -replace "\\", "/")
            $headerXaml = @"
<StackPanel Orientation="Horizontal">
    <Image Source="$imgUri" Height="14" Margin="0,0,5,0" RenderOptions.BitmapScalingMode="HighQuality" />
    <TextBlock Text="$($tabLabels[$c])" VerticalAlignment="Center" Foreground="White" />
</StackPanel>
"@
        } else {
            $headerXaml = @"
<TextBlock Text="$($tabLabels[$c])" VerticalAlignment="Center" Foreground="White" />
"@
        }

        $xaml += @"
            <TabItem>
                <TabItem.Header>
                    $headerXaml
                </TabItem.Header>
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

    # -- Recommendation widget: lookup tables and functions -------------------
    $colorAccentHex = @{
        "White"="#C8B87A"; "Blue"="#1A6EC4"; "Black"="#6A4C9C"
        "Red"="#C0392B"; "Green"="#27AE60"; "Colorless"="#607D8B"
        "Multicolor"="#C0922A"; "Total Set"="#8888BB"
    }
    $colorDot = @{
        "White"="W"; "Blue"="U"; "Black"="B"
        "Red"="R"; "Green"="G"; "Colorless"="C"; "Multicolor"="M"; "Total Set"="ALL"
    }
    $typeDisplay = @{
        "Creatures"="Creature"; "Enchantments"="Enchantment"
        "Instants/Sorceries"="Instant / Sorcery"; "Artifacts"="Artifact"; "Lands"="Land"
    }
    $rarityColor = @{
        "Common"="#AAA"; "Uncommon"="#62B5E5"; "Rare"="#D4AF37"; "Mythic Rare"="#E8751A"
    }
    $colorInitial = @{"White"="W";"Blue"="U";"Black"="B";"Red"="R";"Green"="G"}

    # Weighted random: items with higher weight are picked more often
    function Invoke-WeightedPick {
        param($keys, $weights)
        $total = 0.0
        foreach ($w in $weights) { $total += $w }
        if ($total -le 0) { return $keys[0] }
        $rand = (Get-Random -Minimum 0 -Maximum 10000) / 10000.0 * $total
        $cum  = 0.0
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $cum += [double]$weights[$i]
            if ($rand -le $cum) { return $keys[$i] }
        }
        return $keys[$keys.Count - 1]
    }

    # Card recommendation engine.
    # $FixedColor: pin to a specific color (used by per-color tabs).
    # Omit or pass "Total Set" to pick the most-needed color automatically.
    function Get-Recommendation {
        param([string]$FixedColor = "")

        if ($FixedColor -and $FixedColor -ne "Total Set") {
            $pickedColor = $FixedColor
        } else {
            $cols = @("White","Blue","Black","Red","Green","Colorless","Multicolor")
            $colW = @(foreach ($col in $cols) {
                $g = 0; $a = 0
                foreach ($t in $types) { $g += [int]$goals["${col}_$t"]; $a += [int]$actuals["${col}_$t"] }
                [math]::Max(0, $g - $a)
            })
            $pickedColor = Invoke-WeightedPick $cols $colW
        }

        $typeW = @(foreach ($t in $types) {
            [math]::Max(0, [int]$goals["${pickedColor}_$t"] - [int]$actuals["${pickedColor}_$t"])
        })
        $pickedType = Invoke-WeightedPick $types $typeW

        $mvW = @(foreach ($m in $mvs) {
            [math]::Max(0, [int]$goals["${pickedColor}_$m"] - [int]$actuals["${pickedColor}_$m"])
        })
        $pickedMv = Invoke-WeightedPick $mvs $mvW

        $rarW = @(foreach ($r in $rarities) {
            [math]::Max(0, [int]$goals["${pickedColor}_$r"] - [int]$actuals["${pickedColor}_$r"])
        })
        $pickedRarity = Invoke-WeightedPick $rarities $rarW

        $mvNum = $pickedMv -replace "MV ", ""

        # Lands never have a mana cost - clear MV
        if ($pickedType -eq "Lands") { $mvNum = "" }

        if ($pickedColor -eq "Multicolor") {
            $wubrg = @("White","Blue","Black","Red","Green")
            $pairW = @(foreach ($cc in $wubrg) {
                [math]::Max(1, 20 - [int]$actuals["MulticolorDist_$cc"])
            })
            $numColors = if ((Get-Random -Minimum 0 -Maximum 3) -eq 0) { 3 } else { 2 }
            $remKeys = [System.Collections.ArrayList]$wubrg
            $remW    = [System.Collections.ArrayList]$pairW
            for ($pi = 0; $pi -lt $numColors; $pi++) {
                if ($remKeys.Count -eq 0) { break }
                $chosen = Invoke-WeightedPick $remKeys.ToArray() $remW.ToArray()
                $colorPair += $chosen
                $idx = $remKeys.IndexOf($chosen)
                $remKeys.RemoveAt($idx)
                $remW.RemoveAt($idx)
            }
        }

        return @{ Color=$pickedColor; Type=$pickedType; Mv=$mvNum; Rarity=$pickedRarity; ColorPair=$colorPair }
    }
    # -------------------------------------------------------------------------

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
        $isMvCategory   = ($mvs   -contains $category)
        
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
        
        $act = [double]$actuals[$key]
        $gol = [double]$goals[$key]
        if (-not $gol -or $gol -eq 0) { $pct = 0 } else { $pct = $act / $gol }
        
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
        
        # Read-only state: Total Set is always read-only; MV/Rarity on color tabs are read-only unless MV (which now acts like Types)
        if ($color -eq "Total Set" -or ($color -ne "Baseline" -and -not $isTypeCategory -and -not $isMvCategory)) {
            $box.IsReadOnly = $true
            $box.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#222")
            $box.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#888")
            $box.BorderThickness = 0
        }
        [System.Windows.Controls.Grid]::SetColumn($box, 3)
        $grid.Children.Add($box)
        $goalBoxes[$key] = $box

        # Lock Button or Percent Label
        if ($color -eq "Baseline" -and -not $isTypeCategory -and -not $isMvCategory) {
            $lblPct = New-Object System.Windows.Controls.TextBlock
            $lblPct.Text = "%"
            $lblPct.Foreground = "#888"
            $lblPct.VerticalAlignment = "Center"
            $lblPct.Margin = "5,0,0,0"
            [System.Windows.Controls.Grid]::SetColumn($lblPct, 4)
            $grid.Children.Add($lblPct)
        }
        elseif ($color -ne "Baseline" -and $color -ne "Total Set" -and ($isTypeCategory -or $isMvCategory)) {
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

        # Baseline tab: show a divergence table so you can see which colors are over/under
        if ($c -eq "Baseline") {
            $baselineSum = 0
            foreach ($t in $types) { $baselineSum += [int]$goals["Baseline_$t"] }

            $divSep = New-Object System.Windows.Controls.TextBlock
            $divSep.Text = "-- COLOR DIVERGENCE " + ("-" * 15)
            $divSep.FontWeight = "Bold"
            $divSep.Foreground = "#AAA"
            $divSep.Margin = "0,12,0,6"
            $panel.Children.Add($divSep) | Out-Null

            $anyDiv = $false
            foreach ($col in @("White","Blue","Black","Red","Green","Colorless","Multicolor")) {
                $colSum = 0
                foreach ($t in $types) { $colSum += [int]$goals["${col}_$t"] }
                $d = $colSum - $baselineSum
                if ($d -ne 0) {
                    $anyDiv = $true
                    $dRow = New-Object System.Windows.Controls.TextBlock
                    $dRow.FontSize = 11
                    $dRow.Margin = "0,2,0,0"
                    $conv = New-Object System.Windows.Media.BrushConverter
                    if ($d -gt 0) {
                        $dRow.Text = "  $col  +$d card(s) too many"
                        $dRow.Foreground = $conv.ConvertFromString("#FFC107")
                    } else {
                        $dRow.Text = "  $col  $d card(s) too few"
                        $dRow.Foreground = $conv.ConvertFromString("#FFC107")
                    }
                    $panel.Children.Add($dRow) | Out-Null
                }
            }
            if (-not $anyDiv) {
                $okRow = New-Object System.Windows.Controls.TextBlock
                $okRow.Text = "  All colors match Baseline"
                $okRow.FontSize = 11
                $okRow.Margin = "0,2,0,0"
                $okRow.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#4CAF50")
                $panel.Children.Add($okRow) | Out-Null
            }
        }

        AddSection $panel "MANA VALUE"
        foreach ($m in $mvs) { AddRow $panel $c $m }

        # Baseline tab only: live "X / 100 remaining" counter under MV rows
        if ($c -eq "Baseline") {
            $mvTotalBlock = New-Object System.Windows.Controls.TextBlock
            $mvTotalBlock.Margin = "0,4,0,8"
            $mvTotalBlock.FontSize = 11
            $mvTotalBlock.FontWeight = "Bold"

            # Scriptblock that recalculates and repaints the counter
            $refreshMvTotal = {
                $tot = 0
                foreach ($mKey in $mvs) {
                    $v = 0
                    if ([int]::TryParse($goalBoxes["Baseline_$mKey"].Text, [ref]$v)) { $tot += $v }
                }
                $avail = 100 - $tot
                $conv  = New-Object System.Windows.Media.BrushConverter
                if ($tot -gt 100) {
                    $mvTotalBlock.Text       = "Total: $tot%  |  OVER by $(-$avail)%"
                    $mvTotalBlock.Foreground = $conv.ConvertFromString("#F44336")
                } elseif ($tot -eq 100) {
                    $mvTotalBlock.Text       = "Total: 100%  |  Perfect!"
                    $mvTotalBlock.Foreground = $conv.ConvertFromString("#4CAF50")
                } else {
                    $mvTotalBlock.Text       = "Total: $tot%  |  $avail% remaining"
                    $mvTotalBlock.Foreground = $conv.ConvertFromString("#FFC107")
                }
            }.GetNewClosure()

            # Wire up every MV Baseline box so the counter updates live while typing
            foreach ($m in $mvs) { $goalBoxes["Baseline_$m"].add_TextChanged($refreshMvTotal) }

            # Draw initial state
            & $refreshMvTotal
            $panel.Children.Add($mvTotalBlock) | Out-Null
        }

        AddSection $panel "RARITY"
        foreach ($r in $rarities) { AddRow $panel $c $r }

        if ($c -eq "Multicolor") {
            AddSection $panel "COLOR DISTRIBUTION"
            foreach ($mc in @("White", "Blue", "Black", "Red", "Green")) {
                $grid = New-Object System.Windows.Controls.Grid
                $grid.Margin = "0,2,0,2"
                $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(120)}))
                $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(150)}))
                
                $lbl = New-Object System.Windows.Controls.TextBlock
                $lbl.Text = $mc
                $lbl.VerticalAlignment = "Center"
                [System.Windows.Controls.Grid]::SetColumn($lbl, 0)
                $grid.Children.Add($lbl)
                
                $txt = New-Object System.Windows.Controls.TextBlock
                $txt.Text = "$($actuals["MulticolorDist_$mc"]) cards"
                $txt.VerticalAlignment = "Center"
                $txt.Foreground = "#AAA"
                [System.Windows.Controls.Grid]::SetColumn($txt, 1)
                $grid.Children.Add($txt)
                
                $panel.Children.Add($grid)
            }
        }

        # ── TOTAL CARDS SUMMARY (bottom of every tab) ────────────────────────
        $tabGoal   = 0
        $tabActual = 0
        foreach ($t in $types) {
            $tabGoal   += [int]$goals["${c}_${t}"]
            $tabActual += [int]$actuals["${c}_${t}"]
        }
        $tabRemaining = $tabGoal - $tabActual

        # Divider
        $divider = New-Object System.Windows.Controls.Border
        $divider.BorderThickness = "0,1,0,0"
        $divider.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#444")
        $divider.Margin = "0,18,0,0"
        $panel.Children.Add($divider) | Out-Null

        # Summary row
        $summGrid = New-Object System.Windows.Controls.Grid
        $summGrid.Margin = "0,10,0,6"
        $summGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::Auto}))
        $summGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)}))
        $summGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::Auto}))
        $summGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width=[System.Windows.GridLength]::Auto}))

        $summLbl = New-Object System.Windows.Controls.TextBlock
        $summLbl.Text = "TOTAL CARDS"
        $summLbl.FontWeight = "Bold"
        $summLbl.FontSize = 11
        $summLbl.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#AAA")
        $summLbl.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($summLbl, 0)
        $summGrid.Children.Add($summLbl) | Out-Null

        if ($c -ne "Baseline") {
            $summCount = New-Object System.Windows.Controls.TextBlock
            $summCount.Text = "$tabActual / $tabGoal"
            $summCount.FontWeight = "Bold"
            $summCount.FontSize = 12
            $summCount.Foreground = "White"
            $summCount.VerticalAlignment = "Center"
            $summCount.HorizontalAlignment = "Right"
            [System.Windows.Controls.Grid]::SetColumn($summCount, 2)
            $summGrid.Children.Add($summCount) | Out-Null

            $pillBorder = New-Object System.Windows.Controls.Border
            $pillBorder.CornerRadius = "8"
            $pillBorder.Padding = "8,3"
            $pillBorder.Margin = "10,0,0,0"
            $pillBorder.VerticalAlignment = "Center"
            $conv = New-Object System.Windows.Media.BrushConverter
            if ($tabRemaining -le 0) {
                $pillBorder.Background = $conv.ConvertFromString("#1B5E20")
                $pillText = if ($tabRemaining -eq 0) { "Complete!" } else { "$(-$tabRemaining) over" }
            } else {
                $pillBorder.Background = $conv.ConvertFromString("#37474F")
                $pillText = "$tabRemaining to go"
            }
            $pillLbl = New-Object System.Windows.Controls.TextBlock
            $pillLbl.Text = $pillText
            $pillLbl.Foreground = "White"
            $pillLbl.FontSize = 10
            $pillLbl.FontWeight = "SemiBold"
            $pillBorder.Child = $pillLbl
            [System.Windows.Controls.Grid]::SetColumn($pillBorder, 3)
            $summGrid.Children.Add($pillBorder) | Out-Null
        } else {
            $summCount = New-Object System.Windows.Controls.TextBlock
            $summCount.Text = "$tabGoal cards planned"
            $summCount.FontWeight = "Bold"
            $summCount.FontSize = 12
            $summCount.Foreground = "White"
            $summCount.VerticalAlignment = "Center"
            $summCount.HorizontalAlignment = "Right"
            [System.Windows.Controls.Grid]::SetColumn($summCount, 2)
            $summGrid.Children.Add($summCount) | Out-Null
        }

        $panel.Children.Add($summGrid) | Out-Null

        # Divergence warning: show if this color's planned type total differs from Baseline
        if ($c -ne "Baseline" -and $c -ne "Total Set") {
            $baselineSum = 0
            foreach ($t in $types) { $baselineSum += [int]$goals["Baseline_$t"] }
            $div = $tabGoal - $baselineSum
            if ($div -ne 0) {
                $warnBlock = New-Object System.Windows.Controls.TextBlock
                $warnBlock.FontSize = 11
                $warnBlock.Margin = "0,4,0,0"
                $warnBlock.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#FFC107")
                if ($div -gt 0) {
                    $warnBlock.Text = "$c has $div card(s) too many planned vs Baseline"
                } else {
                    $warnBlock.Text = "$c has $(-$div) card(s) too few planned vs Baseline"
                }
                $panel.Children.Add($warnBlock) | Out-Null
            }
        }

        # -- CARD RECOMMENDATION (every tab except Baseline) ------------------
        if ($c -ne "Baseline") {
            $tabColor = $c

            $recSection = New-Object System.Windows.Controls.Border
            $recSection.Margin = "0,18,0,0"
            $recSection.CornerRadius = "10"
            $recSection.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#18182A")
            $recSection.BorderThickness = "1"
            $recSection.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#333355")
            $recSection.Padding = "16,14"

            $recStack = New-Object System.Windows.Controls.StackPanel
            $recSection.Child = $recStack

            $hdrLbl = New-Object System.Windows.Controls.TextBlock
            $hdrLbl.Text = "[ NEXT CARD TO MAKE ]"
            $hdrLbl.FontSize = 11
            $hdrLbl.FontWeight = "Bold"
            $hdrLbl.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#8888BB")
            $hdrLbl.Margin = "0,0,0,12"
            $recStack.Children.Add($hdrLbl) | Out-Null

            $cardBorder = New-Object System.Windows.Controls.Border
            $cardBorder.CornerRadius = "8"
            $cardBorder.Padding = "14,12"
            $cardBorder.Margin = "0,0,0,12"
            $cardBorder.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#222238")
            $cardBorder.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 3)

            $cardInner = New-Object System.Windows.Controls.StackPanel
            $cardBorder.Child = $cardInner

            $mainRow = New-Object System.Windows.Controls.StackPanel
            $mainRow.Orientation = "Horizontal"
            $mainRow.Margin = "0,0,0,6"

            $dotBorder = New-Object System.Windows.Controls.Border
            $dotBorder.CornerRadius = "4"
            $dotBorder.Padding = "7,2"
            $dotBorder.Margin = "0,4,12,0"
            $dotBorder.VerticalAlignment = "Top"

            $dotLbl = New-Object System.Windows.Controls.TextBlock
            $dotLbl.FontSize = 12
            $dotLbl.FontWeight = "Bold"
            $dotLbl.Foreground = "White"
            $dotBorder.Child = $dotLbl
            $mainRow.Children.Add($dotBorder) | Out-Null

            $mainTextStack = New-Object System.Windows.Controls.StackPanel
            $mainRow.Children.Add($mainTextStack) | Out-Null

            $mvLabel = New-Object System.Windows.Controls.TextBlock
            $mvLabel.FontSize = 11
            $mvLabel.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#999")

            $cardTitle = New-Object System.Windows.Controls.TextBlock
            $cardTitle.FontSize = 18
            $cardTitle.FontWeight = "Bold"

            $mainTextStack.Children.Add($mvLabel) | Out-Null
            $mainTextStack.Children.Add($cardTitle) | Out-Null
            $cardInner.Children.Add($mainRow) | Out-Null

            $rarityLbl = New-Object System.Windows.Controls.TextBlock
            $rarityLbl.FontSize = 11
            $rarityLbl.FontWeight = "SemiBold"
            $rarityLbl.Margin = "0,2,0,0"
            $cardInner.Children.Add($rarityLbl) | Out-Null

            $recStack.Children.Add($cardBorder) | Out-Null

            # Button row: shuffle | create
            $btnRow = New-Object System.Windows.Controls.StackPanel
            $btnRow.Orientation = "Horizontal"
            $btnRow.HorizontalAlignment = "Right"

            $shuffleBtn = New-Object System.Windows.Controls.Button
            $shuffleBtn.Content = "[ New Suggestion ]"
            $shuffleBtn.FontSize = 11
            $shuffleBtn.Padding = "12,6"
            $shuffleBtn.Margin = "0,0,6,0"
            $shuffleBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#252545")
            $shuffleBtn.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#AAAACC")
            $shuffleBtn.BorderThickness = "1"
            $shuffleBtn.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#444466")
            $btnRow.Children.Add($shuffleBtn) | Out-Null

            $createBtn = New-Object System.Windows.Controls.Button
            $createBtn.Content = "[ Create This Card ]"
            $createBtn.FontSize = 11
            $createBtn.Padding = "12,6"
            $createBtn.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#1B3A1B")
            $createBtn.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#6FCF6F")
            $createBtn.BorderThickness = "1"
            $createBtn.BorderBrush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString("#2E6E2E")
            $btnRow.Children.Add($createBtn) | Out-Null

            $recStack.Children.Add($btnRow) | Out-Null

            # Shared state: both closures reference this same hashtable
            $sharedRec = @{ Current = $null }

            $colorInitial = @{"White"="W";"Blue"="U";"Black"="B";"Red"="R";"Green"="G"}
            $updateRec = {
                $rec    = Get-Recommendation -FixedColor $tabColor
                $sharedRec.Current = $rec   # store for Create button
                $col    = $rec.Color
                $accent = $colorAccentHex[$col]
                $conv   = New-Object System.Windows.Media.BrushConverter

                $cardBorder.BorderBrush = $conv.ConvertFromString($accent)
                $dotBorder.Background   = $conv.ConvertFromString($accent)

                if ($rec.Type -eq "Lands") {
                    $mvLabel.Visibility = "Collapsed"
                } else {
                    $mvLabel.Visibility = "Visible"
                    $mvLabel.Text = if ($rec.Mv -eq "7+") { "7+ Mana" } elseif ($rec.Mv -eq "0") { "0 Mana (Free)" } else { "$($rec.Mv) Mana" }
                }

                if ($col -eq "Multicolor" -and $rec.ColorPair.Count -gt 0) {
                    $initials  = ($rec.ColorPair | ForEach-Object { $colorInitial[$_] }) -join ""
                    $colorName = $rec.ColorPair -join " / "
                    $dotLbl.Text    = $initials
                    $cardTitle.Text = "$colorName $($typeDisplay[$rec.Type])"
                } else {
                    $dotLbl.Text    = $colorDot[$col]
                    $cardTitle.Text = "$col $($typeDisplay[$rec.Type])"
                }
                $cardTitle.Foreground = $conv.ConvertFromString($accent)

                $rarityLbl.Text       = $rec.Rarity
                $rarityLbl.Foreground = $conv.ConvertFromString($rarityColor[$rec.Rarity])
            }.GetNewClosure()

            # Create This Card: generate mana cost, write draft file for next sync to pick up
            $createCard = {
                $rec = $sharedRec.Current
                if (-not $rec) { return }

                # -- Read username from git config (same source SyncNow uses) --
                $gitExe = "$env:LOCALAPPDATA\MSE2_Shared_Cloud\mingit\cmd\git.exe"
                $repoPath = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"
                $creator = $env:USERNAME
                if (Test-Path $gitExe) {
                    $gn = (& $gitExe -C $repoPath config user.name 2>$null).Trim()
                    if ($gn) { $creator = $gn }
                }

                # -- Build MSE2 mana cost string --
                $symMap  = @{"White"="W";"Blue"="U";"Black"="B";"Red"="R";"Green"="G"}
                $mvInt   = if ($rec.Mv -eq "7+") { 7 } elseif ($rec.Mv -eq "") { 0 } else { [int]$rec.Mv }
                $manaCost = ""
                if ($rec.Type -ne "Lands") {
                    if ($rec.Color -eq "Colorless") {
                        $manaCost = if ($mvInt -eq 0) { "0" } else { "$mvInt" }
                    } elseif ($rec.Color -eq "Multicolor" -and $rec.ColorPair.Count -gt 0) {
                        $numPips = $rec.ColorPair.Count
                        $cl = [math]::Max(0, $mvInt - $numPips)
                        if ($cl -gt 0) { $manaCost += "$cl" }
                        foreach ($cp in $rec.ColorPair) { $manaCost += $symMap[$cp] }
                    } else {
                        $sym = $symMap[$rec.Color]
                        if ($mvInt -eq 0) { $manaCost = "0" }
                        elseif ($mvInt -eq 1) { $manaCost = $sym }
                        else { $manaCost = "$($mvInt - 1)$sym" }
                    }
                }
                # Lands: $manaCost stays ""

                # -- Build MSE2 card type --
                $superType = switch ($rec.Type) {
                    "Creatures"          { "Creature" }
                    "Enchantments"       { "Enchantment" }
                    "Instants/Sorceries" { if ((Get-Random -Maximum 2) -eq 0) { "Instant" } else { "Sorcery" } }
                    "Artifacts"          { "Artifact" }
                    "Lands"              { "Land" }
                    default              { "Creature" }
                }

                $rarStr = switch ($rec.Rarity) {
                    "Common"     { "common" }
                    "Uncommon"   { "uncommon" }
                    "Rare"       { "rare" }
                    "Mythic Rare" { "mythic rare" }
                    default      { "common" }
                }

                $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $ptFields = if ($superType -eq "Creature") { "`n`tpower: 1`n`ttoughness: 1" } else { "" }

                # -- MSE2 card block --
                $cardBlock = @"
card:
`tname: 
`tcasting_cost: $manaCost
`tsuper_type: $superType
`tsub_type: 
`trarity: $rarStr
`trule_text: $ptFields
`ttime_created: $now
`ttime_modified: $now
`tcreator: $creator
`thas_styling: false
"@

                # -- Mini-sync: save MSE2 -> close -> write card -> reopen --------
                $confirm = [System.Windows.MessageBox]::Show(
                    "MSE2 will briefly close and reopen with the card already in it.`nUnsaved changes will be saved first.`n`nAdd: $manaCost $superType ($rarStr) by $creator?",
                    "Create This Card", "YesNo", "Question")
                if ($confirm -ne "Yes") { return }

                # 1. Auto-save MSE2 before closing
                $mseProc = Get-Process "magicseteditor" -ErrorAction SilentlyContinue |
                           Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
                if ($mseProc) {
                    try {
                        Add-Type -AssemblyName Microsoft.VisualBasic
                        Add-Type -AssemblyName System.Windows.Forms
                        [Microsoft.VisualBasic.Interaction]::AppActivate($mseProc.Id)
                        Start-Sleep -Milliseconds 600
                        [System.Windows.Forms.SendKeys]::SendWait("^s")
                        Start-Sleep -Milliseconds 2200
                    } catch {}
                }

                # 2. Close MSE2 (releases zip lock)
                Stop-Process -Name "magicseteditor" -Force -ErrorAction SilentlyContinue
                Stop-Process -Name "MenuAddon"      -Force -ErrorAction SilentlyContinue
                # Wait for process to fully exit
                for ($w = 0; $w -lt 8; $w++) {
                    Start-Sleep -Seconds 1
                    if (-not (Get-Process "magicseteditor" -ErrorAction SilentlyContinue)) { break }
                }

                $launched = $false
                try {
                    $gitExe2      = "$appData\mingit\cmd\git.exe"
                    $credBypassGT = @("-c", "credential.helper=")

                    # 3. Fetch the very latest cloud state (don't reset - just fetch)
                    & $gitExe2 -C $appData @credBypassGT fetch origin *>$null

                    # 4. Re-resolve the set file fresh (closure var may be stale)
                    $liveSetFile = Get-ChildItem "$appData\Shared-Set" -Recurse -Filter "*.mse-set" | Select-Object -First 1
                    if (-not $liveSetFile) { throw "Could not find set file" }

                    # 5. Read the CURRENT local file (which already has the Ctrl+S save from step 1)
                    #    and the LATEST cloud content, then merge: cloud cards + new card
                    $latestBlobHash = (& $gitExe2 -C $appData rev-parse "origin/main:$($liveSetFile.FullName.Replace("$appData\","").Replace("\","/"))" 2>$null).Trim()
                    $cloudTxt = $null
                    if ($latestBlobHash) {
                        $tmpCloud = [System.IO.Path]::GetTempFileName() + ".mse-set"
                        cmd /c "`"$gitExe2`" -C `"$appData`" cat-file blob $latestBlobHash > `"$tmpCloud`"" 2>$null
                        try {
                            $cz = [System.IO.Compression.ZipFile]::OpenRead($tmpCloud)
                            $ce = $cz.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
                            $cs = New-Object System.IO.StreamReader($ce.Open(), [System.Text.Encoding]::UTF8)
                            $cloudTxt = $cs.ReadToEnd(); $cs.Dispose(); $cz.Dispose()
                        } catch {}
                        Remove-Item $tmpCloud -Force -ErrorAction SilentlyContinue
                    }

                    # Fall back to local file if we couldn't get the cloud blob
                    if (-not $cloudTxt) {
                        $lz = [System.IO.Compression.ZipFile]::OpenRead($liveSetFile.FullName)
                        $le = $lz.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
                        $ls = New-Object System.IO.StreamReader($le.Open(), [System.Text.Encoding]::UTF8)
                        $cloudTxt = $ls.ReadToEnd(); $ls.Dispose(); $lz.Dispose()
                    }

                    # 6. Append the new card block to the (cloud-fresh) content
                    $finalContent = $cloudTxt.TrimEnd() + "`n" + $cardBlock + "`n"

                    # 7. Write the merged content back to the local set file
                    $tmpZipNew = [System.IO.Path]::GetTempFileName() + ".mse-set"
                    $srcZipImg = [System.IO.Compression.ZipFile]::OpenRead($liveSetFile.FullName)
                    $dstZipNew = [System.IO.Compression.ZipFile]::Open($tmpZipNew, [System.IO.Compression.ZipArchiveMode]::Create)

                    $newSetEnt = $dstZipNew.CreateEntry("set", [System.IO.Compression.CompressionLevel]::Optimal)
                    $newSetStr = $newSetEnt.Open()
                    $newSetWr  = New-Object System.IO.StreamWriter($newSetStr, [System.Text.Encoding]::UTF8)
                    $newSetWr.Write($finalContent); $newSetWr.Flush(); $newSetWr.Dispose()

                    foreach ($imgEnt in ($srcZipImg.Entries | Where-Object { $_.Name -ne "set" })) {
                        $dImg = $dstZipNew.CreateEntry($imgEnt.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                        $si = $imgEnt.Open(); $di = $dImg.Open()
                        $si.CopyTo($di); $si.Dispose(); $di.Dispose()
                    }
                    $srcZipImg.Dispose(); $dstZipNew.Dispose()
                    Copy-Item $tmpZipNew $liveSetFile.FullName -Force
                    Remove-Item $tmpZipNew -Force -ErrorAction SilentlyContinue

                    # 8. Update last_known file so the next full sync doesn't flag this
                    #    card as a deletion candidate (it sees it in last_known -> not deleted)
                    $safeUser    = $creator -replace '[\\/:*?"<>|]', '_'
                    $lkFile      = "$appData\Shared-Set\$($liveSetFile.Directory.Name)\last_known_$safeUser.txt"
                    if (-not (Test-Path (Split-Path $lkFile))) {
                        $lkFile = "$appData\Shared-Set\last_known_$safeUser.txt"
                    }
                    # Find it properly - same directory as the set file
                    $lkFile = "$($liveSetFile.Directory.FullName)\last_known_$safeUser.txt"
                    $sha256 = [System.Security.Cryptography.SHA256]::Create()
                    $cardBytes = [System.Text.Encoding]::UTF8.GetBytes($cardBlock + "`n")
                    $cardHex = ([System.BitConverter]::ToString($sha256.ComputeHash($cardBytes)) -replace "-","").Substring(0,16)
                    $sha256.Dispose()
                    $newEntry = "$now|$cardHex"
                    # Append to existing last_known or create new
                    if (Test-Path $lkFile) {
                        $existing = Get-Content $lkFile | Where-Object { $_.Trim() -and $_ -notmatch "^$now" }
                        Set-Content $lkFile -Value (($existing + $newEntry) -join "`n") -Encoding UTF8
                    } else {
                        Set-Content $lkFile -Value $newEntry -Encoding UTF8
                    }

                    # 9. Commit and push - retry up to 3x on rejection
                    & $gitExe2 -C $appData add "Shared-Set/" *>$null
                    & $gitExe2 -C $appData commit -m "Card added: $manaCost $superType ($rarStr) by $creator" *>$null

                    $pushOk = $false
                    for ($pushTry = 1; $pushTry -le 3; $pushTry++) {
                        & $gitExe2 -C $appData @credBypassGT push origin main 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) { $pushOk = $true; break }
                        # Push rejected - fetch, rebase, retry
                        & $gitExe2 -C $appData @credBypassGT fetch origin *>$null
                        & $gitExe2 -C $appData rebase origin/main *>$null
                        if ($LASTEXITCODE -ne 0) {
                            & $gitExe2 -C $appData rebase --abort *>$null
                        }
                        Start-Sleep -Seconds 1
                    }

                    if (-not $pushOk) {
                        [System.Windows.MessageBox]::Show(
                            "Card was added locally but could not be uploaded after 3 attempts.`nPlease press Sync soon to upload it.",
                            "Upload Warning", "OK", "Warning")
                    }

                    # 10. Relaunch MSE2 with the updated set file
                    Start-Process "wscript.exe" -ArgumentList "`"$appData\Launch_Silent.vbs`" `"$($liveSetFile.FullName)`""
                    $launched = $true

                    [System.Windows.MessageBox]::Show(
                        "Card added!`n`n$manaCost $superType ($rarStr) - by $creator`n`nMSE2 is reopening with your new card ready to edit.",
                        "Card Created", "OK", "Information")
                } catch {
                    [System.Windows.MessageBox]::Show("Failed to add card: $($_.Exception.Message)", "Error", "OK", "Error")
                } finally {
                    if (-not $launched) {
                        Start-Process "wscript.exe" -ArgumentList "`"$appData\Launch_Silent.vbs`" `"$($setFile.FullName)`""
                    }
                }
            }.GetNewClosure()


            $shuffleBtn.add_Click($updateRec)
            $createBtn.add_Click($createCard)
            & $updateRec

            $panel.Children.Add($recSection) | Out-Null

        }
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
        
        # 2. Read lock states and manually entered Type AND MV goals
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
            foreach ($m in $mvs) {
                $val = 0
                if ([int]::TryParse($goalBoxes["${c}_${m}"].Text, [ref]$val)) {
                    $goals["${c}_${m}"] = $val
                }
            }
        }

        # 3. Apply Baseline Types to all colors (if not locked)
        foreach ($t in $types) {
            foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
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
        #    But skip MV rows that are locked (keep the manually entered value instead)
        foreach ($cat in ($mvs + $rarities)) {
            $pct = $baseline[$cat]
            foreach ($c in @("White", "Blue", "Black", "Red", "Green", "Colorless", "Multicolor")) {
                if ($mvs -contains $cat -and $locks["${c}_${cat}"]) {
                    # Locked MV row: keep the value the user typed in
                } else {
                    $calc = [math]::Round($colorSizes[$c] * ($pct / 100))
                    $goals["${c}_${cat}"] = $calc
                }
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
