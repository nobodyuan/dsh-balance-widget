# BalanceWidget - 桌面余额悬浮窗 (PowerShell + WPF, 无需编译)
# 显示: WorkBuddy 算力余额 + DeepSeek(dsh) 余额/总额, 每5分钟刷新, 按余量变色
# 交互: 拖动(靠近屏幕边缘自动吸附/自动隐藏) / 单击 dsh 行看用量明细 / 双击刷新 / 右键菜单
# 启动: powershell -ExecutionPolicy Bypass -File BalanceWidget.ps1 [-NodePath <node.exe>]
#       -NodePath 由 dsh 插件传入（它自己就是 Node 运行时），省得依赖系统 PATH

param(
    [string]$NodePath = ''
)

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
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch { }

# ---------- 路径与配置 ----------
$cfgDir  = Join-Path $env:LOCALAPPDATA 'BalanceWidget'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$cfgPath = Join-Path $cfgDir 'config.json'
$cachePath = Join-Path $cfgDir 'cache.json'
$posPath = Join-Path $cfgDir 'pos.txt'
$usagePath = Join-Path $cfgDir 'usage.json'

if (-not (Test-Path $cfgPath)) {
    @{ workbuddyCookie = ''; deepseekApiKey = ''; refreshMinutes = 5; deepseekTotal = 0; dailyBudget = 0; snapPx = 26; autoHide = $true; hangPx = 6; hideDelayMs = 450; nodePath = ''; enabled = $true } |
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
$snapPx = if ($null -ne $cfg.snapPx) { [int]$cfg.snapPx } else { 26 }
$dailyBudget = if ($null -ne $cfg.dailyBudget) { [double]$cfg.dailyBudget } else { 0 }
# 贴边自动隐藏：吸附到屏幕边缘后，鼠标离开就缩进去只留一条窄边；鼠标移到窄边上再滑出来
$autoHide = $true
if ($null -ne $cfg.autoHide) { $autoHide = [bool]$cfg.autoHide }
$hangPx = if ($null -ne $cfg.hangPx) { [int]$cfg.hangPx } else { 6 }
$hideDelayMs = if ($null -ne $cfg.hideDelayMs) { [int]$cfg.hideDelayMs } else { 450 }
$script:widgetVersion = '1.3.3'
$wbUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36 Edg/156.0.0.0'

function Save-Config {
    try { $script:cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgPath -Encoding UTF8 } catch { Write-Log "配置写入失败: $($_.Exception.Message)" }
}

# 把「当前跑的版本 + pid」写出来，插件据此判断要不要替换掉旧窗口
try {
    @{ pid = $PID; version = $script:widgetVersion; at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json | Set-Content -Path (Join-Path $cfgDir 'instance.json') -Encoding UTF8
} catch { }

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

# ---------- dsh 用量统计（读本地会话日志） ----------
# 找 Node：悬浮窗是 dsh 拉起来的，PATH 里通常没有 node（本机 node 只在 WorkBuddy 的私有目录里），
# 所以优先级 = 插件传入 > 配置指定 > 环境变量 > PATH > 注册表 PATH > 各常见安装位置。
$script:nodeExe = $null
$script:usageError = ''

function Get-NodePath {
    $tries = New-Object System.Collections.Generic.List[string]
    # dsh 插件每次启动都会把它的 Node 路径写进 node.txt（最可靠的一条路）
    try {
        $hint = Join-Path $cfgDir 'node.txt'
        if (Test-Path -LiteralPath $hint) {
            $hp = (Get-Content -LiteralPath $hint -Raw -Encoding UTF8).Trim()
            if ($hp) { $tries.Add($hp) }
        }
    } catch { }
    foreach ($c in @($NodePath, [string]$cfg.nodePath, [string]$env:BW_NODE)) {
        if ($c -and $c.Trim()) { $tries.Add($c.Trim()) }
    }
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { $tries.Add($c.Source) }

    # 注册表里的 PATH（进程 PATH 不完整时兜底）
    foreach ($scope in @('Machine', 'User')) {
        try {
            $rp = [Environment]::GetEnvironmentVariable('Path', $scope)
            if ($rp) {
                foreach ($seg in ($rp -split ';')) {
                    if ($seg -and $seg.Trim()) { $tries.Add((Join-Path $seg.Trim() 'node.exe')) }
                }
            }
        } catch { }
    }

    $tries.Add("$env:ProgramFiles\nodejs\node.exe")
    $tries.Add("${env:ProgramFiles(x86)}\nodejs\node.exe")
    $tries.Add("$env:LOCALAPPDATA\Programs\nodejs\node.exe")
    $tries.Add("$env:APPDATA\npm\node.exe")

    foreach ($t in $tries) {
        if ($t -and (Test-Path -LiteralPath $t -PathType Leaf)) { return $t }
    }

    # 带版本号的目录：dsh 自带运行时 / WorkBuddy 自带 node / scoop
    $globs = @(
        "$env:USERPROFILE\.dsh\dsh-runtimes\*\dependencies\node\bin\node.exe",
        "$env:USERPROFILE\.dsh\runtimes\*\dependencies\node\bin\node.exe",
        "$env:USERPROFILE\.workbuddy\binaries\node\versions\*\node.exe",
        "$env:USERPROFILE\scoop\apps\nodejs\current\node.exe",
        "$env:LOCALAPPDATA\fnm\node-versions\*\installation\node.exe"
    )
    foreach ($g in $globs) {
        try {
            $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } catch { }
    }
    return $null
}

# 兼容 Electron 的可执行文件：需要 ELECTRON_RUN_AS_NODE=1 才会当 node 跑脚本
function Invoke-NodeScript([string]$exe, [string[]]$argv) {
    $isElectron = ([System.IO.Path]::GetFileName($exe) -match '^electron')
    if ($isElectron) { [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', '1') }
    try {
        $null = & $exe @argv 2>&1
    } finally {
        if ($isElectron) { [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null) }
    }
}

$script:usageCache = $null
function Get-UsageData([bool]$force) {
    $maxAge = 120
    if (-not $force -and $script:usageCache -and (((Get-Date) - $script:usageCache.at).TotalSeconds -lt $maxAge)) {
        return $script:usageCache.data
    }
    if (-not $force -and (Test-Path $usagePath)) {
        $age = ((Get-Date) - (Get-Item $usagePath).LastWriteTime).TotalSeconds
        if ($age -lt $maxAge) {
            try {
                $d = Get-Content $usagePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $script:usageCache = @{ at = Get-Date; data = $d }
                $script:usageError = ''
                return $d
            } catch { }
        }
    }
    if (-not $script:nodeExe) { $script:nodeExe = Get-NodePath }
    $node = $script:nodeExe
    $scanner = Join-Path $PSScriptRoot 'usage-scan.cjs'
    if (-not $node) {
        $script:usageError = "找不到 Node 运行时（PATH 里没有 node，插件也没传 -NodePath）。`n`n不想装 Node 的话：在 config.json 里加一行 `"nodePath`": `"C:\\...\\node.exe`" 指向任意 Node 22+ 即可。"
        Write-Log "未找到 node，跳过用量扫描"
        return $script:usageCache.data
    }
    if (-not (Test-Path -LiteralPath $scanner)) {
        $script:usageError = "用量扫描脚本缺失：$scanner"
        Write-Log $script:usageError
        return $script:usageCache.data
    }
    $sessionsDir = Join-Path $env:USERPROFILE '.dsh\sessions'
    try {
        # 不输出到 stdout，避免阻塞；结果写文件
        Invoke-NodeScript $node @($scanner, $sessionsDir, $usagePath, '--detail')
        if (Test-Path -LiteralPath $usagePath) {
            $d = Get-Content $usagePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:usageCache = @{ at = Get-Date; data = $d }
            $script:usageError = ''
            Write-Log ("用量扫描完成: node=$node 会话={0} 请求={1} 估算=¥{2}" -f $d.sum.usedSessions, $d.sum.steps, $d.sum.cost)
            return $d
        }
        $script:usageError = "扫描没有产出结果（node=$node）"
        Write-Log $script:usageError
    } catch {
        $script:usageError = "扫描失败（node=$node）：$($_.Exception.Message)"
        Write-Log $script:usageError
    }
    return $script:usageCache.data
}

# dsh 总额：优先用配置的手填值；否则用「余额 + 本地估算累计消耗」自动推算
function Get-DsTotal([double]$balance) {
    if ($null -ne $cfg.deepseekTotal -and [double]$cfg.deepseekTotal -gt 0) { return [double]$cfg.deepseekTotal }
    $u = Get-UsageData $false
    if ($u -and $u.sum) { return [Math]::Round($balance + [double]$u.sum.cost, 2) }
    return 0
}

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

        $tot = Get-DsTotal $v
        if ($tot -gt 0) {
            $used = [Math]::Max(0, $tot - $v)
            return @{ ok = $true; text = ('¥{0:0.00} / ¥{1:0.##}' -f $v, $tot); ratio = [Math]::Max(0.0, [Math]::Min(1.0, $v / $tot));
                     tip = ("DeepSeek 余额 ¥{0:0.00}，总额 ¥{1:0.##}，已用 ¥{2:0.00}（{3}）`n单击此处查看每个会话/请求的 token 明细" -f $v, $tot, $used,
                            $(if ($null -ne $cfg.deepseekTotal -and [double]$cfg.deepseekTotal -gt 0) { '总额取自配置' } else { '总额=余额+本地估算消耗' })) }
        }
        return @{ ok = $true; text = ('¥{0:0.00}' -f $v); ratio = [Math]::Min(1.0, $v / 50.0);
                 tip = "DeepSeek 开放平台余额 ($cur)`n右键「设置 dsh 总额」可显示成 余额/总额，例如 0/16`n单击此处查看 token 明细" }
    } catch {
        Write-Log ("DeepSeek 查询失败: " + $_.Exception.Message)
        if ($script:cache.dsVal -ne '') {
            $cv = [double]$script:cache.dsVal
            $tot = Get-DsTotal $cv
            if ($tot -gt 0) {
                return @{ ok = $true; stale = $true; text = ('¥{0:0.00} / ¥{1:0.##} *' -f $cv, $tot); ratio = [Math]::Max(0.0, [Math]::Min(1.0, $cv / $tot));
                         tip = "DeepSeek 缓存数据(接口异常): $($_.Exception.Message)" }
            }
            return @{ ok = $true; stale = $true; text = ('¥{0:0.00} *' -f $cv); ratio = [Math]::Min(1.0, $cv / 50.0);
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

# ---------- 格式化小工具 ----------
function Format-Time($ms) {
    if (-not $ms -or [double]$ms -le 0) { return '--' }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).ToLocalTime().ToString('MM-dd HH:mm') } catch { return '--' }
}
function Format-Num($n) { try { return ('{0:N0}' -f [double]$n) } catch { return '0' } }
function Format-Money($n) {
    try {
        $v = [double]$n
        # 单次请求常常只有几厘钱，太小就多给两位小数，避免全显示成 ¥0.00
        if ($v -ne 0 -and [Math]::Abs($v) -lt 0.01) { return ('¥{0:0.0000}' -f $v) }
        return ('¥{0:0.00}' -f $v)
    } catch { return '¥0.00' }
}

# ---------- 用量明细窗口 ----------
$script:usageWin = $null
$script:uHead = $null; $script:uSub = $null; $script:uSessions = $null; $script:uSteps = $null
$script:uStepLabel = $null; $script:uData = $null
$script:uFilter = $null; $script:uFilterInfo = $null
$script:uDaily = $null; $script:uModels = $null; $script:uWs = $null

function Fill-UsageSessions {
    if (-not $script:uSessions -or -not $script:uData) { return }
    $kw = ''
    if ($script:uFilter) { $kw = ([string]$script:uFilter.Text).Trim() }
    $all = @($script:uData.sessions | Where-Object { $_.steps -gt 0 })
    $rows = $all
    if ($kw) {
        $rows = @($all | Where-Object {
                    $n = if ($_.firstUser) { $_.firstUser } elseif ($_.title) { $_.title } else { '' }
                    ($n -like "*$kw*") -or ($_.id -like "*$kw*") -or ($_.cwd -like "*$kw*") -or ($_.workdir -like "*$kw*")
                })
    }
    $script:uSessions.Items.Clear()
    $script:uSteps.Items.Clear()
    $script:uStepLabel.Text = '该会话的请求明细'
    foreach ($s in $rows) {
        $name = if ($s.firstUser) { $s.firstUser } elseif ($s.title) { $s.title } else { '(未命名会话)' }
        $script:uSessions.Items.Add([PSCustomObject]@{
            Time  = (Format-Time $s.lastTime)
            Task  = $name
            Steps = [string]$s.steps
            In    = (Format-Num $s.inputTokens)
            Out   = (Format-Num $s.outputTokens)
            Cache = (Format-Num $s.cacheReadTokens)
            Cost  = (Format-Money $s.cost)
            Id    = $s.id
        }) | Out-Null
    }
    if ($script:uFilterInfo) {
        $script:uFilterInfo.Text = if ($kw) { "命中 $($rows.Count) / $($all.Count) 个会话" } else { "共 $($all.Count) 个会话" }
    }
    if ($rows.Count -gt 0) { $script:uSessions.SelectedIndex = 0 }

    # 按天
    if ($script:uDaily) {
        $script:uDaily.Items.Clear()
        foreach ($d in @($script:uData.daily)) {
            $script:uDaily.Items.Add([PSCustomObject]@{
                Date   = [string]$d.date
                Steps  = [string]$d.steps
                Peak   = ('{0} ({1:0}%)' -f $d.peakSteps, $(if ($d.steps -gt 0) { 100.0 * $d.peakSteps / $d.steps } else { 0 }))
                In     = (Format-Num $d.in)
                Out    = (Format-Num $d.out)
                Cache  = (Format-Num $d.cacheRead)
                Tokens = (Format-Num $d.totalTokens)
                Cost   = (Format-Money $d.cost)
            }) | Out-Null
        }
    }
    # 按模型
    if ($script:uModels) {
        $script:uModels.Items.Clear()
        foreach ($m in @($script:uData.models)) {
            $script:uModels.Items.Add([PSCustomObject]@{
                Model  = [string]$m.model
                Steps  = [string]$m.steps
                In     = (Format-Num $m.in)
                Out    = (Format-Num $m.out)
                Cache  = (Format-Num $m.cacheRead)
                Tokens = (Format-Num $m.totalTokens)
                Cost   = (Format-Money $m.cost)
            }) | Out-Null
        }
    }
    # 按工作区
    if ($script:uWs) {
        $script:uWs.Items.Clear()
        foreach ($w in @($script:uData.workspaces)) {
            $script:uWs.Items.Add([PSCustomObject]@{
                Workdir  = [string]$w.workdir
                Sessions = [string]$w.sessions
                Steps    = [string]$w.steps
                Tokens   = (Format-Num $w.tokens)
                Cost     = (Format-Money $w.cost)
                Last     = (Format-Time $w.lastTime)
            }) | Out-Null
        }
    }

    $sm = $script:uData.sum
    $todayTxt = if ($null -ne $sm.todayCost) { "　|　今日 {0}（{1} 次请求）" -f (Format-Money $sm.todayCost), $sm.todaySteps } else { '' }
    $script:uHead.Text = ("dsh 累计：估算花费 {0}{1}　|　总 tokens {2}　|　会话 {3} 个" -f (Format-Money $sm.cost), $todayTxt, (Format-Num $sm.totalTokens), $sm.usedSessions)
    $script:uSub.Text = ("输入 {0}（其中缓存命中 {1}）· 输出 {2} · 费用按 DeepSeek 官方峰谷价估算（flash 空闲 缓存0.02/未命中1/输出4 元每百万，高峰翻倍），仅供参考；余额以官方接口为准。" -f (Format-Num $sm.inputTokens), (Format-Num $sm.cacheReadTokens), (Format-Num $sm.outputTokens))
}

function Show-UsageWindow {
    if ($script:usageWin -and $script:usageWin.IsVisible) {
        $script:usageWin.Activate()
        return
    }
    $data = Get-UsageData $false
    # 读不到数据也照样把窗口开出来，把原因写在标题区里（比弹一个看不懂的 MessageBox 好排查）
    $loadErr = ''
    if (-not $data -or -not $data.sum) {
        $loadErr = if ($script:usageError) { $script:usageError } else { '读不到 dsh 会话数据（~/.dsh/sessions 里没有可用记录）' }
        $data = $null
    }

    $ux = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="dsh 用量明细" Width="940" Height="700" MinWidth="800" MinHeight="540"
        WindowStartupLocation="CenterScreen" Background="#FFFAFAFB"
        FontFamily="Microsoft YaHei UI" FontSize="12" Foreground="#FF1F2328">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock x:Name="UHead" Text="统计中…" FontSize="15" FontWeight="SemiBold"/>
      <TextBlock x:Name="USub" Text="" FontSize="11" Foreground="#FF6B7280" Margin="0,4,0,0" TextWrapping="Wrap"/>
    </StackPanel>
    <DockPanel Grid.Row="1" Margin="0,10,0,6">
      <TextBlock Text="按任务筛选：" VerticalAlignment="Center" FontSize="11" Foreground="#FF6B7280"/>
      <TextBlock x:Name="UFilterInfo" DockPanel.Dock="Right" VerticalAlignment="Center" FontSize="11" Foreground="#FF9AA1AB"/>
      <TextBox x:Name="UFilter" Width="260" Height="24" VerticalContentAlignment="Center"
               BorderBrush="#FFD5D9DF" BorderThickness="1" Padding="4,0"/>
    </DockPanel>
    <TabControl x:Name="UTabs" Grid.Row="2" Background="Transparent">
      <TabItem Header="会话">
        <Grid Margin="0,8,0,0">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="190"/>
          </Grid.RowDefinitions>
          <ListView x:Name="USessions" Grid.Row="0" BorderBrush="#FFE5E7EB" BorderThickness="1">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="最近活动" Width="105" DisplayMemberBinding="{Binding Time}"/>
                <GridViewColumn Header="任务（首条提问）" Width="330" DisplayMemberBinding="{Binding Task}"/>
                <GridViewColumn Header="请求" Width="55" DisplayMemberBinding="{Binding Steps}"/>
                <GridViewColumn Header="输入" Width="75" DisplayMemberBinding="{Binding In}"/>
                <GridViewColumn Header="输出" Width="75" DisplayMemberBinding="{Binding Out}"/>
                <GridViewColumn Header="缓存命中" Width="90" DisplayMemberBinding="{Binding Cache}"/>
                <GridViewColumn Header="估算花费" Width="80" DisplayMemberBinding="{Binding Cost}"/>
              </GridView>
            </ListView.View>
          </ListView>
          <TextBlock x:Name="UStepLabel" Grid.Row="1" Text="该会话的请求明细" FontSize="11" Foreground="#FF6B7280" Margin="0,10,0,6"/>
          <ListView x:Name="USteps" Grid.Row="2" BorderBrush="#FFE5E7EB" BorderThickness="1">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="时间" Width="115" DisplayMemberBinding="{Binding Time}"/>
                <GridViewColumn Header="模型" Width="140" DisplayMemberBinding="{Binding Model}"/>
                <GridViewColumn Header="时段" Width="50" DisplayMemberBinding="{Binding Peak}"/>
                <GridViewColumn Header="输入" Width="75" DisplayMemberBinding="{Binding In}"/>
                <GridViewColumn Header="输出" Width="75" DisplayMemberBinding="{Binding Out}"/>
                <GridViewColumn Header="缓存命中" Width="90" DisplayMemberBinding="{Binding Cache}"/>
                <GridViewColumn Header="估算花费" Width="80" DisplayMemberBinding="{Binding Cost}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Grid>
      </TabItem>
      <TabItem Header="按天">
        <ListView x:Name="UDaily" Margin="0,8,0,0" BorderBrush="#FFE5E7EB" BorderThickness="1">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="日期" Width="110" DisplayMemberBinding="{Binding Date}"/>
              <GridViewColumn Header="请求" Width="65" DisplayMemberBinding="{Binding Steps}"/>
              <GridViewColumn Header="其中高峰" Width="80" DisplayMemberBinding="{Binding Peak}"/>
              <GridViewColumn Header="输入" Width="95" DisplayMemberBinding="{Binding In}"/>
              <GridViewColumn Header="输出" Width="95" DisplayMemberBinding="{Binding Out}"/>
              <GridViewColumn Header="缓存命中" Width="115" DisplayMemberBinding="{Binding Cache}"/>
              <GridViewColumn Header="tokens 合计" Width="115" DisplayMemberBinding="{Binding Tokens}"/>
              <GridViewColumn Header="估算花费" Width="85" DisplayMemberBinding="{Binding Cost}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </TabItem>
      <TabItem Header="按模型">
        <ListView x:Name="UModels" Margin="0,8,0,0" BorderBrush="#FFE5E7EB" BorderThickness="1">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="模型" Width="190" DisplayMemberBinding="{Binding Model}"/>
              <GridViewColumn Header="请求" Width="70" DisplayMemberBinding="{Binding Steps}"/>
              <GridViewColumn Header="输入" Width="100" DisplayMemberBinding="{Binding In}"/>
              <GridViewColumn Header="输出" Width="100" DisplayMemberBinding="{Binding Out}"/>
              <GridViewColumn Header="缓存命中" Width="120" DisplayMemberBinding="{Binding Cache}"/>
              <GridViewColumn Header="tokens 合计" Width="120" DisplayMemberBinding="{Binding Tokens}"/>
              <GridViewColumn Header="估算花费" Width="90" DisplayMemberBinding="{Binding Cost}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </TabItem>
      <TabItem Header="按工作区">
        <ListView x:Name="UWorkspaces" Margin="0,8,0,0" BorderBrush="#FFE5E7EB" BorderThickness="1">
          <ListView.View>
            <GridView>
              <GridViewColumn Header="工作区（会话 cwd）" Width="520" DisplayMemberBinding="{Binding Workdir}"/>
              <GridViewColumn Header="会话" Width="60" DisplayMemberBinding="{Binding Sessions}"/>
              <GridViewColumn Header="请求" Width="60" DisplayMemberBinding="{Binding Steps}"/>
              <GridViewColumn Header="tokens" Width="110" DisplayMemberBinding="{Binding Tokens}"/>
              <GridViewColumn Header="估算花费" Width="85" DisplayMemberBinding="{Binding Cost}"/>
              <GridViewColumn Header="最近" Width="95" DisplayMemberBinding="{Binding Last}"/>
            </GridView>
          </ListView.View>
        </ListView>
      </TabItem>
    </TabControl>
    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,12,0,0" HorizontalAlignment="Right">
      <Button x:Name="URefresh" Content="重新扫描" Width="92" Height="30" Margin="0,0,8,0"/>
      <Button x:Name="UExport" Content="导出 CSV" Width="92" Height="30" Margin="0,0,8,0"/>
      <Button x:Name="UClose" Content="关闭" Width="92" Height="30"/>
    </StackPanel>
  </Grid>
</Window>
"@

    $uw = [Windows.Markup.XamlReader]::Parse($ux)
    $script:usageWin = $uw
    $script:uHead = $uw.FindName('UHead'); $script:uSub = $uw.FindName('USub')
    $script:uSessions = $uw.FindName('USessions'); $script:uSteps = $uw.FindName('USteps')
    $script:uStepLabel = $uw.FindName('UStepLabel')
    $script:uFilter = $uw.FindName('UFilter'); $script:uFilterInfo = $uw.FindName('UFilterInfo')
    $script:uDaily = $uw.FindName('UDaily'); $script:uModels = $uw.FindName('UModels')
    $script:uWs = $uw.FindName('UWorkspaces')
    $script:uData = $data

    if ($script:uFilter) { $script:uFilter.Add_TextChanged({ try { Fill-UsageSessions } catch { } }) }

    $script:uSessions.Add_SelectionChanged({
        try {
            $script:uSteps.Items.Clear()
            $sel = $script:uSessions.SelectedItem
            if (-not $sel) { return }
            $full = @($script:uData.sessions | Where-Object { $_.id -eq $sel.Id })[0]
            if (-not $full -or -not $full.stepList) { $script:uStepLabel.Text = '该会话没有请求明细'; return }
            $script:uStepLabel.Text = ("该会话的请求明细（{0} 次）" -f @($full.stepList).Count)
            foreach ($st in @($full.stepList)) {
                $script:uSteps.Items.Add([PSCustomObject]@{
                    Time  = (Format-Time $st.t)
                    Model = [string]$st.model
                    Peak  = $(if ($st.peak) { '高峰' } else { '空闲' })
                    In    = (Format-Num $st.in)
                    Out   = (Format-Num $st.out)
                    Cache = (Format-Num $st.cacheRead)
                    Cost  = (Format-Money $st.cost)
                }) | Out-Null
            }
        } catch { }
    })

    $uw.FindName('UExport').Add_Click({
        try {
            if (-not $script:uData) { return }
            $rows = @()
            foreach ($s in @($script:uData.sessions | Where-Object { $_.steps -gt 0 })) {
                $name = if ($s.firstUser) { $s.firstUser } elseif ($s.title) { $s.title } else { '(未命名会话)' }
                $rows += [PSCustomObject]@{
                    会话 = $s.id; 最近活动 = (Format-Time $s.lastTime); 任务 = $name; 请求数 = $s.steps
                    输入tokens = $s.inputTokens; 输出tokens = $s.outputTokens; 缓存命中tokens = $s.cacheReadTokens
                    估算花费元 = $s.cost
                }
            }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
            $out = Join-Path $cfgDir ("dsh-usage-$stamp.csv")
            if ($rows.Count -eq 0) { [System.Windows.MessageBox]::Show('没有可导出的会话', 'dsh 用量明细') | Out-Null; return }
            $rows | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
            [System.Windows.MessageBox]::Show("已导出：`n$out", 'dsh 用量明细') | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show("导出失败: $($_.Exception.Message)", 'dsh 用量明细') | Out-Null
        }
    })
    $uw.FindName('UClose').Add_Click({ $uw.Close() })
    $uw.Add_Closed({ $script:usageWin = $null })

    # 先挂好事件，再填数据 —— 这样 Fill 里自动选中首行会触发明细填充
    Fill-UsageSessions

    if ($loadErr) {
        $script:uHead.Text = '读不到 dsh 会话数据'
        $script:uSub.Text = $loadErr + "`n`n" +
        "排查顺序：`n" +
        "1) 点「重新扫描」再试一次；`n" +
        "2) 看 %LOCALAPPDATA%\BalanceWidget\widget.log 里搜索 node/扫描 相关的行；`n" +
        "3) 在 config.json 里加一行 `"nodePath`": `"C:\\路径\\node.exe`" 指向任意 Node 22+（dsh 自带的那个也行）；`n" +
        "4) 确认 ~/.dsh/sessions 里存在 session-*/session.v4.jsonl.zstd。"
        $script:uFilter.IsEnabled = $false
    }

    # 重新扫描成功后把头部恢复成正常文案
    $uw.FindName('URefresh').Add_Click({
        try {
            $script:uData = Get-UsageData $true
            if ($script:uData -and $script:uData.sum) {
                $script:uFilter.IsEnabled = $true
                Fill-UsageSessions
            } else {
                $script:uSub.Text = $(if ($script:usageError) { $script:usageError } else { '仍然读不到数据' })
            }
        } catch { }
    })

    [void]$uw.ShowDialog()
}

# ---------- 主窗口 ----------
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BalanceWidget" Width="250" Height="112"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False">
  <Border x:Name="Card" CornerRadius="14" Background="#F01C1D22" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="14,10">
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="26"/><RowDefinition Height="16"/></Grid.RowDefinitions>
      <Grid.ColumnDefinitions><ColumnDefinition Width="62"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <TextBlock Grid.Row="0" Text="WB 算力" Foreground="#A0C8C8D2" FontSize="11" VerticalAlignment="Center"/>
      <TextBlock x:Name="WbVal"  Grid.Row="0" Grid.Column="1" Text="..." FontFamily="Consolas" FontSize="17" FontWeight="Bold" VerticalAlignment="Center"/>
      <Border x:Name="DsRow" Grid.Row="1" Grid.ColumnSpan="2" Background="Transparent" Cursor="Hand"
              ToolTip="单击这里查看每个会话/请求的 token 明细（整窗都可以拖动）">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="62"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Text="dsh 余额" Foreground="#A0C8C8D2" FontSize="11" VerticalAlignment="Center"/>
          <TextBlock x:Name="DsVal" Grid.Column="1" Text="..." FontFamily="Consolas" FontSize="17" FontWeight="Bold" VerticalAlignment="Center"/>
          <TextBlock Grid.Column="2" Text="明细›" Foreground="#7A9AA8B8" FontSize="9" VerticalAlignment="Center" Margin="6,0,0,0"/>
        </Grid>
      </Border>
      <TextBlock x:Name="Status" Grid.Row="2" Grid.ColumnSpan="2" Text="初始化…" FontSize="9" Foreground="#78A0A0AA" VerticalAlignment="Bottom"/>
    </Grid>
  </Border>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Parse($xaml)
$wbVal = $win.FindName('WbVal'); $dsVal = $win.FindName('DsVal'); $status = $win.FindName('Status')
$dsRow = $win.FindName('DsRow')

# 打开明细窗口（防抖 + 延迟一帧）
# 直接在 MouseLeftButtonDown 里 ShowDialog 会被吞：那一刻 DragMove 还握着鼠标捕获，
# 模态窗口要么不显示要么立刻被关闭，异常又被外层 catch 吃掉。改用 Dispatcher 回调。
$script:lastUsageOpen = [DateTime]::MinValue
function Open-UsageOnce {
    $now = Get-Date
    if (($now - $script:lastUsageOpen).TotalMilliseconds -lt 800) { return }
    $script:lastUsageOpen = $now
    Write-Log "请求打开用量明细"
    try {
        $win.Dispatcher.BeginInvoke([Action]{
                try { Show-UsageWindow }
                catch { Write-Log ("明细窗口异常: " + $_.Exception.Message) }
            }) | Out-Null
    } catch {
        Write-Log ("调度明细窗口失败: " + $_.Exception.Message)
    }
}

# 记住位置
if (Test-Path $posPath) {
    try {
        $p = (Get-Content $posPath -Raw).Split(',')
        $win.WindowStartupLocation = 'Manual'
        $win.Left = [double]$p[0]; $win.Top = [double]$p[1]
    } catch { }
} else {
    $win.WindowStartupLocation = 'Manual'
    # 默认贴右上角（留 24px 边距）
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $win.Left = $wa.Right - 250 - 24; $win.Top = $wa.Top + 24
}

# ----- 贴边吸附 + 自动隐藏 / 悬停展开 -----
$script:dockSide = ''            # '' | left | right | top | bottom
$script:hiddenState = $false
$script:dragging = $false
$script:dockWa = $null
$script:shownLeft = $win.Left
$script:shownTop = $win.Top
$script:slideTargetL = $null
$script:slideTargetT = $null

function Save-Pos([double]$l, [double]$t) {
    try { "$l,$t" | Set-Content -Path $posPath -Encoding ASCII } catch { }
}

# 平滑滑动（12ms 一帧，缓动），不用 WPF 动画是因为要跟 WinForms 光标判定配合
$script:slideTimer = New-Object Windows.Threading.DispatcherTimer
$script:slideTimer.Interval = [TimeSpan]::FromMilliseconds(12)
$script:slideTimer.Add_Tick({
    try {
        if ($null -eq $script:slideTargetL -and $null -eq $script:slideTargetT) { $script:slideTimer.Stop(); return }
        $done = $true
        if ($null -ne $script:slideTargetL) {
            $d = [double]$script:slideTargetL - $win.Left
            if ([Math]::Abs($d) -lt 1.5) { $win.Left = [double]$script:slideTargetL }
            else { $win.Left = $win.Left + [Math]::Max(-46, [Math]::Min(46, $d / 2.4)); $done = $false }
        }
        if ($null -ne $script:slideTargetT) {
            $d = [double]$script:slideTargetT - $win.Top
            if ([Math]::Abs($d) -lt 1.5) { $win.Top = [double]$script:slideTargetT }
            else { $win.Top = $win.Top + [Math]::Max(-46, [Math]::Min(46, $d / 2.4)); $done = $false }
        }
        if ($done) {
            $script:slideTargetL = $null; $script:slideTargetT = $null
            $script:slideTimer.Stop()
        }
    } catch { $script:slideTimer.Stop() }
})

function Slide-To($l, $t) {
    $script:slideTargetL = $l
    $script:slideTargetT = $t
    if (-not $script:slideTimer.IsEnabled) { $script:slideTimer.Start() }
}

function Show-FromEdge([bool]$instant) {
    if ($script:dockSide -eq '' -or -not $script:dockWa) { return }
    $wa = $script:dockWa
    $L = $null; $T = $null
    switch ($script:dockSide) {
        'right'  { $L = $wa.Right - $win.Width }
        'left'   { $L = $wa.Left }
        'top'    { $T = $wa.Top }
        'bottom' { $T = $wa.Bottom - $win.Height }
    }
    $script:hiddenState = $false
    $script:shownLeft = if ($null -ne $L) { [double]$L } else { $win.Left }
    $script:shownTop = if ($null -ne $T) { [double]$T } else { $win.Top }
    if ($instant) {
        $script:slideTimer.Stop(); $script:slideTargetL = $null; $script:slideTargetT = $null
        if ($null -ne $L) { $win.Left = [double]$L }
        if ($null -ne $T) { $win.Top = [double]$T }
    } else {
        Slide-To $L $T
    }
    Write-Log "展开 (侧=$($script:dockSide))"
}

function Hide-ToEdge {
    if ($script:dockSide -eq '' -or -not $script:dockWa -or $script:hiddenState) { return }
    $wa = $script:dockWa
    $script:shownLeft = $win.Left
    $script:shownTop = $win.Top
    $L = $null; $T = $null
    switch ($script:dockSide) {
        'right'  { $L = $wa.Right - $hangPx }
        'left'   { $L = $wa.Left - ($win.Width - $hangPx) }
        'top'    { $T = $wa.Top - ($win.Height - $hangPx) }
        'bottom' { $T = $wa.Bottom - $hangPx }
    }
    $script:hiddenState = $true
    Slide-To $L $T
    Write-Log "贴边隐藏 (侧=$($script:dockSide) 留边=$hangPx px)"
}

# 隐藏后如果鼠标其实还停在窄边上，就自动展开，避免「卡在隐藏态」
$script:verifyTimer = New-Object Windows.Threading.DispatcherTimer
$script:verifyTimer.Interval = [TimeSpan]::FromMilliseconds(280)
$script:verifyTimer.Add_Tick({
    $script:verifyTimer.Stop()
    try {
        if ($script:hiddenState -and $win.IsMouseOver) { Show-FromEdge $false }
    } catch { }
})

$script:hideTimer = New-Object Windows.Threading.DispatcherTimer
$script:hideTimer.Interval = [TimeSpan]::FromMilliseconds($hideDelayMs)
$script:hideTimer.Add_Tick({
    $script:hideTimer.Stop()
    try {
        if ($script:dragging -or -not $autoHide) { return }
        if ($script:dockSide -eq '' -or $script:hiddenState) { return }
        Hide-ToEdge
        $script:verifyTimer.Start()
    } catch { }
})

function Snap-ToEdges {
    try {
        if ($snapPx -le 0) { $script:dockSide = ''; return }
        $cx = [int]($win.Left + $win.Width / 2)
        $cy = [int]($win.Top + $win.Height / 2)
        $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx, $cy))).WorkingArea
        $l = $win.Left; $t = $win.Top
        $r = $win.Left + $win.Width; $b = $win.Top + $win.Height
        $side = ''
        # 左右优先（竖条型的隐藏边更好用）
        if ([Math]::Abs($l - $wa.Left) -le $snapPx) { $l = $wa.Left; $side = 'left' }
        elseif ([Math]::Abs($r - $wa.Right) -le $snapPx) { $l = $wa.Right - $win.Width; $side = 'right' }
        if ([Math]::Abs($t - $wa.Top) -le $snapPx) { $t = $wa.Top; if ($side -eq '') { $side = 'top' } }
        elseif ([Math]::Abs($b - $wa.Bottom) -le $snapPx) { $t = $wa.Bottom - $win.Height; if ($side -eq '') { $side = 'bottom' } }
        if ([Math]::Abs($l - $win.Left) -ge 0.5) { $win.Left = $l }
        if ([Math]::Abs($t - $win.Top) -ge 0.5) { $win.Top = $t }
        $script:dockSide = $side
        $script:dockWa = $wa
        $script:shownLeft = $win.Left; $script:shownTop = $win.Top
        Save-Pos $win.Left $win.Top
        Write-Log "吸附结果: 侧='$side' 位置=$([int]$win.Left),$([int]$win.Top)"
    } catch { Write-Log ("吸附失败: " + $_.Exception.Message) }
}

$script:topmost = $true
$script:downX = 0; $script:downY = 0

$win.Add_MouseEnter({
    try {
        $script:hideTimer.Stop()
        if ($script:hiddenState) { Show-FromEdge $false }
    } catch { }
})

$win.Add_MouseLeave({
    try {
        if ($autoHide -and $script:dockSide -ne '' -and -not $script:hiddenState -and -not $script:dragging) {
            $script:hideTimer.Stop()
            $script:hideTimer.Start()
        }
    } catch { }
})

$win.Add_MouseLeftButtonDown({
    try {
        $script:downX = [System.Windows.Forms.Cursor]::Position.X
        $script:downY = [System.Windows.Forms.Cursor]::Position.Y
        $script:hideTimer.Stop(); $script:verifyTimer.Stop()
        $script:dragging = $true
        # 按下瞬间就要判断「是不是落在 dsh 行上」——拖动后窗口会移动，松手时的坐标不可靠
        $script:downOnRow = $false
        try {
            $rp = [System.Windows.Input.Mouse]::GetPosition($dsRow)
            if ($rp.X -ge 0 -and $rp.Y -ge 0 -and $rp.X -le $dsRow.ActualWidth -and $rp.Y -le $dsRow.ActualHeight) {
                $script:downOnRow = $true
            }
            Write-Log ("按下 p=$([int]$rp.X),$([int]$rp.Y) row=$([int]$dsRow.ActualWidth)x$([int]$dsRow.ActualHeight) onRow=$($script:downOnRow)")
        } catch { Write-Log ("按下判定异常: " + $_.Exception.Message) }
        # 隐藏状态下抓住窄边拖动：先整体拉出来，再跟手拖
        if ($script:hiddenState) { Show-FromEdge $true }
        $win.DragMove()
    } catch { Write-Log ("拖动异常: " + $_.Exception.Message) }
    $script:dragging = $false
    Snap-ToEdges
    try {
        $dx = [Math]::Abs([System.Windows.Forms.Cursor]::Position.X - $script:downX)
        $dy = [Math]::Abs([System.Windows.Forms.Cursor]::Position.Y - $script:downY)
        if ($dx -lt 4 -and $dy -lt 4 -and $script:downOnRow) {
            # 位移极小 + 按在 dsh 行上 → 当作单击，打开用量明细
            Write-Log "单击命中 dsh 行，打开明细"
            Open-UsageOnce
            return
        }
    } catch { Write-Log ("单击处理异常: " + $_.Exception.Message) }
    # 拖完停在边缘 → 等鼠标离开就自动缩边
    if ($autoHide -and $script:dockSide -ne '') {
        $script:hideTimer.Stop()
        $script:hideTimer.Start()
    }
})
$win.Add_MouseDoubleClick({ Update-All })

function Set-DsTotal {
    $cur = 0
    if ($null -ne $cfg.deepseekTotal) { $cur = [double]$cfg.deepseekTotal }
    $hint = "请输入 dsh 的累计总额（元，含赠送）。`n例：赠送 6 元 + 充值 10 元 = 16`n`n填 0 = 自动推算（余额 + 本地估算消耗）"
    $r = $null
    try { $r = [Microsoft.VisualBasic.Interaction]::InputBox($hint, 'dsh 总额设置', "$cur") } catch { }
    if ($null -eq $r -or $r.Trim() -eq '') { return }
    $v = 0.0
    if (-not [double]::TryParse($r.Trim(), [ref]$v) -or $v -lt 0) {
        [System.Windows.MessageBox]::Show('请输入一个不小于 0 的数字', 'dsh 总额设置') | Out-Null
        return
    }
    $script:cfg | Add-Member -NotePropertyName deepseekTotal -NotePropertyValue $v -Force
    Save-Config
    Write-Log "dsh 总额设置为 $v"
    Update-All
}

function Set-DailyBudget {
    $cur = 0
    if ($null -ne $cfg.dailyBudget) { $cur = [double]$cfg.dailyBudget }
    $hint = "今日花费超过这个数时，悬浮窗底部会变成橙色提醒。`n填 0 = 不提醒"
    $r = $null
    try { $r = [Microsoft.VisualBasic.Interaction]::InputBox($hint, '今日预算（元）', "$cur") } catch { }
    if ($null -eq $r -or $r.Trim() -eq '') { return }
    $v = 0.0
    if (-not [double]::TryParse($r.Trim(), [ref]$v) -or $v -lt 0) {
        [System.Windows.MessageBox]::Show('请输入一个不小于 0 的数字', '今日预算') | Out-Null
        return
    }
    $script:cfg | Add-Member -NotePropertyName dailyBudget -NotePropertyValue $v -Force
    Save-Config
    $script:dailyBudget = $v
    Write-Log "今日预算设置为 $v"
    Update-All
}

$win.Add_MouseRightButtonUp({
    $menu = New-Object Windows.Controls.ContextMenu
    $i1 = New-Object Windows.Controls.MenuItem; $i1.Header = '刷新余额'
    $i1.Add_Click({ Update-All }); [void]$menu.Items.Add($i1)
    $i2 = New-Object Windows.Controls.MenuItem; $i2.Header = 'dsh 用量明细…'
    $i2.Add_Click({ Open-UsageOnce }); [void]$menu.Items.Add($i2)
    $i3 = New-Object Windows.Controls.MenuItem; $i3.Header = '设置 dsh 总额（赠送+充值）…'
    $i3.Add_Click({ Set-DsTotal }); [void]$menu.Items.Add($i3)
    $i9 = New-Object Windows.Controls.MenuItem; $i9.Header = '设置今日预算（超了变橙）…'
    $i9.Add_Click({ Set-DailyBudget }); [void]$menu.Items.Add($i9)
    $i4 = New-Object Windows.Controls.MenuItem; $i4.Header = '窗口置顶'; $i4.IsCheckable = $true; $i4.IsChecked = $script:topmost
    $i4.Add_Click({ $script:topmost = -not $script:topmost; $win.Topmost = $script:topmost }); [void]$menu.Items.Add($i4)
    $i5 = New-Object Windows.Controls.MenuItem; $i5.Header = '停用跟随 dsh 启动（下次不再自动出现，/widget 仍可打开）'
    $i5.Add_Click({
        $script:cfg | Add-Member -NotePropertyName enabled -NotePropertyValue $false -Force
        Save-Config
        [System.Windows.MessageBox]::Show('已停用跟随启动。需要时在 dsh 里输入 /widget 手动打开。', '余额悬浮窗') | Out-Null
    }); [void]$menu.Items.Add($i5)
    $i8 = New-Object Windows.Controls.MenuItem; $i8.Header = '贴边自动隐藏（鼠标移开缩边）'; $i8.IsCheckable = $true; $i8.IsChecked = $script:autoHide
    $i8.Add_Click({
        $script:autoHide = -not $script:autoHide
        $script:cfg | Add-Member -NotePropertyName autoHide -NotePropertyValue $script:autoHide -Force
        Save-Config
        $i8.IsChecked = $script:autoHide
        if (-not $script:autoHide -and $script:hiddenState) { Show-FromEdge $true }
        Write-Log "贴边自动隐藏 = $script:autoHide"
    }); [void]$menu.Items.Add($i8)
    $i6 = New-Object Windows.Controls.MenuItem; $i6.Header = '打开配置文件'
    $i6.Add_Click({ Start-Process notepad.exe $cfgPath }); [void]$menu.Items.Add($i6)
    $i7 = New-Object Windows.Controls.MenuItem; $i7.Header = '退出'
    $i7.Add_Click({ $win.Close() }); [void]$menu.Items.Add($i7)
    $win.ContextMenu = $menu
    $win.ContextMenu.IsOpen = $true
})

$script:lastStatus = ''
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

        # 今日花费（读缓存/本地日志；拿不到就不显示）
        $todayCostVal = $null
        $over = $false
        try {
            $u = Get-UsageData $false
            if ($u -and $u.sum -and $null -ne $u.sum.todayCost) {
                $todayCostVal = [double]$u.sum.todayCost
                if ($dailyBudget -gt 0 -and $todayCostVal -gt $dailyBudget) { $over = $true }
                $dsVal.ToolTip = [string]$ds.tip + "`n今日已花 ¥{0:0.00}（{1} 次请求）" -f $todayCostVal, $u.sum.todaySteps
            }
        } catch { }

        $hm = Get-Date -Format 'HH:mm'
        if ($null -ne $todayCostVal) {
            if ($over) { $script:lastStatus = "今日 ¥{0:0.00} 超预算" -f $todayCostVal }
            else { $script:lastStatus = "今日 ¥{0:0.00} · {1}" -f $todayCostVal, $hm }
        } else {
            $script:lastStatus = "更新 $hm　单击 dsh 看明细"
        }
        $status.Text = $script:lastStatus
        if ($over) { $status.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb([byte]0xFF,[byte]0x96,[byte]0x3C)) }
        else { $status.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb([byte]0x78,[byte]0xA0,[byte]0xA0,[byte]0xAA)) }
    } catch {
        Write-Log ("刷新异常: " + $_.Exception.Message)
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes($refreshMin)
$timer.Add_Tick({ Update-All })
$timer.Start()

$win.Add_Loaded({
    Write-Log "窗口已加载, 开始首次刷新"
    # 启动时如果本来就贴着边，直接认下来，这样鼠标一离开就会缩边
    try {
        $wa = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point([int]($win.Left + $win.Width / 2), [int]($win.Top + $win.Height / 2)))).WorkingArea
        $script:dockWa = $wa
        $side = ''
        if ([Math]::Abs($win.Left - $wa.Left) -le 2) { $side = 'left' }
        elseif ([Math]::Abs(($win.Left + $win.Width) - $wa.Right) -le 2) { $side = 'right' }
        if ([Math]::Abs($win.Top - $wa.Top) -le 2) { if ($side -eq '') { $side = 'top' } }
        elseif ([Math]::Abs(($win.Top + $win.Height) - $wa.Bottom) -le 2) { if ($side -eq '') { $side = 'bottom' } }
        $script:dockSide = $side
        $script:shownLeft = $win.Left; $script:shownTop = $win.Top
        Write-Log "启动时吸附侧='$side'"
        if ($side -ne '' -and $autoHide) { $script:hideTimer.Stop(); $script:hideTimer.Start() }
    } catch { }
    # 先让窗口画出来，再跑可能耗时的刷新（网络 + 本地日志扫描）
    $win.Dispatcher.BeginInvoke([Action]{
            Update-All
            if ($env:BW_OPEN_USAGE -eq '1') { Show-UsageWindow }
        }) | Out-Null
})
$win.Add_Closed({
    Write-Log "窗口关闭, 保存位置"
    # 隐藏态下保存的是「展开后」的位置，下次开机不会藏在屏幕外
    if ($script:hiddenState) { Save-Pos $script:shownLeft $script:shownTop }
    else { Save-Pos $win.Left $win.Top }
})

Write-Log "进入 ShowDialog"
[void]$win.ShowDialog()
Write-Log "ShowDialog 结束, 进程退出"
