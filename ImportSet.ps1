
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase | Out-Null
$xamlStr = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
    + ' Title="Import Set" Width="680" Height="560" Background="#0A0A14" Foreground="White"'
    + ' FontFamily="Segoe UI" WindowStartupLocation="CenterScreen" ResizeMode="CanResize">'
    + '<Grid Margin="18"><Grid.RowDefinitions>'
    + '<RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>'
    + '<RowDefinition Height="*"/><RowDefinition Height="Auto"/>'
    + '</Grid.RowDefinitions>'
    + '<TextBlock Grid.Row="0" Text="Import Cards from Another Set" FontSize="18" FontWeight="Bold" Foreground="White" Margin="0,0,0,14"/>'
    + '<StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">'
    + '<TextBlock Text="Source .mse-set file:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="12" Foreground="#9CA3AF"/>'
    + '<TextBox Name="PathBox" Width="340" IsReadOnly="True" Background="#111827" Foreground="#D1D5DB" Padding="6,4" VerticalAlignment="Center" FontSize="11" BorderBrush="#374151"/>'
    + '<Button Name="BtnBrowse" Content="Browse..." Margin="8,0,0,0" Background="#1E3A5F" Foreground="White" Padding="14,6" FontSize="12"/>'
    + '</StackPanel>'
    + '<TextBlock Name="StatusText" Grid.Row="2" Foreground="#6B7280" FontSize="11" Margin="0,0,0,8" TextWrapping="Wrap"/>'
    + '<ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto"><StackPanel Name="PreviewList"/></ScrollViewer>'
    + '<Button Name="BtnImport" Grid.Row="4" Content="Import Cards into Shared Set" Margin="0,12,0,0"'
    + ' Background="#1D4ED8" Foreground="#555" FontWeight="Bold" FontSize="13" Padding="20,10"'
    + ' HorizontalAlignment="Right" IsEnabled="False"/>'
    + '</Grid></Window>'
$xaml   = [xml]$xamlStr
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$pathBox     = $window.FindName('PathBox')
$btnBrowse   = $window.FindName('BtnBrowse')
$statusText  = $window.FindName('StatusText')
$previewList = $window.FindName('PreviewList')
$btnImport   = $window.FindName('BtnImport')
$conv        = New-Object System.Windows.Media.BrushConverter
$script:importCards = $null
function Read-ZipSet([string]$path) {
    try {
        $z  = [System.IO.Compression.ZipFile]::OpenRead($path)
        $e  = $z.Entries | Where-Object { $_.Name -eq "set" } | Select-Object -First 1
        if (-not $e) { $z.Dispose(); return $null }
        $sr = New-Object System.IO.StreamReader($e.Open(),[System.Text.Encoding]::UTF8)
        $t  = $sr.ReadToEnd(); $sr.Dispose(); $z.Dispose(); return $t
    } catch { return $null }
}
function Get-CardName([string]$block) {
    if ($block -match "(?m)^\s*name:\s*(.+)") { return $matches[1].Trim() }; return ""
}
function Stamp-Now([string]$block) {
    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    if ($block -match "(?m)(^\s*time_modified:\s*)[^\r\n]+") {
        return $block -replace "(?m)(^\s*time_modified:\s*)[^\r\n]+", ('${1}'+$now)
    }
    if ($block -match "(?m)(^\s*time_created:\s*[^\r\n]+)") {
        return $block -replace "(?m)(^\s*time_created:\s*[^\r\n]+)", ('$1'+"`n`ttime_modified: $now")
    }
    return $block
}
function Run-Preview([string]$srcPath) {
    $previewList.Children.Clear(); $btnImport.IsEnabled=$false; $btnImport.Foreground="#555"
    $statusText.Text="Reading..."; $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render,[action]{})
    try {
        $srcTxt=Read-ZipSet $srcPath; if(-not $srcTxt){$statusText.Text="Cannot read selected file.";return}
        $localTxt=Read-ZipSet $setFile.FullName; if(-not $localTxt){$statusText.Text="Cannot read shared set.";return}
        $nameMap=@{}
        $localTxt -split "(?m)^(?=card:)" | Where-Object {$_ -match "^card:"} | ForEach-Object {
            $blk=($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            $n=Get-CardName $blk; if($n){$nameMap[$n.ToLower()]=$true}
        }
        $cards=@($srcTxt -split "(?m)^(?=card:)" | Where-Object {$_ -match "^card:"} | ForEach-Object {
            $blk=($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            $n=Get-CardName $blk
            if($n){$s=if($nameMap[$n.ToLower()]){"OVERRIDE"}else{"ADD"};[pscustomobject]@{Block=$blk;Name=$n;Status=$s}}
        })
        if($cards.Count -eq 0){$statusText.Text="No cards found.";return}
        $script:importCards=$cards
        $adds=($cards|Where-Object Status -eq "ADD").Count; $ovrs=($cards|Where-Object Status -eq "OVERRIDE").Count
        $statusText.Text="$($cards.Count) cards found: +$adds new   ~$ovrs will replace same-name cards"
        foreach($c in $cards){
            $row=New-Object System.Windows.Controls.Border
            $row.Margin=[System.Windows.Thickness]::new(0,2,0,2); $row.Padding=[System.Windows.Thickness]::new(10,5,10,5); $row.CornerRadius="4"
            if($c.Status -eq "ADD"){$row.Background=$conv.ConvertFromString("#0F2A1A");$row.BorderBrush=$conv.ConvertFromString("#15803D")}
            else{$row.Background=$conv.ConvertFromString("#131A30");$row.BorderBrush=$conv.ConvertFromString("#1D4ED8")}
            $row.BorderThickness="1"
            $sp=New-Object System.Windows.Controls.StackPanel; $sp.Orientation="Horizontal"
            $badge=New-Object System.Windows.Controls.Border; $badge.CornerRadius="3"
            $badge.Padding=[System.Windows.Thickness]::new(5,2,5,2); $badge.Margin=[System.Windows.Thickness]::new(0,0,10,0); $badge.VerticalAlignment="Center"
            $btb=New-Object System.Windows.Controls.TextBlock; $btb.FontSize=10; $btb.FontWeight="Bold"; $btb.Foreground="White"
            if($c.Status -eq "ADD"){$badge.Background=$conv.ConvertFromString("#15803D");$btb.Text="+ ADD"}
            else{$badge.Background=$conv.ConvertFromString("#1D4ED8");$btb.Text="~ OVERRIDE"}
            $badge.Child=$btb
            $ntb=New-Object System.Windows.Controls.TextBlock; $ntb.Text=$c.Name; $ntb.FontSize=12; $ntb.Foreground="White"; $ntb.VerticalAlignment="Center"
            $sp.Children.Add($badge)|Out-Null; $sp.Children.Add($ntb)|Out-Null; $row.Child=$sp
            $previewList.Children.Add($row)|Out-Null
        }
        $btnImport.IsEnabled=$true; $btnImport.Foreground="White"
    } catch { $statusText.Text="Error: $($_.Exception.Message)" }
}
$btnBrowse.add_Click({
    $dlg=New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title="Select an MSE2 set file to import from"; $dlg.Filter="MSE Set files (*.mse-set)|*.mse-set|All files (*.*)|*.*"
    if($dlg.ShowDialog() -eq "OK"){$pathBox.Text=$dlg.FileName; Run-Preview $dlg.FileName}
})
$btnImport.add_Click({
    if(-not $script:importCards -or $script:importCards.Count -eq 0){return}
    $btnImport.IsEnabled=$false; $statusText.Text="Importing..."
    $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render,[action]{})
    try {
        $localTxt=Read-ZipSet $setFile.FullName; if(-not $localTxt){throw "Cannot read shared set."}
        $ordered=[System.Collections.Specialized.OrderedDictionary]::new()
        $localTxt -split "(?m)^(?=card:)" | Where-Object {$_ -match "^card:"} | ForEach-Object {
            $blk=($_ -split "(?m)^(?=keyword:|version_control:|apprentice_code:)")[0]
            $n=Get-CardName $blk; if($n -and -not $ordered.Contains($n.ToLower())){$ordered[$n.ToLower()]=$blk}
        }
        $addN=0; $ovrN=0
        foreach($c in $script:importCards){
            $key=$c.Name.ToLower(); $stmp=Stamp-Now $c.Block
            if($ordered.Contains($key)){$ordered[$key]=$stmp;$ovrN++}else{$ordered[$key]=$stmp;$addN++}
        }
        $hIdx=$localTxt.IndexOf("`ncard:"); $header=if($hIdx -ge 0){$localTxt.Substring(0,$hIdx+1)}else{""}
        $lIdx=$localTxt.LastIndexOf("`ncard:"); $trail=""
        if($lIdx -ge 0){
            $after=$localTxt.Substring($lIdx)
            if($after -match "(?s)`r?`n(keyword:|version_control:|apprentice_code:)"){
                $ts=$after.IndexOf("`r`n"+$matches[1]); if($ts -lt 0){$ts=$after.IndexOf("`n"+$matches[1])}
                if($ts -ge 0){$trail="`r`n"+$after.Substring($ts).TrimStart("`r","`n")}
            }
        }
        $out=$header; foreach($k in $ordered.Keys){$out+=$ordered[$k].TrimEnd()+"`r`n"}; $out+=$trail
        $tmp=[System.IO.Path]::GetTempFileName()+".mse-set"
        $sz=[System.IO.Compression.ZipFile]::OpenRead($setFile.FullName)
        $dz=[System.IO.Compression.ZipFile]::Open($tmp,[System.IO.Compression.ZipArchiveMode]::Create)
        $se=$dz.CreateEntry("set",[System.IO.Compression.CompressionLevel]::Optimal)
        $sw=New-Object System.IO.StreamWriter($se.Open(),[System.Text.Encoding]::UTF8)
        $sw.Write($out);$sw.Flush();$sw.Dispose()
        foreach($img in ($sz.Entries|Where-Object{$_.Name -ne "set"})){
            $de=$dz.CreateEntry($img.FullName,[System.IO.Compression.CompressionLevel]::Optimal)
            $s2=$img.Open();$d2=$de.Open();$s2.CopyTo($d2);$s2.Dispose();$d2.Dispose()
        }
        $sz.Dispose();$dz.Dispose()
        Copy-Item $tmp $setFile.FullName -Force; Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $statusText.Text="Done! +$addN added, ~$ovrN overridden. Use Cloud Sync to upload."
        $statusText.Foreground=$conv.ConvertFromString("#4ADE80")
        $btnImport.Content="Import Complete"; $btnImport.Background=$conv.ConvertFromString("#14532D")
        $script:importCards=$null
    } catch {
        $statusText.Text="Failed: $($_.Exception.Message)"; $statusText.Foreground=$conv.ConvertFromString("#F87171")
        $btnImport.IsEnabled=$true
    }
})
$window.ShowDialog() | Out-Null
