# Claude 账号切换器 - Windows 界面 (WPF, Beta)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$BASE = "$env:USERPROFILE\.claude-switcher"
$CORE = "$BASE\claude-switch.ps1"

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 账号切换器" Width="540" Height="860" MinWidth="480" MinHeight="640" ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen" Background="#FF12141D" Foreground="White" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Foreground" Value="White"/><Setter Property="Background" Value="#1AFFFFFF"/>
            <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="14,8"/>
            <Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="36"/>
        </Style>
        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#FF6366F1"/><Setter Property="FontWeight" Value="Bold"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Focusable" Value="False"/>
            <Setter Property="Padding" Value="0"/>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="#14FFFFFF"/><Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#33FFFFFF"/><Setter Property="Padding" Value="10,8"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#14FFFFFF"/><Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#33FFFFFF"/><Setter Property="Padding" Value="10,8"/>
            <Setter Property="CaretBrush" Value="White"/><Setter Property="SelectionBrush" Value="#FF6366F1"/>
        </Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,18">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Width="44" Height="44" CornerRadius="12" Background="#FF6366F1" VerticalAlignment="Center">
                <TextBlock Text="CS" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="16" FontWeight="Bold" Foreground="White"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
                <TextBlock Text="Claude 账号切换器" FontSize="19" FontWeight="Bold"/>
                <TextBlock Text="安全检查 · 切换 · 启动" FontSize="11" Foreground="#B3FFFFFF" Margin="0,3,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="BtnTools" Content="工具" Padding="12,7" Margin="0,0,8,0" ToolTip="指纹体检、CLI 体检、安全链接与快照迁移"/>
                <Button x:Name="BtnSettings" Content="设置" Padding="12,7" ToolTip="检查设置与脱敏诊断日志"/>
            </StackPanel>
        </Grid>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel>
                <Grid Margin="0,0,0,8">
                    <TextBlock Text="环境检查" FontSize="12" FontWeight="SemiBold" Foreground="#CCFFFFFF" VerticalAlignment="Center"/>
                    <Border x:Name="StatusPill" HorizontalAlignment="Right" Padding="11,5" CornerRadius="12" Background="#33F59E0B">
                        <TextBlock x:Name="StatusText" Text="等待检查" FontSize="11" FontWeight="Bold" Foreground="#FFFBBE24"/>
                    </Border>
                </Grid>
                <Border CornerRadius="12" Background="#0DFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" Padding="6">
                    <ListBox x:Name="CheckList" Background="Transparent" BorderThickness="0" Foreground="#F2FFFFFF" FontSize="12">
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <Grid Margin="6,5">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="{Binding Name}" VerticalAlignment="Center" Margin="0,0,12,0"/>
                                    <TextBlock Grid.Column="1" Text="{Binding Detail}" VerticalAlignment="Center" HorizontalAlignment="Right" Foreground="#A6FFFFFF" FontSize="10" TextTrimming="CharacterEllipsis" ToolTip="{Binding Detail}" Margin="0,0,12,0"/>
                                    <TextBlock Grid.Column="2" Text="{Binding StateText}" MinWidth="34" TextAlignment="Right" VerticalAlignment="Center" Foreground="{Binding Color}" FontSize="10" FontWeight="Bold"/>
                                </Grid>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>
                </Border>
                <Border CornerRadius="12" Background="#0DFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" Padding="12,9" Margin="0,12,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                            <TextBlock Text="代理客户端" FontSize="12" FontWeight="SemiBold"/>
                            <TextBlock Text="切换后自动重新检查" FontSize="10" Foreground="#99FFFFFF" Margin="0,2,0,0"/>
                        </StackPanel>
                        <ComboBox x:Name="ProxyClient" Grid.Column="1" Width="180" MinHeight="34" IsEnabled="False" ToolTip="选择实际使用的代理客户端">
                            <ComboBoxItem Content="Clash Verge" Tag="clash-verge"/><ComboBoxItem Content="FlClash" Tag="flclash"/>
                            <ComboBoxItem Content="sing-box" Tag="sing-box"/><ComboBoxItem Content="ClashX" Tag="clashx"/>
                            <ComboBoxItem Content="Surge" Tag="surge"/><ComboBoxItem Content="WireGuard" Tag="wireguard"/>
                            <ComboBoxItem Content="其他 TUN 客户端" Tag="other"/><ComboBoxItem Content="自动识别" Tag="auto"/>
                        </ComboBox>
                    </Grid>
                </Border>
                <Border CornerRadius="12" Background="#0DFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" Padding="12" Margin="0,12,0,0">
                    <StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                            <TextBlock Text="当前账号" FontSize="11" Foreground="#B3FFFFFF" VerticalAlignment="Center"/>
                            <Border Margin="7,0,0,0" Padding="9,3" CornerRadius="10" Background="#4D6366F1">
                                <TextBlock x:Name="CurrentAccount" Text="?" FontSize="11" FontWeight="Bold" Foreground="#FFA5B4FC"/>
                            </Border>
                        </StackPanel>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="10"/><ColumnDefinition/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="10"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Button x:Name="BtnA" Grid.Column="0" Grid.Row="0" IsEnabled="False" ToolTip="切换或初始化账号 A">
                                <StackPanel><TextBlock Text="账号 A" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center"/><TextBlock x:Name="AccountASubtitle" Text="未初始化" FontSize="10" Foreground="#CCFFFFFF" HorizontalAlignment="Center" Margin="0,3,0,0"/></StackPanel>
                            </Button>
                            <Button x:Name="BtnB" Grid.Column="2" Grid.Row="0" IsEnabled="False" ToolTip="切换或初始化账号 B">
                                <StackPanel><TextBlock Text="账号 B" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center"/><TextBlock x:Name="AccountBSubtitle" Text="未初始化" FontSize="10" Foreground="#CCFFFFFF" HorizontalAlignment="Center" Margin="0,3,0,0"/></StackPanel>
                            </Button>
                            <Button x:Name="BtnC" Grid.Column="0" Grid.Row="2" IsEnabled="False" ToolTip="切换或初始化账号 C">
                                <StackPanel><TextBlock Text="账号 C" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center"/><TextBlock x:Name="AccountCSubtitle" Text="未初始化" FontSize="10" Foreground="#CCFFFFFF" HorizontalAlignment="Center" Margin="0,3,0,0"/></StackPanel>
                            </Button>
                            <Button x:Name="BtnD" Grid.Column="2" Grid.Row="2" IsEnabled="False" ToolTip="切换或初始化账号 D">
                                <StackPanel><TextBlock Text="账号 D" FontSize="15" FontWeight="Bold" HorizontalAlignment="Center"/><TextBlock x:Name="AccountDSubtitle" Text="未初始化" FontSize="10" Foreground="#CCFFFFFF" HorizontalAlignment="Center" Margin="0,3,0,0"/></StackPanel>
                            </Button>
                        </Grid>
                    </StackPanel>
                </Border>
                <Border x:Name="UpdateBar" Visibility="Collapsed" CornerRadius="10" Background="#1F6366F1" BorderBrush="#556366F1" BorderThickness="1" Padding="12,10" Margin="0,12,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <TextBlock x:Name="UpdateText" Grid.Column="0" Text="" FontSize="11" Foreground="#FFE0E7FF" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,8,0"/>
                        <Button x:Name="BtnUpdate" Grid.Column="1" Content="一键更新" Padding="10,5" Margin="0,0,6,0" FontSize="11" Style="{StaticResource AccentButton}"/>
                        <Button x:Name="BtnLater" Grid.Column="2" Content="稍后" Padding="10,5" FontSize="11"/>
                    </Grid>
                </Border>
                <TextBlock x:Name="Banner" Text="" FontSize="12" Foreground="#FFF87171" Margin="0,12,0,0" TextWrapping="Wrap"/>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                    <Button x:Name="BtnFix" Content="一键修复" Style="{StaticResource AccentButton}" Margin="0,0,10,0" ToolTip="修复代理、时区、IPv6 与保镖，可能需要管理员授权"/>
                    <Button x:Name="BtnRefresh" Content="重新检查" ToolTip="重新执行完整环境检查"/>
                </StackPanel>
            </StackPanel>
        </ScrollViewer>
        <Grid Grid.Row="2" Margin="0,16,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnDiagnostics" Content="导出诊断" Padding="10,6" FontSize="11" ToolTip="只导出脱敏日志和状态"/>
                <TextBlock Text="硬性项必须通过" FontSize="10" Foreground="#99FFFFFF" VerticalAlignment="Center" Margin="10,0,0,0"/>
            </StackPanel>
            <Button x:Name="BtnCheckUpdate" Grid.Column="2" Content="检查更新" Padding="10,6" FontSize="11"/>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)
$rows = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$win.FindName('CheckList').ItemsSource = $rows
$checkNames = @('代理内核','TUN网卡','出口IP','IP一致','时区','地区','IPv6','DNS','WebRTC','保镖','规则置顶','客户端语言','ASN属性','生态可达性')
$clientModes = @('clash-verge','flclash','sing-box','clashx','surge','wireguard','other','auto')
$script:isBusy = $false
$script:environmentReady = $false
$script:currentClient = ''
$script:currentAccount = 'none'
$script:archivedAccounts = @()
$script:suppressClientEvent = $false
$script:uiJob = $null
$script:uiTimer = $null
$script:uiOperation = ''
$script:activeToolOutput = $null

function Set-Status($text, $color) {
    $win.FindName('StatusText').Text = $text
    $win.FindName('StatusText').Foreground = New-Object System.Windows.Media.SolidColorBrush $color
}
function Set-Banner([string]$text, [string]$kind = 'info') {
    $colors = @{ info = '#FF93C5FD'; success = '#FF4ADE80'; warn = '#FFFBBE24'; error = '#FFF87171' }
    $win.FindName('Banner').Text = $text
    $win.FindName('Banner').Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$kind]))
}
function Set-Busy([bool]$busy) {
    $script:isBusy = $busy
    foreach ($name in @('BtnFix','BtnRefresh','BtnTools','BtnSettings','BtnDiagnostics')) { $win.FindName($name).IsEnabled = -not $busy }
    foreach ($name in @('BtnA','BtnB','BtnC','BtnD')) { $win.FindName($name).IsEnabled = (-not $busy -and $script:environmentReady) }
    $win.FindName('ProxyClient').IsEnabled = (-not $busy -and [bool]$script:currentClient)
    $win.FindName('BtnCheckUpdate').IsEnabled = (-not $busy -and -not $script:updateRunning)
}
function Invoke-Core([string[]]$coreArgs) {
    $script:lastCoreExit = 1
    $quotedArgs = @($coreArgs | ForEach-Object { Quote-UiArgument ([string]$_) })
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $CORE @quotedArgs 2>$null
    $script:lastCoreExit = $LASTEXITCODE
    return ($out | Out-String).Trim()
}
function Quote-UiArgument([string]$Argument) {
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"'); $slashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq [char]92) { $slashes++; continue }
        if ($char -eq '"') { [void]$result.Append(('\' * ($slashes * 2 + 1))); [void]$result.Append('"'); $slashes = 0; continue }
        if ($slashes) { [void]$result.Append(('\' * $slashes)); $slashes = 0 }
        [void]$result.Append($char)
    }
    [void]$result.Append(('\' * ($slashes * 2))); [void]$result.Append('"')
    return $result.ToString()
}
function Start-UiOperation([string]$Operation, [scriptblock]$Work, [object[]]$Arguments = @()) {
    if ($script:isBusy) { return $false }
    Set-Busy $true
    $script:uiOperation = $Operation
    try { $script:uiJob = Start-Job -ScriptBlock $Work -ArgumentList $Arguments } catch {
        Set-Busy $false; Set-Banner "无法启动后台任务：$($_.Exception.Message)" 'error'; return $false
    }
    $script:uiTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:uiTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:uiTimer.Add_Tick({
        if (-not $script:uiJob) { $script:uiTimer.Stop(); return }
        $state = $script:uiJob.State
        if ($state -notin @('Completed','Failed','Stopped')) { return }
        $script:uiTimer.Stop()
        $result = Receive-Job $script:uiJob -ErrorAction SilentlyContinue | Select-Object -Last 1
        Remove-Job $script:uiJob -Force -ErrorAction SilentlyContinue
        $script:uiJob = $null
        $operation = $script:uiOperation
        Set-Busy $false
        Complete-UiOperation $operation $result
    })
    $script:uiTimer.Start()
    return $true
}
function Start-CommandOperation([string]$Operation, [string[]]$CoreArgs, [string]$Secret = $null) {
    $work = {
        param($core, [string[]]$commandArgs, [string]$inputText)
        try {
            $allArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$core) + $commandArgs
            $quoted = @($allArgs | ForEach-Object {
                $arg = [string]$_
                if ($arg -notmatch '[\s"]') { $arg } else {
                    $sb = New-Object System.Text.StringBuilder; [void]$sb.Append('"'); $slashes = 0
                    foreach ($char in $arg.ToCharArray()) {
                        if ($char -eq [char]92) { $slashes++; continue }
                        if ($char -eq '"') { [void]$sb.Append(('\' * ($slashes * 2 + 1))); [void]$sb.Append('"'); $slashes = 0; continue }
                        if ($slashes) { [void]$sb.Append(('\' * $slashes)); $slashes = 0 }
                        [void]$sb.Append($char)
                    }
                    [void]$sb.Append(('\' * ($slashes * 2))); [void]$sb.Append('"'); $sb.ToString()
                }
            })
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'; $psi.Arguments = $quoted -join ' '
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            if ($null -ne $inputText) { $psi.RedirectStandardInput = $true }
            $process = [System.Diagnostics.Process]::Start($psi)
            if ($null -ne $inputText) { $process.StandardInput.WriteLine($inputText); $process.StandardInput.Close() }
            if (-not $process.WaitForExit(900000)) {
                try { $process.Kill() } catch {}
                return [pscustomobject]@{ Text = '操作超时，请重试'; Exit = 1 }
            }
            $text = ($process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()).Trim()
            [pscustomobject]@{ Text = $text; Exit = $process.ExitCode }
        } catch { [pscustomobject]@{ Text = $_.Exception.Message; Exit = 1 } }
    }
    Start-UiOperation $Operation $work @($CORE, $CoreArgs, $Secret)
}
function Apply-ClientOutput([string]$Text) {
    $mode = ''
    foreach ($line in ($Text -split "`r?`n")) { if ($line -match '^client=([a-z-]+)$') { $mode = $Matches[1] } }
    if ($clientModes -notcontains $mode) { $script:currentClient = ''; return $false }
    $script:currentClient = $mode
    $script:suppressClientEvent = $true
    foreach ($item in $win.FindName('ProxyClient').Items) { if ([string]$item.Tag -eq $mode) { $win.FindName('ProxyClient').SelectedItem = $item; break } }
    $script:suppressClientEvent = $false
    return $true
}
function Apply-StatusOutput([string]$Text) {
    $fields = @{}
    foreach ($token in ($Text -split '\s+')) {
        $pair = $token -split '=', 2
        if ($pair.Count -eq 2) { $fields[$pair[0]] = $pair[1] }
    }
    $current = [string]$fields['current']
    if ($current -notin @('A','B','C','D','none')) { return $false }
    $archived = @()
    if ($fields.ContainsKey('accounts')) {
        if ($fields['accounts'] -ne 'none') {
            $archived = @($fields['accounts'] -split ',')
            if (@($archived | Where-Object { $_ -notin @('A','B','C','D') }).Count) { return $false }
        }
    } else {
        foreach ($slot in @('A','B','C','D')) { if ($fields["has$slot"] -eq '1') { $archived += $slot } }
    }
    $script:currentAccount = $current; $script:archivedAccounts = $archived
    $win.FindName('CurrentAccount').Text = if ($current -eq 'none') { '未初始化' } else { $current }
    foreach ($slot in @('A','B','C','D')) {
        $subtitle = if ($current -eq $slot) { '当前' } elseif ($archived -notcontains $slot) { '未初始化' }
            elseif ($fields["acc$slot"] -match '^([^@]+)@(\d{4})-(\d{2})-(\d{2})$') { "已建档 · $($Matches[1]) · $($Matches[3])-$($Matches[4])" }
            else { '已建档' }
        $win.FindName("Account${slot}Subtitle").Text = $subtitle
        $win.FindName("Btn$slot").Background = if ($current -eq $slot) { '#B96366F1' } else { '#1AFFFFFF' }
    }
    return $true
}
function Apply-CheckOutput([string]$Text, [int]$ExitCode) {
    $rows.Clear(); foreach ($name in $checkNames) { $rows.Add([pscustomobject]@{ Name = $name; Detail = ''; StateText = '等待'; Color = '#FF6B7280' }) }
    $matched = New-Object 'System.Collections.Generic.HashSet[int]'
    $valid = $ExitCode -eq 0; $hasWarn = $false; $hasSkip = $false
    foreach ($line in ($Text -split "`r?`n")) {
        $kv = $line -split '=', 2
        if ($kv.Count -ne 2) { continue }
        $state = $kv[1] -split ':', 2
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($rows[$i].Name -ne $kv[0]) { continue }
            if (-not $matched.Add($i)) { $valid = $false; break }
            $detail = if ($state.Count -gt 1) { $state[1] } else { '' }
            switch ($state[0]) {
                'ok' { $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $detail; StateText = '通过'; Color = '#FF22C55E' } }
                'warn' { $hasWarn = $true; $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $detail; StateText = '警告'; Color = '#FFFACC15' } }
                'skip' { $hasSkip = $true; $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $detail; StateText = '跳过'; Color = '#FF6B7280' } }
                default { $valid = $false; $rows[$i] = [pscustomobject]@{ Name = $rows[$i].Name; Detail = $detail; StateText = '失败'; Color = '#FFF87171' } }
            }
            break
        }
    }
    if ($matched.Count -ne $checkNames.Count) { $valid = $false }
    $script:environmentReady = $valid
    if (-not $valid) {
        Set-Status '检查未过' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71))
        Set-Banner $(if ($matched.Count -ne $checkNames.Count) { "检测输出不完整($($matched.Count)/$($checkNames.Count))，请重新检查" } else { '存在未通过项，可一键修复或手动处理后重试' }) 'error'
    } else {
        $script:environmentReady = $true
        $label = if ($hasWarn) { '有警告' } elseif ($hasSkip) { '通过（含跳过）' } else { '环境安全' }
        Set-Status $label ([System.Windows.Media.Color]::FromRgb(0x22,0xC5,0x5E))
        Set-Banner $(if ($hasWarn) { '环境可启动，但有警告项需要留意' } elseif ($hasSkip) { '硬性安全项已通过；灰色跳过不表示检查通过' } else { '全部环境检查已完成，可以选择账号启动' }) $(if ($hasWarn) { 'warn' } else { 'success' })
    }
    Set-Busy $false
    return $valid
}
function Refresh-Checks {
    if ($script:isBusy) { return }
    if (-not (Test-Path -LiteralPath $CORE -PathType Leaf)) {
        $script:environmentReady = $false
        $rows.Clear(); foreach ($name in $checkNames) { $rows.Add([pscustomobject]@{ Name = $name; Detail = '核心脚本未安装'; StateText = '失败'; Color = '#FFF87171' }) }
        Set-Status '未安装' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71)); Set-Banner '未找到核心脚本，请先运行 Windows 安装器' 'error'; Set-Busy $false; return
    }
    Set-Status '检查中' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C)); Set-Banner '正在执行完整环境检查…' 'info'
    $work = {
        param($core, $base)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $core checkdetail 2>$null | Out-Null
        $checkExit = $LASTEXITCODE
        $checks = if (Test-Path "$base\last-check.txt") { (Get-Content "$base\last-check.txt" -Encoding UTF8) -join "`n" } else { '' }
        $status = (& powershell -NoProfile -ExecutionPolicy Bypass -File $core status 2>$null | Out-String).Trim(); $statusExit = $LASTEXITCODE
        $client = (& powershell -NoProfile -ExecutionPolicy Bypass -File $core get-client 2>$null | Out-String).Trim(); $clientExit = $LASTEXITCODE
        [pscustomobject]@{ Checks = $checks; CheckExit = $checkExit; Status = $status; StatusExit = $statusExit; Client = $client; ClientExit = $clientExit }
    }
    Start-UiOperation 'refresh' $work @($CORE,$BASE)
}
function Switch-To($target) {
    if ($script:isBusy -or $target -notin @('A','B','C','D')) { return }
    if (-not $script:environmentReady) { Set-Banner '上次检查未通过，切换前必须重新完成审计' 'warn' } else { Set-Banner "正在执行账号 $target 的切换前审计…" 'info' }
    $script:pendingSwitch = $target
    Refresh-Checks
}
function Complete-UiOperation([string]$Operation, $Result) {
    if ($Operation -eq 'refresh') {
        if (-not $Result) { $script:pendingSwitch = ''; $script:environmentReady = $false; Set-Status '检查失败' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71)); Set-Banner '核心脚本没有返回检查结果' 'error'; Set-Busy $false; return }
        $statusOk = $Result.StatusExit -eq 0 -and (Apply-StatusOutput $Result.Status)
        $clientOk = $Result.ClientExit -eq 0 -and (Apply-ClientOutput $Result.Client)
        $checksOk = Apply-CheckOutput $Result.Checks $Result.CheckExit
        $script:environmentReady = $checksOk -and $statusOk -and $clientOk
        if (-not $statusOk -or -not $clientOk) { $script:environmentReady = $false; Set-Status '状态异常' ([System.Windows.Media.Color]::FromRgb(0xF8,0x71,0x71)); Set-Banner '无法读取账号或代理客户端状态，请更新核心脚本后重试' 'error' }
        Set-Busy $false
        if ($script:environmentReady -and $script:pendingSwitch) {
            $next = [string]$script:pendingSwitch
            $script:pendingSwitch = ''
            Set-Status '切换中' ([System.Windows.Media.Color]::FromRgb(0x60,0xA5,0xFA)); Set-Banner "正在切换到账号 $next…" 'info'
            Start-CommandOperation 'switch' @('switch',$next)
        } else {
            $script:pendingSwitch = ''
        }
        return
    }
    $text = if ($Result -and $Result.Text) { [string]$Result.Text } else { '' }
    $exit = if ($Result -and $null -ne $Result.Exit) { [int]$Result.Exit } else { 1 }
    if ($Operation -eq 'fix') {
        $line = $text -split "`r?`n" | Where-Object { $_ -match '^FIX:.*(FAIL|✗|无法|未恢复|未完全|未找到|模式|规则|TUN)' } | Select-Object -Last 1
        Set-Banner $(if ($line) { $line.Trim() } elseif ($text) { $text } else { '修复流程结束' }) $(if ($exit -eq 0 -and $text -notmatch 'FAIL|✗') { 'info' } else { 'error' }); Refresh-Checks; return
    }
    if ($Operation -eq 'switch') {
        if ($exit -eq 0 -and $text -match '(?m)^(OK|INFO):' -and $text -notmatch '(?m)^FAIL:') { Set-Banner '账号切换完成，Claude 启动中' 'success' }
        else { Set-Banner $(if ($text) { $text } else { '切换未返回成功结果，请重试' }) 'error' }
        Refresh-Checks; return
    }
    if ($Operation -in @('set-client','set-region')) {
        if ($exit -eq 0 -and $text -match '(?m)^OK:') { Set-Banner ($text -split "`r?`n" | Select-Object -Last 1) 'success' }
        else { Set-Banner $(if ($text) { $text } else { '操作失败，请重试' }) 'error' }
        Refresh-Checks; return
    }
    if ($Operation -like 'tool:*') {
        if ($script:activeToolOutput) { $script:activeToolOutput.Text = if ($text) { $text } else { '没有返回内容' }
            $script:activeToolOutput.ScrollToEnd() }
        Set-Busy $false; return
    }
    if ($Operation -eq 'open-safe') { Set-Banner $(if ($text) { $text } else { '操作完成' }) $(if ($exit -eq 0) { 'success' } else { 'error' }); return }
    if ($Operation -in @('snapshot-export','snapshot-import')) {
        [void][System.Windows.MessageBox]::Show($(if ($text) { $text } else { '操作失败' }), $(if ($exit -eq 0) { '快照操作完成' } else { '快照操作失败' }))
        Refresh-Checks
    }
}
function Show-TextTool([string]$Command) {
    if ($script:isBusy) { return }
    if ($script:activeToolOutput) { $script:activeToolOutput.Text = "正在执行 $Command…" }
    Start-CommandOperation "tool:$Command" @($Command)
}
function Show-ToolsWindow {
    if ($script:isBusy) { return }
    $toolsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="维护工具" Width="620" Height="700" MinWidth="500" MinHeight="520" ResizeMode="CanResize" WindowStartupLocation="CenterOwner" Background="#FF12141D" Foreground="White" FontFamily="Segoe UI">
    <Grid Margin="22"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,16"><TextBlock Text="维护工具" FontSize="21" FontWeight="Bold"/><TextBlock Text="只读体检、隔离打开与加密快照迁移" FontSize="11" Foreground="#B3FFFFFF" Margin="0,4,0,0"/></StackPanel>
        <UniformGrid Grid.Row="1" Columns="2">
            <Button x:Name="BtnFingerprint" Content="设备指纹体检" Margin="0,0,6,8" Padding="12,9"/><Button x:Name="BtnCliInfo" Content="Claude Code CLI 体检" Margin="6,0,0,8" Padding="12,9"/>
            <Button x:Name="BtnOpenSafe" Content="安全打开链接…" Margin="0,0,6,8" Padding="12,9"/><Button x:Name="BtnRegion" Content="重新适配出口地区" Margin="6,0,0,8" Padding="12,9"/>
            <Button x:Name="BtnSnapshotExport" Content="导出加密快照…" Margin="0,0,6,8" Padding="12,9"/><Button x:Name="BtnSnapshotImport" Content="导入加密快照…" Margin="6,0,0,8" Padding="12,9"/>
        </UniformGrid>
        <Border Grid.Row="2" CornerRadius="10" Background="#0DFFFFFF" BorderBrush="#1FFFFFFF" BorderThickness="1" Padding="10" Margin="0,8,0,0">
            <TextBox x:Name="ToolOutput" Text="选择上方工具；体检结果只显示在本机。" FontFamily="Consolas" FontSize="12" Foreground="#E6FFFFFF" Background="Transparent" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
        </Border>
        <Button x:Name="BtnCloseTools" Grid.Row="3" Content="关闭" HorizontalAlignment="Right" Margin="0,14,0,0" Padding="16,7"/>
    </Grid>
</Window>
"@
    $toolReader = New-Object System.Xml.XmlNodeReader ([xml]$toolsXaml)
    $toolWin = [Windows.Markup.XamlReader]::Load($toolReader); $toolWin.Owner = $win
    $script:activeToolOutput = $toolWin.FindName('ToolOutput')
    $toolWin.FindName('BtnFingerprint').Add_Click({ Show-TextTool 'fingerprint' })
    $toolWin.FindName('BtnCliInfo').Add_Click({ Show-TextTool 'cli-info' })
    $toolWin.FindName('BtnOpenSafe').Add_Click({ Show-OpenSafeDialog $toolWin })
    $toolWin.FindName('BtnRegion').Add_Click({ if (-not $script:isBusy) { $toolWin.Close(); Set-Banner '正在重新适配出口地区，可能需要管理员授权…' 'info'; Start-CommandOperation 'set-region' @('set-region') } })
    $toolWin.FindName('BtnSnapshotExport').Add_Click({ Show-SnapshotDialog 'export' $toolWin })
    $toolWin.FindName('BtnSnapshotImport').Add_Click({ Show-SnapshotDialog 'import' $toolWin })
    $toolWin.FindName('BtnCloseTools').Add_Click({ $toolWin.Close() })
    $toolWin.Add_Closed({ $script:activeToolOutput = $null })
    [void]$toolWin.ShowDialog()
}
function Show-OpenSafeDialog($Owner) {
    if ($script:isBusy) { return }
    $inputXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="安全打开链接" Width="520" Height="230" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF12141D" Foreground="White">
    <StackPanel Margin="22"><TextBlock Text="在一次性隔离浏览器中打开" FontSize="18" FontWeight="Bold"/><TextBlock Text="仅支持 http/https；会话会随窗口关闭销毁" FontSize="11" Foreground="#B3FFFFFF" Margin="0,5,0,14"/>
        <TextBox x:Name="SafeUrl" ToolTip="输入完整 http/https 链接"/>
        <TextBlock x:Name="SafeError" Foreground="#FFF87171" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0"><Button x:Name="BtnCancelSafe" Content="取消" Padding="14,7" Margin="0,0,8,0"/><Button x:Name="BtnConfirmSafe" Content="隔离打开" Padding="14,7" Background="#FF6366F1"/></StackPanel>
    </StackPanel>
</Window>
"@
    $inputReader = New-Object System.Xml.XmlNodeReader ([xml]$inputXaml); $inputWin = [Windows.Markup.XamlReader]::Load($inputReader); $inputWin.Owner = $Owner
    $inputWin.FindName('BtnCancelSafe').Add_Click({ $inputWin.Close() })
    $inputWin.FindName('BtnConfirmSafe').Add_Click({
        $url = $inputWin.FindName('SafeUrl').Text.Trim()
        if ($url -notmatch '^https?://\S+$') { $inputWin.FindName('SafeError').Text = '请输入完整 http/https 链接'; return }
        $inputWin.Close(); $Owner.Close(); Set-Banner '正在启动一次性隔离浏览器…' 'info'; Start-CommandOperation 'open-safe' @('open-safe',$url)
    })
    [void]$inputWin.ShowDialog()
}
function Show-SnapshotDialog([string]$Kind, $Owner) {
    if ($script:isBusy) { return }
    $slots = if ($Kind -eq 'export') { @($script:archivedAccounts | Where-Object { $_ -ne $script:currentAccount }) } else { @('A','B','C','D' | Where-Object { $script:archivedAccounts -notcontains $_ }) }
    if (-not $slots.Count) { [void][System.Windows.MessageBox]::Show($(if ($Kind -eq 'export') { '没有可导出的已归档账号，请先切换一次完成归档' } else { '没有空账号槽位可导入' }), '快照迁移'); return }
    $dialogXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="加密快照迁移" Width="500" Height="420" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#FF12141D" Foreground="White">
    <StackPanel Margin="22"><TextBlock x:Name="SnapshotTitle" FontSize="19" FontWeight="Bold"/><TextBlock Text="Windows .csnap 格式；密码无法找回，不与 macOS DMG 兼容" FontSize="11" Foreground="#B3FFFFFF" TextWrapping="Wrap" Margin="0,5,0,14"/>
        <TextBlock Text="账号槽位" FontSize="11"/><ComboBox x:Name="SnapshotSlot" MinHeight="34" Margin="0,4,0,10"/>
        <TextBlock Text="快照文件" FontSize="11"/><Grid Margin="0,4,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="SnapshotPath" IsReadOnly="True"/><Button x:Name="BtnSnapshotBrowse" Grid.Column="1" Content="浏览…" Padding="12,7" Margin="8,0,0,0"/></Grid>
        <TextBlock Text="密码（至少 8 位）" FontSize="11"/><PasswordBox x:Name="SnapshotPassword" Margin="0,4,0,10"/>
        <StackPanel x:Name="SnapshotConfirmPanel"><TextBlock Text="再次输入密码" FontSize="11"/><PasswordBox x:Name="SnapshotConfirm" Margin="0,4,0,0"/></StackPanel>
        <TextBlock x:Name="SnapshotError" Foreground="#FFF87171" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"/>
        <Button x:Name="BtnSnapshotSubmit" Content="开始" HorizontalAlignment="Right" Padding="16,8" Background="#FF6366F1" Margin="0,12,0,0"/>
    </StackPanel>
</Window>
"@
    $dialogReader = New-Object System.Xml.XmlNodeReader ([xml]$dialogXaml); $dialogWin = [Windows.Markup.XamlReader]::Load($dialogReader); $dialogWin.Owner = $Owner
    $dialogWin.FindName('SnapshotTitle').Text = if ($Kind -eq 'export') { '导出加密快照' } else { '导入加密快照' }
    if ($Kind -eq 'import') { $dialogWin.FindName('SnapshotConfirmPanel').Visibility = 'Collapsed'; $dialogWin.Height = 360 }
    foreach ($slot in $slots) { [void]$dialogWin.FindName('SnapshotSlot').Items.Add($slot) }
    $dialogWin.FindName('SnapshotSlot').SelectedIndex = 0
    $dialogWin.FindName('BtnSnapshotBrowse').Add_Click({
        if ($Kind -eq 'export') {
            $dialog = New-Object Microsoft.Win32.SaveFileDialog; $dialog.FileName = "account-$($dialogWin.FindName('SnapshotSlot').SelectedItem).csnap"; $dialog.Filter = 'Claude 加密快照|*.csnap'; $dialog.DefaultExt = '.csnap'; $dialog.AddExtension = $true
        } else {
            $dialog = New-Object Microsoft.Win32.OpenFileDialog; $dialog.Filter = 'Claude 加密快照|*.csnap'
        }
        if ($dialog.ShowDialog() -eq $true) { $dialogWin.FindName('SnapshotPath').Text = $dialog.FileName }
    })
    $dialogWin.FindName('BtnSnapshotSubmit').Add_Click({
        $slot = [string]$dialogWin.FindName('SnapshotSlot').SelectedItem; $path = $dialogWin.FindName('SnapshotPath').Text.Trim()
        $password = $dialogWin.FindName('SnapshotPassword').Password
        if (-not $path -or $password.Length -lt 8) { $dialogWin.FindName('SnapshotError').Text = '请选择文件并输入至少 8 位密码'; return }
        if ($Kind -eq 'export' -and $password -cne $dialogWin.FindName('SnapshotConfirm').Password) { $dialogWin.FindName('SnapshotError').Text = '两次密码不一致'; return }
        $args = if ($Kind -eq 'export') { @('snapshot-export',$slot,$path,'--password-stdin') } else { @('snapshot-import',$path,$slot,'--password-stdin') }
        $dialogWin.Close(); $Owner.Close(); Set-Banner '正在校验并处理加密快照…' 'info'; Start-CommandOperation "snapshot-$Kind" $args $password
    })
    [void]$dialogWin.ShowDialog()
}
function Show-CheckSettings {
    $configJson = Invoke-Core @('get-check-config')
    if ($script:lastCoreExit -ne 0 -or [string]::IsNullOrWhiteSpace($configJson)) { [void][System.Windows.MessageBox]::Show('无法读取检查设置，请确认核心脚本已更新。', '检查设置'); return }
    try { $config = $configJson | ConvertFrom-Json -ErrorAction Stop } catch { [void][System.Windows.MessageBox]::Show('检查设置格式无效，请恢复默认设置。', '检查设置'); return }
    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="检查设置" Width="540" Height="650" MinWidth="480" MinHeight="520" ResizeMode="CanResize" WindowStartupLocation="CenterOwner" Background="#FF12141D" Foreground="White">
    <Grid Margin="22"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,14"><TextBlock Text="检查设置" FontSize="20" FontWeight="Bold"/><TextBlock Text="硬性安全项始终执行；跳过不等于通过" FontSize="11" Foreground="#B3FFFFFF" Margin="0,4,0,0"/></StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel>
            <Border CornerRadius="10" Background="#0DFFFFFF" Padding="14" Margin="0,0,0,12"><StackPanel><TextBlock Text="可自定义的非关键检查" FontWeight="Bold" Margin="0,0,0,10"/>
                <CheckBox x:Name="Check_IP" Content="IP 与上次一致" Margin="0,5"/><CheckBox x:Name="Check_DNS" Content="DNS 走隧道" Margin="0,5"/><CheckBox x:Name="Check_WebRTC" Content="WebRTC" Margin="0,5"/>
                <CheckBox x:Name="Check_Locale" Content="客户端语言" Margin="0,5"/><CheckBox x:Name="Check_ASN" Content="ASN 属性" Margin="0,5"/><CheckBox x:Name="Check_Eco" Content="生态可达性" Margin="0,5"/>
                <TextBlock Text="关闭后会真正跳过探测，并以灰色显示。出口国家、代理/TUN、Kill-Switch、保镖、账号归档和更新校验不可关闭。" FontSize="11" Foreground="#B3FFFFFF" TextWrapping="Wrap" Margin="0,8,0,0"/>
            </StackPanel></Border>
            <Border CornerRadius="10" Background="#0DFFFFFF" Padding="14" Margin="0,0,0,12"><StackPanel><CheckBox x:Name="CheckAllow" Content="将上述非关键项的失败降为警告" Margin="0,5"/><TextBlock Text="只影响以上 6 项，不放宽硬性安全项，也不会自动关闭检测。" FontSize="11" Foreground="#B3FFFFFF" TextWrapping="Wrap" Margin="0,0,0,8"/><CheckBox x:Name="CheckLogging" Content="记录脱敏客户端日志" Margin="0,5"/><TextBlock Text="仅记录版本、命令、退出码、耗时和检查状态，不记录 IP、凭据或账号内容。" FontSize="11" Foreground="#B3FFFFFF" TextWrapping="Wrap"/></StackPanel></Border>
            <Border CornerRadius="10" Background="#0DFFFFFF" Padding="14"><StackPanel><Button x:Name="BtnExportInSettings" Content="导出脱敏诊断日志…" Padding="12,7" HorizontalAlignment="Left"/><TextBlock Text="%USERPROFILE%\.claude-switcher\logs\client.log" FontSize="10" Foreground="#99FFFFFF" Margin="0,8,0,0"/></StackPanel></Border>
        </StackPanel></ScrollViewer>
        <StackPanel Grid.Row="2" Margin="0,14,0,0"><TextBlock x:Name="SettingsMessage" Text="" FontSize="11" Foreground="#FFFACC15" TextWrapping="Wrap" Margin="0,0,0,8"/><StackPanel Orientation="Horizontal"><Button x:Name="BtnDefaults" Content="恢复默认" Padding="12,7"/><Button x:Name="BtnSaveSettings" Content="保存并重新检查" Padding="12,7" Margin="12,0,0,0" FontWeight="Bold" Background="#FF6366F1"/></StackPanel></StackPanel>
    </Grid>
</Window>
"@
    $settingsReader = New-Object System.Xml.XmlNodeReader ([xml]$settingsXaml); $settingsWin = [Windows.Markup.XamlReader]::Load($settingsReader); $settingsWin.Owner = $win
    $map = @(@{ Name = 'IP一致'; Control = 'Check_IP' },@{ Name = 'DNS'; Control = 'Check_DNS' },@{ Name = 'WebRTC'; Control = 'Check_WebRTC' },@{ Name = '客户端语言'; Control = 'Check_Locale' },@{ Name = 'ASN属性'; Control = 'Check_ASN' },@{ Name = '生态可达性'; Control = 'Check_Eco' })
    $disabled = @($config.disabled); foreach ($item in $map) { $settingsWin.FindName($item.Control).IsChecked = ($disabled -notcontains $item.Name) }
    $settingsWin.FindName('CheckAllow').IsChecked = [bool]$config.allowOptionalFailures; $settingsWin.FindName('CheckLogging').IsChecked = [bool]$config.logging
    $settingsWin.FindName('BtnDefaults').Add_Click({ foreach ($item in $map) { $settingsWin.FindName($item.Control).IsChecked = $true }; $settingsWin.FindName('CheckAllow').IsChecked = $false; $settingsWin.FindName('CheckLogging').IsChecked = $true; $settingsWin.FindName('SettingsMessage').Text = '已恢复默认选项，点击保存后生效' })
    $settingsWin.FindName('BtnSaveSettings').Add_Click({
        $newDisabled = @(); foreach ($item in $map) { if ($settingsWin.FindName($item.Control).IsChecked -ne $true) { $newDisabled += $item.Name } }
        $newConfig = [pscustomobject]@{ disabled = @($newDisabled); allowOptionalFailures = [bool]$settingsWin.FindName('CheckAllow').IsChecked; logging = [bool]$settingsWin.FindName('CheckLogging').IsChecked }
        $saveResult = Invoke-Core @('set-check-config', ($newConfig | ConvertTo-Json -Depth 3 -Compress))
        if ($script:lastCoreExit -ne 0 -or $saveResult -notmatch '(?m)^OK:') { $settingsWin.FindName('SettingsMessage').Text = '保存失败，请检查配置后重试'; return }
        $settingsWin.FindName('SettingsMessage').Text = '设置已保存，正在重新检查'; Refresh-Checks
    })
    $settingsWin.FindName('BtnExportInSettings').Add_Click({ Export-DiagnosticLog }); [void]$settingsWin.ShowDialog()
}
function Export-DiagnosticLog {
    $dialog = New-Object Microsoft.Win32.SaveFileDialog; $dialog.Title = '导出脱敏诊断日志'; $dialog.FileName = 'claude-switcher-diagnostics.zip'; $dialog.DefaultExt = '.zip'; $dialog.Filter = 'ZIP 压缩包|*.zip'; $dialog.AddExtension = $true
    if ($dialog.ShowDialog() -ne $true) { return }
    $result = Invoke-Core @('export-diagnostics', $dialog.FileName)
    if ($script:lastCoreExit -eq 0 -and $result -match '(?m)^OK:') { [void][System.Windows.MessageBox]::Show($result, '诊断日志已导出') } else { [void][System.Windows.MessageBox]::Show('诊断日志导出失败，请重试。', '导出失败') }
}

$script:checkJob = $null; $script:checkTimer = $null; $script:checkManual = $false
$script:updateJob = $null; $script:updateTimer = $null; $script:updateRunning = $false; $script:latestVersion = ''
function Get-UiVersion {
    $vf = Join-Path $BASE 'version.txt'
    if (Test-Path -LiteralPath $vf) { try { $v = ([string](Get-Content -LiteralPath $vf -Raw -Encoding UTF8 -ErrorAction Stop)).Trim(); if ($v) { return $v } } catch {} }
    return 'unknown'
}
function ConvertFrom-UpdateOutput([string]$text) { $map = @{}; foreach ($line in ($text -split "`r?`n")) { $kv = $line -split '=', 2; if ($kv.Count -eq 2) { $map[$kv[0].Trim()] = $kv[1].Trim() } }; return $map }
function Write-UpdateCache([string]$status, [string]$latest) { try { $obj = [pscustomobject]@{ checkedAt = (Get-Date).ToString('o'); latest = $latest; status = $status }; [IO.File]::WriteAllText((Join-Path $BASE 'update-check.json'), ($obj | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) } catch {} }
function Read-UpdateCache { $p = Join-Path $BASE 'update-check.json'; if (-not (Test-Path -LiteralPath $p)) { return $null }; try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json) } catch { return $null } }
function Test-UpdateCacheFresh($cache) { if (-not $cache -or -not $cache.checkedAt) { return $false }; try { $hours = ((Get-Date) - [DateTime]::Parse([string]$cache.checkedAt, [Globalization.CultureInfo]::InvariantCulture)).TotalHours; return ($hours -ge 0 -and $hours -lt 24) } catch { return $false } }
function Set-UpdateText([string]$text, [string]$hex) { $win.FindName('UpdateText').Text = $text; $win.FindName('UpdateText').Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }
function Show-UpdateAvailable([string]$latest) { $script:latestVersion = $latest; Set-UpdateText "发现新版本 v$latest（当前 v$(Get-UiVersion)）" '#FFE0E7FF'; $win.FindName('BtnUpdate').Visibility = 'Visible'; $win.FindName('BtnUpdate').IsEnabled = -not $script:isBusy; $win.FindName('BtnLater').Content = '稍后'; $win.FindName('BtnLater').Visibility = 'Visible'; $win.FindName('UpdateBar').Visibility = 'Visible' }
function Show-UpdateNote([string]$text, [bool]$isError) { $script:latestVersion = ''; Set-UpdateText $text $(if ($isError) { '#FFF87171' } else { '#FFE0E7FF' }); $win.FindName('BtnUpdate').Visibility = 'Collapsed'; $win.FindName('BtnLater').Content = '关闭'; $win.FindName('BtnLater').Visibility = 'Visible'; $win.FindName('UpdateBar').Visibility = 'Visible' }
function Show-UpdateChecking { Set-UpdateText '正在检查更新…' '#FFE0E7FF'; $win.FindName('BtnUpdate').Visibility = 'Collapsed'; $win.FindName('BtnLater').Content = '关闭'; $win.FindName('BtnLater').Visibility = 'Visible'; $win.FindName('UpdateBar').Visibility = 'Visible' }
function Start-UpdateCheck([bool]$manual) {
    if ($script:updateRunning) { return }
    if ($script:checkJob) { if ($script:checkJob.State -in @('Running','NotStarted')) { if ($manual) { $script:checkManual = $true; Show-UpdateChecking }; return }; Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue; $script:checkJob = $null }
    if (-not $manual) { $cache = Read-UpdateCache; if (Test-UpdateCacheFresh $cache) { if ($cache.status -eq 'update_available' -and $cache.latest) { Show-UpdateAvailable ([string]$cache.latest); return }; if ($cache.status -eq 'dismissed') { return } } }
    if ($script:checkTimer) { $script:checkTimer.Stop(); $script:checkTimer = $null }
    $script:checkManual = $manual; if ($manual) { Show-UpdateChecking }
    try { $script:checkJob = Start-Job -ScriptBlock { param($core) & powershell -NoProfile -ExecutionPolicy Bypass -File $core check-update 2>$null } -ArgumentList $CORE } catch { $script:checkJob = $null; if ($manual) { Show-UpdateNote ("检查更新失败：" + $_.Exception.Message) $true }; return }
    $script:checkTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:checkTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:checkTimer.Add_Tick({
        if (-not $script:checkJob) { $script:checkTimer.Stop(); return }
        if ($script:checkJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:checkTimer.Stop(); $out = (Receive-Job $script:checkJob -ErrorAction SilentlyContinue | Out-String); Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue; $script:checkJob = $null
        $kv = ConvertFrom-UpdateOutput $out; $manualNow = [bool]$script:checkManual
        if ($kv['STATUS'] -eq 'update_available' -and $kv['LATEST']) { Show-UpdateAvailable ([string]$kv['LATEST']); Write-UpdateCache 'update_available' ([string]$kv['LATEST']) }
        elseif ($manualNow) { if ($kv['STATUS'] -eq 'latest') { Show-UpdateNote ("已是最新版本 v" + $kv['LATEST']) $false; Write-UpdateCache 'latest' ([string]$kv['LATEST']) } else { Show-UpdateNote ("检查更新失败：" + $(if ($kv['MESSAGE']) { $kv['MESSAGE'] } else { '无法获取更新信息' })) $true } }
        elseif ($kv['STATUS'] -eq 'latest') { Write-UpdateCache 'latest' ([string]$kv['LATEST']) }
    }); $script:checkTimer.Start()
}

$win.FindName('BtnRefresh').Add_Click({ Refresh-Checks })
$win.FindName('BtnFix').Add_Click({ if (-not $script:isBusy) { Set-Status '修复中' ([System.Windows.Media.Color]::FromRgb(0xFB,0x92,0x3C)); Set-Banner '正在修复…（可能弹出管理员授权框）' 'info'; Start-CommandOperation 'fix' @('fix') } })
foreach ($slot in @('A','B','C','D')) { $win.FindName("Btn$slot").Add_Click({ Switch-To $slot }.GetNewClosure()) }
$win.FindName('ProxyClient').Add_SelectionChanged({ if ($script:suppressClientEvent -or $script:isBusy) { return }; $selected = $win.FindName('ProxyClient').SelectedItem; if (-not $selected) { return }; $mode = [string]$selected.Tag; if ($clientModes -contains $mode -and $mode -ne $script:currentClient) { Set-Banner "正在切换代理客户端为 $mode…" 'info'; Start-CommandOperation 'set-client' @('set-client',$mode) } })
$win.FindName('BtnTools').Add_Click({ Show-ToolsWindow }); $win.FindName('BtnSettings').Add_Click({ Show-CheckSettings }); $win.FindName('BtnDiagnostics').Add_Click({ Export-DiagnosticLog })
$win.FindName('BtnCheckUpdate').Add_Click({ if ($script:updateRunning -or $script:isBusy) { return }; Remove-Item -LiteralPath (Join-Path $BASE 'update-check.json') -Force -ErrorAction SilentlyContinue; Start-UpdateCheck $true })
$win.FindName('BtnLater').Add_Click({ if ($script:checkJob) { Stop-Job $script:checkJob -ErrorAction SilentlyContinue; Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue; $script:checkJob = $null }; if ($script:checkTimer) { $script:checkTimer.Stop() }; $win.FindName('UpdateBar').Visibility = 'Collapsed'; Write-UpdateCache 'dismissed' $(if ($script:latestVersion) { [string]$script:latestVersion } else { '' }) })
$win.FindName('BtnUpdate').Add_Click({
    if ($script:updateRunning -or $script:isBusy) { return }
    $script:updateRunning = $true; $win.FindName('BtnUpdate').IsEnabled = $false; $win.FindName('BtnLater').IsEnabled = $false; $win.FindName('BtnCheckUpdate').IsEnabled = $false
    if ($script:updateTimer) { $script:updateTimer.Stop(); $script:updateTimer = $null }; Set-UpdateText '正在下载并校验…' '#FFE0E7FF'
    try { $script:updateJob = Start-Job -ScriptBlock { param($core) & powershell -NoProfile -ExecutionPolicy Bypass -File $core update-now 2>$null } -ArgumentList $CORE } catch { $script:updateRunning = $false; $win.FindName('BtnUpdate').IsEnabled = $true; $win.FindName('BtnLater').IsEnabled = $true; $win.FindName('BtnCheckUpdate').IsEnabled = $true; Set-UpdateText ("更新失败：" + $_.Exception.Message) '#FFF87171'; return }
    $script:updateTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:updateTimer.Add_Tick({
        if (-not $script:updateJob) { $script:updateTimer.Stop(); return }; if ($script:updateJob.State -notin @('Completed','Failed','Stopped')) { return }
        $script:updateTimer.Stop(); $out = (Receive-Job $script:updateJob -ErrorAction SilentlyContinue | Out-String); Remove-Job $script:updateJob -Force -ErrorAction SilentlyContinue; $script:updateJob = $null; $script:updateRunning = $false
        $kv = ConvertFrom-UpdateOutput $out
        if ($kv['STATUS'] -eq 'updated') {
            Set-UpdateText '更新完成，正在重启界面' '#FF22C55E'; Write-UpdateCache 'latest' ([string]$kv['LATEST'])
            if ($script:checkJob) { Stop-Job $script:checkJob -ErrorAction SilentlyContinue; Remove-Job $script:checkJob -Force -ErrorAction SilentlyContinue; $script:checkJob = $null }
            Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + "$BASE\SwitcherUI.ps1" + '"'); $win.Close()
        } elseif ($kv['STATUS'] -eq 'latest') { $win.FindName('BtnUpdate').IsEnabled = $true; $win.FindName('BtnLater').IsEnabled = $true; $win.FindName('BtnCheckUpdate').IsEnabled = $true; Show-UpdateNote '已是最新版本' $false; Write-UpdateCache 'latest' ([string]$kv['LATEST']) }
        else { Set-UpdateText ("更新失败：" + $(if ($kv['MESSAGE']) { $kv['MESSAGE'] } else { '更新失败，请稍后重试' })) '#FFF87171'; $win.FindName('BtnUpdate').IsEnabled = $true; $win.FindName('BtnLater').IsEnabled = $true; $win.FindName('BtnCheckUpdate').IsEnabled = $true }
    }); $script:updateTimer.Start()
})
$win.Add_ContentRendered({ Start-UpdateCheck $false; Refresh-Checks })
$win.Add_Closing({ if ($script:isBusy -or $script:updateRunning) { $_.Cancel = $true; Set-Banner '正在执行写入或切换操作，请等待完成后再关闭' 'warn' } })
$win.Add_Closed({ foreach ($timer in @($script:uiTimer,$script:checkTimer,$script:updateTimer)) { if ($timer) { $timer.Stop() } }; foreach ($job in @($script:uiJob,$script:checkJob,$script:updateJob)) { if ($job) { Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue } } })
[void]$win.ShowDialog()
