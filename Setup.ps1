
# Setup.ps1 - First-run setup wizard for MSE2 Shared Cloud
# Lets the user point to wherever MSE2 is installed on their PC.
# Writes mse_path.txt so all other scripts read the location from config.

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$appData    = "$env:LOCALAPPDATA\MSE2_Shared_Cloud"
$msePathFile = "$appData\mse_path.txt"
$creatorFile = "$appData\creator.txt"
$gitExe      = "$appData\mingit\cmd\git.exe"

# Pre-fill MSE path if already configured
$existingMsePath = ""
if (Test-Path $msePathFile) { $existingMsePath = (Get-Content $msePathFile -Raw).Trim() }
$existingName = ""
if (Test-Path $creatorFile) { $existingName = (Get-Content $creatorFile -Raw).Trim() }

# ------------------------------------------------------------------
# Helper: find MSE2 automatically on this machine
# ------------------------------------------------------------------
function Find-MSE2Exe {
    $candidates = @(
        "$env:LOCALAPPDATA\MSE2_Shared_Cloud\MSE2\magicseteditor.exe",
        "C:\Program Files\Magic Set Editor\magicseteditor.exe",
        "C:\Program Files (x86)\Magic Set Editor\magicseteditor.exe",
        "$env:PROGRAMFILES\Magic Set Editor\magicseteditor.exe",
        "${env:PROGRAMFILES(X86)}\Magic Set Editor\magicseteditor.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    # Search running process
    $proc = Get-Process "magicseteditor" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        try { return $proc.MainModule.FileName } catch {}
    }
    return ""
}

$autoFound = Find-MSE2Exe
if ($existingMsePath -eq "" -and $autoFound -ne "") { $existingMsePath = $autoFound }

# ------------------------------------------------------------------
# XAML
# ------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MTG Card Editor - Setup" Height="540" Width="700"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0D0D1A">
  <Window.Resources>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1A1A30"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#2D2D55"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="CaretBrush" Value="White"/>
    </Style>
  </Window.Resources>
  <Grid>
    <!-- Left sidebar: step indicators -->
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="200"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Sidebar background -->
    <Border Grid.Column="0" Background="#080812"/>

    <!-- Logo area -->
    <StackPanel Grid.Column="0" Margin="24,32,24,0">
      <TextBlock Text="MTG" FontSize="28" FontWeight="Black" Foreground="#6366F1"/>
      <TextBlock Text="Card Editor" FontSize="14" Foreground="#4B4B8A" Margin="0,-4,0,0"/>
      <TextBlock Text="Shared Cloud" FontSize="11" Foreground="#333366" Margin="0,0,0,32"/>

      <!-- Step 1 -->
      <StackPanel Name="SideStep1" Orientation="Horizontal" Margin="0,0,0,20">
        <Border Name="StepDot1" Width="28" Height="28" CornerRadius="14" Background="#6366F1" Margin="0,0,12,0" VerticalAlignment="Center">
          <TextBlock Name="StepNum1" Text="1" FontSize="13" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Name="StepLbl1" Text="Welcome" FontSize="12" FontWeight="SemiBold" Foreground="White"/>
          <TextBlock Text="Get started" FontSize="10" Foreground="#555580"/>
        </StackPanel>
      </StackPanel>

      <!-- Step 2 -->
      <StackPanel Name="SideStep2" Orientation="Horizontal" Margin="0,0,0,20">
        <Border Name="StepDot2" Width="28" Height="28" CornerRadius="14" Background="#1E1E38" Margin="0,0,12,0" VerticalAlignment="Center">
          <TextBlock Name="StepNum2" Text="2" FontSize="13" FontWeight="Bold" Foreground="#555580" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Name="StepLbl2" Text="Find MSE2" FontSize="12" FontWeight="SemiBold" Foreground="#555580"/>
          <TextBlock Text="Locate your install" FontSize="10" Foreground="#333366"/>
        </StackPanel>
      </StackPanel>

      <!-- Step 3 -->
      <StackPanel Name="SideStep3" Orientation="Horizontal" Margin="0,0,0,20">
        <Border Name="StepDot3" Width="28" Height="28" CornerRadius="14" Background="#1E1E38" Margin="0,0,12,0" VerticalAlignment="Center">
          <TextBlock Name="StepNum3" Text="3" FontSize="13" FontWeight="Bold" Foreground="#555580" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Name="StepLbl3" Text="Your Name" FontSize="12" FontWeight="SemiBold" Foreground="#555580"/>
          <TextBlock Text="Card credits" FontSize="10" Foreground="#333366"/>
        </StackPanel>
      </StackPanel>

      <!-- Step 4 -->
      <StackPanel Name="SideStep4" Orientation="Horizontal" Margin="0,0,0,20">
        <Border Name="StepDot4" Width="28" Height="28" CornerRadius="14" Background="#1E1E38" Margin="0,0,12,0" VerticalAlignment="Center">
          <TextBlock Name="StepNum4" Text="4" FontSize="13" FontWeight="Bold" Foreground="#555580" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Name="StepLbl4" Text="Set Location" FontSize="12" FontWeight="SemiBold" Foreground="#555580"/>
          <TextBlock Text="Where are your cards" FontSize="10" Foreground="#333366"/>
        </StackPanel>
      </StackPanel>

      <!-- Step 5 -->
      <StackPanel Name="SideStep5" Orientation="Horizontal" Margin="0,0,0,20">
        <Border Name="StepDot5" Width="28" Height="28" CornerRadius="14" Background="#1E1E38" Margin="0,0,12,0" VerticalAlignment="Center">
          <TextBlock Name="StepNum5" Text="5" FontSize="13" FontWeight="Bold" Foreground="#555580" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Name="StepLbl5" Text="All Set!" FontSize="12" FontWeight="SemiBold" Foreground="#555580"/>
          <TextBlock Text="Ready to play" FontSize="10" Foreground="#333366"/>
        </StackPanel>
      </StackPanel>

      <!-- Version -->
      <TextBlock Text="v3.4" FontSize="10" Foreground="#22223A" Margin="0,40,0,0"/>
    </StackPanel>

    <!-- Right content panel -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Step panels -->
      <Grid Grid.Row="0" Margin="40,36,40,20">

        <!-- ======= STEP 1: Welcome ======= -->
        <StackPanel Name="PanelStep1" Visibility="Visible">
          <TextBlock Text="Welcome!" FontSize="28" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,6"/>
          <TextBlock Text="Let's get your shared card editor set up." FontSize="14" Foreground="#AAAACC" Margin="0,0,0,30" TextWrapping="Wrap"/>

          <Border Background="#111128" CornerRadius="10" Padding="20,16" Margin="0,0,0,16">
            <StackPanel>
              <TextBlock Text="What this does:" FontSize="12" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,10"/>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="&#x2713;" Foreground="#22C55E" FontSize="14" Width="22"/>
                <TextBlock Text="Connects MSE2 to a shared cloud set" Foreground="#CCC" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="&#x2713;" Foreground="#22C55E" FontSize="14" Width="22"/>
                <TextBlock Text="Syncs cards between all players automatically" Foreground="#CCC" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                <TextBlock Text="&#x2713;" Foreground="#22C55E" FontSize="14" Width="22"/>
                <TextBlock Text="Tracks your set goals and card distribution" Foreground="#CCC" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x2713;" Foreground="#22C55E" FontSize="14" Width="22"/>
                <TextBlock Text="Works with MSE2 installed anywhere on your PC" Foreground="#CCC" FontSize="12" VerticalAlignment="Center"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Background="#0F1F0F" BorderBrush="#1A3A1A" BorderThickness="1" CornerRadius="8" Padding="16,12">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#x2139;" FontSize="18" Foreground="#22C55E" Margin="0,0,12,0" VerticalAlignment="Center"/>
              <TextBlock TextWrapping="Wrap" Foreground="#88BB88" FontSize="11" VerticalAlignment="Center">
                If you haven't downloaded Magic Set Editor 2 yet, do that first.
                Search for "Magic Set Editor 2" and install it anywhere you like.
                This wizard will find it for you.
              </TextBlock>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- ======= STEP 2: Find MSE2 ======= -->
        <StackPanel Name="PanelStep2" Visibility="Collapsed">
          <TextBlock Text="Find MSE2" FontSize="28" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,6"/>
          <TextBlock Text="Tell us where Magic Set Editor 2 is installed." FontSize="14" Foreground="#AAAACC" Margin="0,0,0,24" TextWrapping="Wrap"/>

          <!-- Auto-detect result -->
          <Border Name="AutoDetectBox" Background="#0F1A0F" BorderBrush="#1A3A1A" BorderThickness="1" CornerRadius="8" Padding="14,10" Margin="0,0,0,20" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#x2705;" FontSize="14" Margin="0,0,10,0" VerticalAlignment="Center"/>
              <TextBlock Name="AutoDetectText" Text="" Foreground="#88BB88" FontSize="11" VerticalAlignment="Center" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>

          <TextBlock Text="Path to magicseteditor.exe" FontSize="12" Foreground="#AAAACC" Margin="0,0,0,6"/>

          <Grid Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox Name="MsePathBox" Grid.Column="0" VerticalContentAlignment="Center"/>
            <Button Name="BtnBrowse" Grid.Column="1" Content="Browse..." Margin="8,0,0,0"
                    Background="#252545" Foreground="#AAAACC" BorderBrush="#333366"
                    BorderThickness="1" Padding="12,8" FontSize="12" FontFamily="Segoe UI" Cursor="Hand">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                          BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"
                          Padding="{TemplateBinding Padding}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter Property="Background" Value="#333366"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
          </Grid>

          <!-- Validation message -->
          <TextBlock Name="PathValidation" Text="" FontSize="11" Margin="0,4,0,0"/>

          <TextBlock Margin="0,20,0,8" FontSize="11" Foreground="#555580" TextWrapping="Wrap">
            Not sure where it is? Try searching your PC for "magicseteditor.exe"
            in File Explorer, or right-click the MSE2 shortcut and choose "Open file location".
          </TextBlock>

          <!-- Common locations hint -->
          <Border Background="#111128" CornerRadius="8" Padding="14,10">
            <StackPanel>
              <TextBlock Text="Common locations:" FontSize="11" Foreground="#6366F1" Margin="0,0,0,6"/>
              <TextBlock Text="C:\Program Files\Magic Set Editor\magicseteditor.exe" FontSize="10" Foreground="#444470" FontFamily="Consolas" Margin="0,2"/>
              <TextBlock Text="C:\Program Files (x86)\Magic Set Editor\magicseteditor.exe" FontSize="10" Foreground="#444470" FontFamily="Consolas" Margin="0,2"/>
              <TextBlock Text="(anywhere you installed it)" FontSize="10" Foreground="#333355" Margin="0,4,0,0" FontStyle="Italic"/>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- ======= STEP 3: Your Name ======= -->
        <StackPanel Name="PanelStep3" Visibility="Collapsed">
          <TextBlock Text="Your Name" FontSize="28" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,6"/>
          <TextBlock Text="This name shows up on every card you create." FontSize="14" Foreground="#AAAACC" Margin="0,0,0,24" TextWrapping="Wrap"/>

          <TextBlock Text="Display name or initials" FontSize="12" Foreground="#AAAACC" Margin="0,0,0,6"/>
          <TextBox Name="NameBox" FontSize="16" Padding="12,10"/>

          <TextBlock Text='Example: "Bass", "Alex", "J.R."' FontSize="11" Foreground="#444470" Margin="0,8,0,0" FontStyle="Italic"/>

          <Border Background="#111128" CornerRadius="10" Padding="20,16" Margin="0,30,0,0">
            <StackPanel>
              <TextBlock Text="This will appear as:" FontSize="11" Foreground="#6366F1" Margin="0,0,0,10"/>
              <Border Background="#0D0D1A" CornerRadius="6" Padding="14,10">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Background="#6366F1" CornerRadius="4" Padding="8,3" Margin="0,0,12,0" VerticalAlignment="Center">
                    <TextBlock Name="PreviewInitial" Text="?" FontSize="12" FontWeight="Bold" Foreground="White"/>
                  </Border>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center">
                    <TextBlock Text="Dragon Whelp" FontSize="13" FontWeight="SemiBold" Foreground="White"/>
                    <TextBlock Name="PreviewName" Text="Created by ?" FontSize="11" Foreground="#6366F1"/>
                  </StackPanel>
                </Grid>
              </Border>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- ======= STEP 4: Set Location ======= -->
        <StackPanel Name="PanelStep4" Visibility="Collapsed">
          <TextBlock Text="Set Location" FontSize="28" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,6"/>
          <TextBlock Text="Here is where your shared card set files are stored on this computer." FontSize="14" Foreground="#AAAACC" Margin="0,0,0,24" TextWrapping="Wrap"/>

          <!-- Path display box -->
          <TextBlock Text="Shared set folder" FontSize="12" Foreground="#AAAACC" Margin="0,0,0,6"/>
          <Border Background="#0D0D1A" BorderBrush="#2D2D55" BorderThickness="1" CornerRadius="6" Padding="14,10" Margin="0,0,0,10">
            <TextBlock Name="SetPathDisplay" Text="" FontSize="12" Foreground="#AAAAEE" FontFamily="Consolas" TextWrapping="Wrap"/>
          </Border>

          <!-- Action buttons -->
          <StackPanel Orientation="Horizontal" Margin="0,0,0,24">
            <Button Name="BtnCopySetPath" Content="Copy Path" Margin="0,0,10,0"
                    Background="#252545" Foreground="#AAAACC" BorderBrush="#333366"
                    BorderThickness="1" Padding="14,8" FontSize="12" FontFamily="Segoe UI" Cursor="Hand">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                          BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#333366"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <Button Name="BtnOpenSetFolder" Content="Open in Explorer" Margin="0,0,0,0"
                    Background="#1A2A1A" Foreground="#88BB88" BorderBrush="#2A4A2A"
                    BorderThickness="1" Padding="14,8" FontSize="12" FontFamily="Segoe UI" Cursor="Hand">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                          BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#243A24"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
            </Button>
            <TextBlock Name="CopiedMsg" Text="Copied!" Foreground="#22C55E" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
          </StackPanel>

          <!-- How-to tip -->
          <Border Background="#111128" CornerRadius="10" Padding="20,16" Margin="0,0,0,12">
            <StackPanel>
              <TextBlock Text="How to open your set in MSE2:" FontSize="12" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,10"/>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <TextBlock Text="1." Foreground="#6366F1" Width="20" FontSize="12"/>
                <TextBlock Text="Launch MSE2 from your desktop shortcut" Foreground="#CCC" FontSize="12"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <TextBlock Text="2." Foreground="#6366F1" Width="20" FontSize="12"/>
                <TextBlock Text="It will open the shared set automatically" Foreground="#CCC" FontSize="12"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="3." Foreground="#6366F1" Width="20" FontSize="12"/>
                <TextBlock TextWrapping="Wrap" Foreground="#CCC" FontSize="12">Or use File &gt; Open and paste the path above to find it manually</TextBlock>
              </StackPanel>
            </StackPanel>
          </Border>

          <Border Background="#0F1A2F" BorderBrush="#1A2A4A" BorderThickness="1" CornerRadius="8" Padding="14,10">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="TIP" FontSize="10" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,10,0" VerticalAlignment="Center"
                         Padding="6,2" Background="#1A1A40"/>
              <TextBlock TextWrapping="Wrap" Foreground="#6688AA" FontSize="11" VerticalAlignment="Center">
                Share this folder path with your friends so they know where to find the set files too.
              </TextBlock>
            </StackPanel>
          </Border>
        </StackPanel>

        <!-- ======= STEP 5: Done ======= -->
        <StackPanel Name="PanelStep5" Visibility="Collapsed">
          <TextBlock Text="You're all set!" FontSize="28" FontWeight="Bold" Foreground="#22C55E" Margin="0,0,0,6"/>
          <TextBlock Text="Everything is configured and ready to go." FontSize="14" Foreground="#AAAACC" Margin="0,0,0,30" TextWrapping="Wrap"/>

          <Border Background="#0F1F0F" BorderBrush="#1A4A1A" BorderThickness="1" CornerRadius="10" Padding="20,16" Margin="0,0,0,16">
            <StackPanel>
              <TextBlock Text="Configuration saved:" FontSize="12" FontWeight="Bold" Foreground="#22C55E" Margin="0,0,0,12"/>
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="MSE2 path:" Foreground="#666" FontSize="11"/>
                <TextBlock Grid.Column="1" Name="SummaryPath" Text="" Foreground="#AAA" FontSize="11" TextWrapping="Wrap"/>
              </Grid>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="90"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Your name:" Foreground="#666" FontSize="11"/>
                <TextBlock Grid.Column="1" Name="SummaryName" Text="" Foreground="#AAA" FontSize="11"/>
              </Grid>
            </StackPanel>
          </Border>

          <Border Background="#111128" CornerRadius="10" Padding="20,16">
            <StackPanel>
              <TextBlock Text="What's next:" FontSize="12" FontWeight="Bold" Foreground="#6366F1" Margin="0,0,0,10"/>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <TextBlock Text="1." Foreground="#6366F1" Width="20" FontSize="12"/>
                <TextBlock Text="Click Finish -- MSE2 will open automatically" Foreground="#CCC" FontSize="12"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
                <TextBlock Text="2." Foreground="#6366F1" Width="20" FontSize="12"/>
                <TextBlock Text="Use the Cloud Sync button to see and sync cards" Foreground="#CCC" FontSize="12"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="3." Foreground="#6366F1" Width="20" FontSize="12"/>
                <TextBlock Text="Open Goal Tracker to plan your set" Foreground="#CCC" FontSize="12"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </StackPanel>

      </Grid>

      <!-- Bottom nav buttons -->
      <Border Grid.Row="1" Background="#080812" Padding="40,16">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <TextBlock Name="StepCounter" Grid.Column="0" Text="Step 1 of 5" FontSize="11" Foreground="#333366" VerticalAlignment="Center"/>

          <Button Name="BtnBack" Grid.Column="1" Content="Back" Margin="0,0,10,0"
                  Background="#1A1A30" Foreground="#888" BorderBrush="#2D2D55"
                  BorderThickness="1" Padding="18,9" FontSize="13" FontFamily="Segoe UI"
                  Cursor="Hand" IsEnabled="False">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8"
                        Padding="{TemplateBinding Padding}" Opacity="{TemplateBinding Opacity}">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#252545"/>
                  </Trigger>
                  <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Opacity" Value="0.4"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
          </Button>

          <Button Name="BtnNext" Grid.Column="2" Content="Next  &#x2192;" Padding="22,9"
                  Background="#6366F1" Foreground="White" BorderThickness="0"
                  FontSize="13" FontFamily="Segoe UI" FontWeight="SemiBold" Cursor="Hand">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border Background="{TemplateBinding Background}" CornerRadius="8"
                        Padding="{TemplateBinding Padding}">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#4F52D3"/>
                  </Trigger>
                  <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Opacity" Value="0.5"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Button.Template>
          </Button>

        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Controls
$panelStep1     = $window.FindName("PanelStep1")
$panelStep2     = $window.FindName("PanelStep2")
$panelStep3     = $window.FindName("PanelStep3")
$panelStep4     = $window.FindName("PanelStep4")
$panelStep5     = $window.FindName("PanelStep5")
$panels         = @($panelStep1, $panelStep2, $panelStep3, $panelStep4, $panelStep5)

$stepDots       = @(1..5 | ForEach-Object { $window.FindName("StepDot$_") })
$stepNums       = @(1..5 | ForEach-Object { $window.FindName("StepNum$_") })
$stepLbls       = @(1..5 | ForEach-Object { $window.FindName("StepLbl$_") })

$msePathBox     = $window.FindName("MsePathBox")
$btnBrowse      = $window.FindName("BtnBrowse")
$pathValidation = $window.FindName("PathValidation")
$autoDetectBox  = $window.FindName("AutoDetectBox")
$autoDetectText = $window.FindName("AutoDetectText")

$nameBox        = $window.FindName("NameBox")
$previewInitial = $window.FindName("PreviewInitial")
$previewName    = $window.FindName("PreviewName")

$setPathDisplay  = $window.FindName("SetPathDisplay")
$btnCopySetPath  = $window.FindName("BtnCopySetPath")
$btnOpenSetFolder= $window.FindName("BtnOpenSetFolder")
$copiedMsg       = $window.FindName("CopiedMsg")

$summaryPath    = $window.FindName("SummaryPath")
$summaryName    = $window.FindName("SummaryName")

$btnBack        = $window.FindName("BtnBack")
$btnNext        = $window.FindName("BtnNext")
$stepCounter    = $window.FindName("StepCounter")

$conv = New-Object System.Windows.Media.BrushConverter

# Pre-fill fields
$msePathBox.Text = $existingMsePath
$nameBox.Text    = $existingName

# Show auto-detect notice if we found MSE2 automatically
if ($autoFound -ne "" -and $existingMsePath -eq $autoFound) {
    $autoDetectText.Text = "Auto-detected: $autoFound"
    $autoDetectBox.Visibility = "Visible"
}

# ------------------------------------------------------------------
# Navigation state
# ------------------------------------------------------------------
$currentStep = 1

function Update-StepVisuals {
    param([int]$step)
    for ($i = 0; $i -lt 5; $i++) {
        $panels[$i].Visibility = if ($i -eq ($step - 1)) { "Visible" } else { "Collapsed" }
        if ($i -lt ($step - 1)) {
            $stepDots[$i].Background = $conv.ConvertFromString("#22C55E")
            $stepNums[$i].Text = [char]0x2713
            $stepNums[$i].Foreground = "White"
            $stepLbls[$i].Foreground = $conv.ConvertFromString("#22C55E")
        } elseif ($i -eq ($step - 1)) {
            $stepDots[$i].Background = $conv.ConvertFromString("#6366F1")
            $stepNums[$i].Text = "$($i + 1)"
            $stepNums[$i].Foreground = "White"
            $stepLbls[$i].Foreground = "White"
        } else {
            $stepDots[$i].Background = $conv.ConvertFromString("#1E1E38")
            $stepNums[$i].Text = "$($i + 1)"
            $stepNums[$i].Foreground = $conv.ConvertFromString("#555580")
            $stepLbls[$i].Foreground = $conv.ConvertFromString("#555580")
        }
    }
    $stepCounter.Text = "Step $step of 5"
    $btnBack.IsEnabled = ($step -gt 1)
    $btnNext.Content = if ($step -eq 5) { "Finish  [OK]" } else { "Next  >>" }
}

function Validate-MsePath {
    $p = $msePathBox.Text.Trim()
    if ($p -eq "") {
        $pathValidation.Text = ""
        return $false
    }
    if (Test-Path $p -PathType Leaf) {
        $leaf = [System.IO.Path]::GetFileName($p).ToLower()
        if ($leaf -eq "magicseteditor.exe") {
            $pathValidation.Text = "Path looks good!"
            $pathValidation.Foreground = $conv.ConvertFromString("#22C55E")
            return $true
        }
        $pathValidation.Text = "That file doesn't look like magicseteditor.exe"
        $pathValidation.Foreground = $conv.ConvertFromString("#EF4444")
        return $false
    }
    # Maybe they typed a folder - check inside it
    $guess = Join-Path $p "magicseteditor.exe"
    if (Test-Path $guess) {
        $msePathBox.Text = $guess
        $pathValidation.Text = "Found magicseteditor.exe in that folder!"
        $pathValidation.Foreground = $conv.ConvertFromString("#22C55E")
        return $true
    }
    $pathValidation.Text = "File not found -- browse to magicseteditor.exe"
    $pathValidation.Foreground = $conv.ConvertFromString("#EF4444")
    return $false
}

# Live path validation while typing
$msePathBox.add_TextChanged({
    Validate-MsePath | Out-Null
    # Hide auto-detect box if user edited the path
    if ($msePathBox.Text.Trim() -ne $autoFound) {
        $autoDetectBox.Visibility = "Collapsed"
    }
})

# Live name preview
$nameBox.add_TextChanged({
    $n = $nameBox.Text.Trim()
    if ($n -eq "") { $n = "?" }
    $previewInitial.Text = $n.Substring(0, [math]::Min(2, $n.Length))
    $previewName.Text = "Created by $n"
})
# Trigger initial preview
$nameBox.Text = $existingName

# Browse button
$btnBrowse.add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title  = "Find magicseteditor.exe"
    $ofd.Filter = "Magic Set Editor|magicseteditor.exe|All executables|*.exe"
    # Try to start in common locations
    $startDir = "C:\Program Files"
    if ($msePathBox.Text.Trim() -ne "") {
        $startDir = [System.IO.Path]::GetDirectoryName($msePathBox.Text.Trim())
    }
    $ofd.InitialDirectory = $startDir
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $msePathBox.Text = $ofd.FileName
        Validate-MsePath | Out-Null
    }
})

# Copy set path to clipboard
$btnCopySetPath.add_Click({
    $p = $setPathDisplay.Text
    if ($p -ne "") {
        [System.Windows.Clipboard]::SetText($p)
        $copiedMsg.Visibility = "Visible"
        # Hide the "Copied!" message after 2 seconds
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(2)
        $timer.add_Tick({
            $copiedMsg.Visibility = "Collapsed"
            $timer.Stop()
        }.GetNewClosure())
        $timer.Start()
    }
})

# Open set folder in Windows Explorer
$btnOpenSetFolder.add_Click({
    $p = $setPathDisplay.Text
    if ($p -ne "" -and (Test-Path $p)) {
        Start-Process explorer.exe -ArgumentList "`"$p`""
    } else {
        Start-Process explorer.exe -ArgumentList "`"$appData\Shared-Set`""
    }
})

# ------------------------------------------------------------------
# Next / Finish button
# ------------------------------------------------------------------
$btnNext.add_Click({
    switch ($script:currentStep) {
        1 { # Welcome -> Find MSE2
            $script:currentStep = 2
            Update-StepVisuals 2
        }
        2 { # Find MSE2 -> validate then advance
            if (-not (Validate-MsePath)) {
                $pathValidation.Text = "Please choose the path to magicseteditor.exe before continuing."
                $pathValidation.Foreground = $conv.ConvertFromString("#EF4444")
                return
            }
            $script:currentStep = 3
            Update-StepVisuals 3
        }
        3 { # Name -> Set Location
            $n = $nameBox.Text.Trim()
            if ($n -eq "") {
                [System.Windows.MessageBox]::Show("Please enter your name or initials.", "Name required", "OK", "Warning") | Out-Null
                return
            }
            # Populate set path display
            $sharedSetPath = "$appData\Shared-Set"
            if (-not (Test-Path $sharedSetPath)) { New-Item $sharedSetPath -ItemType Directory -Force | Out-Null }
            # Find the actual set subfolder if one exists
            $setSubFolder = Get-ChildItem $sharedSetPath -Directory | Select-Object -First 1
            $displayPath = if ($setSubFolder) { $setSubFolder.FullName } else { $sharedSetPath }
            $setPathDisplay.Text = $displayPath
            $script:currentStep = 4
            Update-StepVisuals 4
        }
        4 { # Set Location -> Summary
            $summaryPath.Text = $msePathBox.Text.Trim()
            $summaryName.Text = $nameBox.Text.Trim()
            $script:currentStep = 5
            Update-StepVisuals 5
        }
        5 { # Finish - save config and exit
            $msePath = $msePathBox.Text.Trim()
            $name    = $nameBox.Text.Trim()

            # Save mse_path.txt
            Set-Content $msePathFile -Value $msePath -Encoding UTF8 -NoNewline

            # Save creator.txt
            Set-Content $creatorFile -Value $name -Encoding UTF8 -NoNewline

            # Update git user.name so commits show the right name
            if (Test-Path $gitExe) {
                & $gitExe -C $appData config user.name $name 2>$null
                & $gitExe -C $appData config user.email "$name@mse.local" 2>$null
            }

            # Update MSE2 custom_script so the By field auto-fills
            $mseDir = [System.IO.Path]::GetDirectoryName($msePath)
            $customScript = "$mseDir\data\magic.mse-game\custom_script"
            if (Test-Path (Split-Path $customScript)) {
                $scriptContent = "## Auto-generated by Setup wizard`r`ncreator_name := `"$name`"`r`n`r`nexample_script_so_it_doesnt_die := {`"`"}"
                Set-Content $customScript -Value $scriptContent -NoNewline
            }

            $window.DialogResult = $true
            $window.Close()
        }
    }
})

# Back button
$btnBack.add_Click({
    if ($script:currentStep -gt 1) {
        $script:currentStep--
        Update-StepVisuals $script:currentStep
    }
})

Update-StepVisuals 1
$result = $window.ShowDialog()

# After wizard closes, if finished successfully, launch MSE2
if ($result -eq $true) {
    $msePath = (Get-Content $msePathFile -Raw).Trim()
    if (Test-Path $msePath) {
        $launchVbs = "$appData\Launch_Silent.vbs"
        if (Test-Path $launchVbs) {
            Start-Process "wscript.exe" -ArgumentList "`"$launchVbs`""
        } else {
            Start-Process $msePath
        }
    }
}
