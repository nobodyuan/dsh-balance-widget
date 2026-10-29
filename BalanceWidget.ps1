# BalanceWidget - 桌面余额悬浮窗 (PowerShell + WPF, 无需编译)
# 显示: WorkBuddy 算力余额 + DeepSeek(dsh) 余额, 每5分钟刷新, 按余量变色
# 启动: powershell -ExecutionPolicy Bypass -File BalanceWidget.ps1
# 退出/菜单: 右键窗口

$ErrorActionPreference = 'Stop'

# ---------- 启动日志 ----------
$script:logPath = Join-Path $env:LOCALAPPDATA 'BalanceWidget\widget.log'
function Write-Log([string]$m) {
    try {
        if ((Test-Path $script:logPath) -and ((Get-Item $script:logPath).Length -gt 200KB)) {
            Set-Content -Path $script:logPath -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        "$(Get-Date -Format 'HH:mm:ss') [pid=$PID] $m" | Add-Content -Path $script:logPath -Encoding UTF8
    } catch { }
}
Write-Log "启动: 参数=$($MyInvocation.Line)"

# ---------- 单实例保护：已在运行则直接退出 ----------
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\BalanceWidget_SingleInstance')
if (-not $script:mutex.WaitOne(0)) { Write-Log "已有实例在运行, 退出"; exit 0 }
Write-Log "获得单实例锁"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- 路径与配置 ----------
$cfgDir  = Join-Path $env:LOCALAPPDATA 'BalanceWidget'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$cfgPath = Join-Path $cfgDir 'config.json'
$cachePath = Join-Path $cfgDir 'cache.json'
$posPath = Join-Path $cfgDir 'pos.txt'

if (-not (Test-Path $cfgPath)) {
    @{ workbuddyToken = ''; deepseekApiKey = ''; refreshMinutes = 5 } |
        ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
}
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

# DeepSeek key 兜底: 从 ~/.dsh/.credentials.yaml 读取
if (-not $cfg.deepseekApiKey) {
    $cred = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
    if (Test-Path $cred) {
        $m = Select-String -Path $cred -Pattern 'DEEPSEEK_API_KEY:\s*(sk-[\w\-]+)' | Select-Object -First 1
        if ($m) { $cfg.deepseekApiKey = $m.Matches[0].Groups[1].Value }
    }
}
$wbCookie = [string]$cfg.workbuddyCookie
if (-not $wbCookie -and $cfg.workbuddyToken) { $wbCookie = [string]$cfg.workbuddyToken }
$dsKey   = [string]$cfg.deepseekApiKey
$refreshMin = if ($cfg.refreshMinutes -ge 1) { [int]$cfg.refreshMinutes } else { 5 }
$wbUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0'

function Read-Cache {
    if (Test-Path $cachePath) {
        try { return Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    return @{ wbLeft = ''; wbTotal = ''; wbAt = ''; dsVal = ''; dsAt = '' }
}
function Save-Cache($c) {
    # 容错：多实例/文件占用时不抛异常（否则会被当成接口失败）
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $c | ConvertTo-Json | Set-Content -Path $cachePath -Encoding UTF8 -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    Write-Log "缓存写入失败(文件被占用), 已跳过"
}
$cache = Read-Cache

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- 数据获取 ----------
function Get-WorkBuddy {
    if (-not $wbCookie) { return @{ ok = $false; text = '--'; ratio = -1; tip = '未配置 WorkBuddy 登录态(右键>打开配置文件)' } }
    try {
        $uri = 'https://www.workbuddy.cn/billing/meter/get-user-resource-summary'
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Accept = 'application/json, text/plain, */*'
        $req.Referer = 'https://www.workbuddy.cn/'
        $req.UserAgent = $wbUA
        $req.Headers['Accept-Language'] = 'zh-CN'
        $req.Headers['Origin'] = 'https://www.workbuddy.cn'
        $req.Timeout = 20000
        # 手动解析 Cookie，避免 PowerShell 转义问题
        $req.Headers['Cookie'] = $wbCookie
        $body = [System.Text.Encoding]::UTF8.GetBytes('{}')
        $req.ContentLength = $body.Length
        $rs = $req.GetRequestStream()
        $rs.Write($body, 0, $body.Length)
        $rs.Close()
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $jsonText = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        $r = $jsonText | ConvertFrom-Json
        $total = 0.0; $left = 0.0
        if ($r.data.Packages) {
            foreach ($p in $r.data.Packages) {
                $t = 0.0; $l = 0.0
                [double]::TryParse("$($p.CycleTotalCapacity)", [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$t) | Out-Null
                [double]::TryParse("$($p.CycleRemainCapacity)", [Globalization.NumberStyles]::Any, [Globalization.CultureInfo]::InvariantCulture, [ref]$l) | Out-Null
                if ($t -le 0 -and $l -le 0) {
                    [double]::TryParse("$($p.CycleTotalCapacityPrecise)", 'Any', 'InvariantCulture', [ref]$t) | Out-Null
                    [double]::TryParse("$($p.CycleRemainCapacityPrecise)", 'Any', 'InvariantCulture', [ref]$l) | Out-Null
                }
                $total += $t; $left += $l
            }
        }
        # 若 Packages 无有效数据，回退到 TotalCredits
        if ($total -le 0 -and $left -le 0 -and $r.data.TotalCredits) {
            $left = [double]$r.data.TotalCredits; $total = 800.0
        }
        if ($total -gt 0 -or $left -gt 0) {
            $script:cache.wbLeft = "$left"; $script:cache.wbTotal = "$total"; $script:cache.wbAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Save-Cache $script:cache
            $subName = ''
            try { $subName = $r.data.SubscriptionPackageName } catch { }
            return @{ ok = $true; text = ('{0:0.##} / {1:0.##}' -f $left, $total); ratio = if ($total -gt 0) { $left / $total } else { -1 };
                     tip = "WorkBuddy 算力$(if ($subName) { ' · ' + $subName })" }
        }
        return @{ ok = $false; text = '--'; ratio = -1; tip = '响应中无算力包数据' }
    } catch {
        if ($script:cache.wbLeft -ne '') {
            return @{ ok = $true; stale = $true; text = ('{0:0.##} / {1:0.##} *' -f [double]$script:cache.wbLeft, [double]$script:cache.wbTotal);
                     ratio = if ([double]$script:cache.wbTotal -gt 0) { [double]$script:cache.wbLeft / [double]$script:cache.wbTotal } else { -1 };
                     tip = "WorkBuddy 缓存数据(接口异常): $($_.Exception.Message)" }
        }
        return @{ ok = $false; text = '--'; ratio = -1; tip = "WorkBuddy: $($_.Exception.Message)" }
    }
}

function Get-DeepSeek {
    if (-not $dsKey) { return @{ ok = $false; text = '--'; ratio = -1; tip = '未配置 DeepSeek API Key' } }
    try {
        $headers = @{ Authorization = "Bearer $dsKey" }
        # 境外端点间歇性超时，重试 3 次（800ms 退避），与 dsh-pet 的余额实现同口径
        $r = $null; $lastErr = $null
        for ($i = 0; $i -lt 3; $i++) {
            try {
                $r = Invoke-RestMethod -Uri 'https://api.deepseek.com/user/balance' -Headers $headers -TimeoutSec 15
                break
            } catch {
                $lastErr = $_
                if ($i -lt 2) { Start-Sleep -Milliseconds 800 }
            }
        }
        if (-not $r) { throw $lastErr }
        $v = [double]$r.balance_infos[0].total_balance
        $cur = $r.balance_infos[0].currency
        $script:cache.dsVal = "$v"; $script:cache.dsAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Save-Cache $script:cache
        return @{ ok = $true; text = ('¥{0:0.##}' -f $v); ratio = [Math]::Min(1.0, $v / 50.0); tip = "DeepSeek 开放平台余额 ($cur), 满 ¥50 显示为满格" }
    } catch {
        Write-Log ("DeepSeek 查询失败: " + $_.Exception.Message)
        if ($script:cache.dsVal -ne '') {
            return @{ ok = $true; stale = $true; text = ('¥{0:0.##} *' -f [double]$script:cache.dsVal); ratio = [Math]::Min(1.0, [double]$script:cache.dsVal / 50.0);
                     tip = "DeepSeek 缓存数据(接口异常): $($_.Exception.Message)" }
        }
        return @{ ok = $false; text = '--'; ratio = -1; tip = "DeepSeek: $($_.Exception.Message)" }
    }
}

function Get-RatioColor([double]$ratio, [bool]$unknown) {
    if ($unknown -or $ratio -lt 0) { return [Windows.Media.Brushes]::Gray }
    if ($ratio -gt 0.8) { $c = [Windows.Media.Color]::FromRgb(0x30,0xC4,0x78) }
    elseif ($ratio -gt 0.6) { $c = [Windows.Media.Color]::FromRgb(0x40,0x8C,0xFF) }
    elseif ($ratio -gt 0.4) { $c = [Windows.Media.Color]::FromRgb(0xA8,0x6C,0xFF) }
    elseif ($ratio -gt 0.2) { $c = [Windows.Media.Color]::FromRgb(0xFF,0xC8,0x3C) }
    elseif ($ratio -gt 0.1) { $c = [Windows.Media.Color]::FromRgb(0xFF,0x96,0x3C) }
    else { $c = [Windows.Media.Color]::FromRgb(0xFF,0x5C,0x40) }
    return New-Object Windows.Media.SolidColorBrush($c)
}

# ---------- UI ----------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BalanceWidget" Width="250" Height="112"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False">
  <Border x:Name="Card" CornerRadius="14" Background="#F01C1D22" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="14,10">
    <Grid>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition Height="16"/></Grid.RowDefinitions>
      <Grid.ColumnDefinitions><ColumnDefinition Width="70"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <TextBlock Grid.Row="0" Text="WB 算力" Foreground="#A0C8C8D2" FontSize="11" VerticalAlignment="Center"/>
      <TextBlock x:Name="WbVal"  Grid.Row="0" Grid.Column="1" Text="..." FontFamily="Consolas" FontSize="17" FontWeight="Bold" VerticalAlignment="Center"/>
      <TextBlock Grid.Row="1" Text="dsh 余额" Foreground="#A0C8C8D2" FontSize="11" VerticalAlignment="Center"/>
      <TextBlock x:Name="DsVal"  Grid.Row="1" Grid.Column="1" Text="..." FontFamily="Consolas" FontSize="17" FontWeight="Bold" VerticalAlignment="Center"/>
      <TextBlock x:Name="Status" Grid.Row="2" Grid.ColumnSpan="2" Text="初始化…" FontSize="9" Foreground="#78A0A0AA" VerticalAlignment="Bottom"/>
    </Grid>
  </Border>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$wbVal = $win.FindName('WbVal'); $dsVal = $win.FindName('DsVal'); $status = $win.FindName('Status')

# 记住位置
if (Test-Path $posPath) {
    try {
        $p = (Get-Content $posPath -Raw).Split(',')
        $win.WindowStartupLocation = 'Manual'
        $win.Left = [double]$p[0]; $win.Top = [double]$p[1]
    } catch { }
} else {
    $win.WindowStartupLocation = 'Manual'
    $win.Left = 200; $win.Top = 120
}

$script:topmost = $true
$win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch { } })
$win.Add_MouseDoubleClick({ Update-All })

$win.Add_MouseRightButtonUp({
    $menu = New-Object Windows.Controls.ContextMenu
    $i1 = New-Object Windows.Controls.MenuItem; $i1.Header = '刷新余额'
    $i1.Add_Click({ Update-All }); [void]$menu.Items.Add($i1)
    $i2 = New-Object Windows.Controls.MenuItem; $i2.Header = '窗口置顶'; $i2.IsCheckable = $true; $i2.IsChecked = $script:topmost
    $i2.Add_Click({ $script:topmost = -not $script:topmost; $win.Topmost = $script:topmost }); [void]$menu.Items.Add($i2)
    $i3 = New-Object Windows.Controls.MenuItem; $i3.Header = '打开配置文件'
    $i3.Add_Click({ Start-Process notepad.exe $cfgPath }); [void]$menu.Items.Add($i3)
    $i35 = New-Object Windows.Controls.MenuItem; $i35.Header = '停用跟随启动(下次dsh不再出现)'
    $i35.Add_Click({
        try {
            $c = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $c | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force
            $c | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgPath -Encoding UTF8
            Write-Log "用户已停用跟随启动 (enabled=false)"
        } catch { Write-Log ("停用写入失败: " + $_.Exception.Message) }
        $win.Close()
    }); [void]$menu.Items.Add($i35)
    $i4 = New-Object Windows.Controls.MenuItem; $i4.Header = '退出'
    $i4.Add_Click({ $win.Close() }); [void]$menu.Items.Add($i4)
    $win.ContextMenu = $menu
    $win.ContextMenu.IsOpen = $true
})

$win.Add_MouseLeave({ $status.Text = $script:lastStatus })

function Update-All {
    try {
        Write-Log "开始刷新"
        $wb = Get-WorkBuddy
        $ds = Get-DeepSeek
        Write-Log "刷新结果: wb=$($wb.text) (ok=$($wb.ok)) | ds=$($ds.text) (ok=$($ds.ok))"
        $wbVal.Text = $wb.text;  $wbVal.Foreground = Get-RatioColor ([double]$wb.ratio) (-not $wb.ok)
        $dsVal.Text = $ds.text;  $dsVal.Foreground = Get-RatioColor ([double]$ds.ratio) (-not $ds.ok)
        $wbVal.ToolTip = $wb.tip; $dsVal.ToolTip = $ds.tip
        $staleMark = ''
        if ($wb.stale -or $ds.stale) { $staleMark = ' *含缓存' }
        $script:lastStatus = "更新 $(Get-Date -Format 'HH:mm:ss')$staleMark"
        $status.Text = $script:lastStatus
    } catch {
        Write-Log ("刷新异常: " + $_.Exception.Message)
    }
}
$script:lastStatus = ''

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes($refreshMin)
$timer.Add_Tick({ Update-All })
$timer.Start()

$win.Add_Loaded({ Write-Log "窗口已加载, 开始首次刷新"; Update-All })
$win.Add_Closed({
    Write-Log "窗口关闭, 保存位置"
    try { "$($win.Left),$($win.Top)" | Set-Content -Path $posPath -Encoding ASCII } catch { }
})

Write-Log "进入 ShowDialog"
[void]$win.ShowDialog()
Write-Log "ShowDialog 结束, 进程退出"
