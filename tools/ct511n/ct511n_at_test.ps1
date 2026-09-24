#Requires -Version 5.1
<#
.SYNOPSIS
    DX-CT511 / DX-CT511N 4G Cat.1 模块 AT 测试任务执行器（零第三方依赖）。

.DESCRIPTION
    把 doc/DX-CT511N_测试任务编排.md 里的分阶段测试任务变成可重复执行的脚本。
    只依赖 Windows 自带的 System.IO.Ports.SerialPort，不需要 pyserial。

    默认只跑无副作用阶段（link/info/sim）。net/ppp/tcp/gnss 会改变模块状态
    （开数据网络、拨号、开 GNSS、建 TCP 连接），必须显式加 -AllowStateChange。

.PARAMETER Stage
    link  : 串口链路、回显、波特率
    info  : 模块身份、固件版本、IMEI、时钟
    sim   : SIM 卡、注网、信号、小区信息
    net   : 内置协议栈联网（NETOPEN / DNS / PING / NTP）
    ppp   : PPP 拨号能力探测（AT+CGDCONT? / ATD*99#）—— 关键未知项
    tcp   : 内置 TCP 透传（CIPOPEN / CIPSEND / ATO）
    aprs  : 直连 APRS-IS 服务器（只收问候语验证端到端连通，不发送登录）
    gnss  : GNSS 开关、定位查询、有源天线供电
    pwr   : 休眠与功耗相关状态查询（只读）

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -ListOnly
    powershell -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage link,info,sim
    powershell -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage net,ppp -AllowStateChange
#>
[CmdletBinding()]
param(
    [string] $Port = 'COM6',
    [int]    $Baud = 115200,

    # 允许 "link,info,sim" 这种写法（powershell -File 传参时不会自动拆数组）
    [string[]] $Stage = @('link', 'info', 'sim'),

    [string] $LogDir = '',
    [int]    $QuietMs = 400,
    [int]    $GpsFixWaitSec = 45,

    [string] $Apn = '',
    [string] $NtpServer = 'ntp.aliyun.com',
    [string] $TcpHost = 'www.baidu.com',
    [int]    $TcpPort = 80,
    # 注意：旧资料里的 aprs.dprns.com 已无法公网解析，改用区域轮转服务器
    [string] $AprsHost = 'china.aprs2.net',
    [int]    $AprsPort = 14580,
    [string] $AprsCallsign = '',
    [int]    $AprsPasscode = -1,
    [string] $AprsFilter = 'r/31.23/121.47/50',

    [switch] $AllowStateChange,
    [switch] $ActiveAntenna,
    [switch] $Transparent,
    [switch] $ListOnly,
    [switch] $Raw
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ValidStages = @('link', 'info', 'sim', 'net', 'ppp', 'tcp', 'aprs', 'gnss', 'pwr', 'all')
$Stage = @($Stage | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ })
$badStages = @($Stage | Where-Object { $script:ValidStages -notcontains $_ })
if ($badStages.Count -gt 0) {
    Write-Host ("未知阶段: " + ($badStages -join ', ') + "；可用: " + ($script:ValidStages -join ', ')) -ForegroundColor Red
    exit 2
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $PSScriptRoot '..\..\tmp\ct511n_logs'
}

$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:Notes   = New-Object 'System.Collections.Generic.List[string]'
$script:Log     = New-Object 'System.Text.StringBuilder'

function Write-Log {
    param([string] $Text)
    [void]$script:Log.AppendLine($Text)
}

function Write-Head {
    param([string] $Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
    Write-Log "=== $Text ==="
}

function Add-Note {
    param([string] $Text)
    [void]$script:Notes.Add($Text)
}

function Add-Result {
    param(
        [string] $Id,
        [string] $Group,
        [string] $Title,
        [string] $Cmd,
        [string] $Response,
        [ValidateSet('PASS', 'FAIL', 'INFO', 'WARN', 'SKIP')]
        [string] $Status,
        [string] $Note = ''
    )
    $r = [pscustomobject]@{
        Id       = $Id
        Stage    = $Group
        Title    = $Title
        Command  = $Cmd
        Status   = $Status
        Note     = $Note
        Response = $Response
    }
    [void]$script:Results.Add($r)

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        'SKIP' { 'DarkGray' }
        default { 'Gray' }
    }
    $flat = ($Response -replace "`r`n", ' | ' -replace "`n", ' | ').Trim()
    if ($flat.Length -gt 160 -and -not $Raw) { $flat = $flat.Substring(0, 160) + '...' }
    Write-Host ("[{0}] {1,-4} {2}" -f $Status, $Id, $Title) -ForegroundColor $color
    if ($Cmd -and -not $Raw) { Write-Host ("        > {0}" -f $Cmd) -ForegroundColor DarkGray }
    if ($flat) { Write-Host ("        < {0}" -f $flat) -ForegroundColor DarkGray }
    if ($Note) { Write-Host ("        ! {0}" -f $Note) -ForegroundColor DarkYellow }

    Write-Log ("[{0}] {1} {2} :: {3}" -f $Status, $Id, $Title, $Cmd)
    Write-Log ("        raw: " + ($Response -replace "`r`n", '\r\n' -replace "`n", '\n' -replace "`r", '\r'))
    if ($Note) { Write-Log ("        note: " + $Note) }
    return $r
}

function Open-CtPort {
    param([string] $Name, [int] $Rate)
    $sp = New-Object System.IO.Ports.SerialPort $Name, $Rate, 'None', 8, 'One'
    $sp.Encoding     = [System.Text.Encoding]::ASCII
    $sp.NewLine      = "`r`n"
    $sp.ReadTimeout  = 2000
    $sp.WriteTimeout = 2000
    $sp.DtrEnable    = $true
    $sp.RtsEnable    = $true
    $sp.Open()
    Start-Sleep -Milliseconds 250
    $sp.DiscardInBuffer()
    $sp.DiscardOutBuffer()
    return $sp
}

function Read-UntilQuiet {
    param(
        [System.IO.Ports.SerialPort] $Sp,
        [int] $Quiet = 400,
        [int] $MaxMs = 4000,
        [string] $StopOn = ''
    )
    $sb = New-Object System.Text.StringBuilder
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = $sw.ElapsedMilliseconds
    $matched = $false
    # 指定 StopOn 表示“等模块给出终止符”，在命中前不能因为静默就退出
    # （DNS/建连/NTP 这类命令的应答可能比回声晚很多），命中后再用 500ms 收尾
    $quietEffective = if ($StopOn) { [int]::MaxValue } else { $Quiet }
    while ($sw.ElapsedMilliseconds -lt $MaxMs) {
        if ($Sp.BytesToRead -gt 0) {
            [void]$sb.Append($Sp.ReadExisting())
            $last = $sw.ElapsedMilliseconds
            if ($StopOn -and -not $matched -and ($sb.ToString() -match $StopOn)) {
                # 命中终止符后只再收 500ms 尾巴，兼顾 OK 之后紧跟的 +XXX 结果行
                $matched = $true
                $quietEffective = 500
            }
        }
        elseif (($sw.ElapsedMilliseconds - $last) -gt $quietEffective) {
            break
        }
        else {
            Start-Sleep -Milliseconds 20
        }
    }
    return $sb.ToString()
}

function Send-At {
    param(
        [System.IO.Ports.SerialPort] $Sp,
        [string] $Cmd,
        [int] $Quiet = $QuietMs,
        [int] $MaxMs = 4000,
        [string] $StopOn = '(?m)^(OK|ERROR|\+CME ERROR|\+CMS ERROR)\s*$'
    )
    if ($Cmd) { $Sp.WriteLine($Cmd) }
    return (Read-UntilQuiet -Sp $Sp -Quiet $Quiet -MaxMs $MaxMs -StopOn $StopOn)
}

function Wait-Idle {
    <# 排空模块仍在异步吐出的响应（如 MPING 多次结果、NETCLOSE 延迟回包） #>
    param(
        [System.IO.Ports.SerialPort] $Sp,
        [int] $MaxMs = 10000,
        [int] $Quiet = 2000
    )
    $t = Read-UntilQuiet -Sp $Sp -Quiet $Quiet -MaxMs $MaxMs
    if ($t) { [void]$script:Log.AppendLine('[drain] ' + ($t -replace "`r`n", '\r\n')) }
    return $t
}

function Read-Fixed {
    <# 固定时间窗读取：GNSS 芯片会 $HOSTSLEEP，静默判据会提前收工，这里按绝对时间收 #>
    param(
        [System.IO.Ports.SerialPort] $Sp,
        [int] $Ms = 5000
    )
    $sb = New-Object System.Text.StringBuilder
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        if ($Sp.BytesToRead -gt 0) { [void]$sb.Append($Sp.ReadExisting()) }
        else { Start-Sleep -Milliseconds 20 }
    }
    return $sb.ToString()
}

function Invoke-AtGuarded {
    <#
        把模块从透传/数据态强行拉回 AT 命令模式：
        先留 1.2s 保护间隔，发不带结束符的 +++，再留 1.2s，然后发命令。
        每个会改变状态的阶段开头都调一次，保证上一次中断的测试不会污染本轮。
    #>
    param(
        [System.IO.Ports.SerialPort] $Sp,
        [string] $Cmd = 'AT',
        [int] $MaxMs = 10000
    )
    Start-Sleep -Milliseconds 1200
    [void]$Sp.Write('+++')
    Start-Sleep -Milliseconds 1200
    [void](Read-UntilQuiet -Sp $Sp -Quiet 500 -MaxMs 2000)
    return (Send-At -Sp $Sp -Cmd $Cmd -MaxMs $MaxMs)
}

function Format-Resp {
    param([string] $Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "`r`n", "`n" -replace "`r", "`n").Trim()
}

# ---------------------------------------------------------------- 测试任务表
function Get-AtTests {
    return @(
        # ---- link：链路层 ----
        @{ Id = 'L1'; Stage = 'link'; Title = 'AT 基本应答'; Cmd = 'AT'; Expect = '(?m)^OK\s*$'; Timeout = 3000
           Note = '无 OK 说明波特率/接线/电平不匹配' }
        @{ Id = 'L3'; Stage = 'link'; Title = '查询串口波特率'; Cmd = 'AT+IPR?'; Expect = '(?m)^\+IPR'; Timeout = 3000
           Note = '应等于 115200' }

        # ---- info：模块身份 ----
        @{ Id = 'I1'; Stage = 'info'; Title = '模块型号标识（ATI）'; Cmd = 'ATI'; Expect = '\S'; Timeout = 3000 }
        @{ Id = 'I2'; Stage = 'info'; Title = '厂商型号 CGMM'; Cmd = 'AT+CGMM'; Expect = '\S'; Timeout = 3000; Optional = $true }
        @{ Id = 'I3'; Stage = 'info'; Title = '固件版本 CGMR'; Cmd = 'AT+CGMR'; Expect = '\S'; Timeout = 3000; Optional = $true }
        @{ Id = 'I4'; Stage = 'info'; Title = 'IMEI（CGSN）'; Cmd = 'AT+CGSN'; Expect = '(?m)^"?\d{15}"?\s*$'; Timeout = 4000 }
        @{ Id = 'I5'; Stage = 'info'; Title = '模块时钟 CCLK'; Cmd = 'AT+CCLK?'; Expect = '\S'; Timeout = 3000; Optional = $true }
        @{ Id = 'I6'; Stage = 'info'; Title = '功能开关 CFUN'; Cmd = 'AT+CFUN?'; Expect = '\S'; Timeout = 3000; Optional = $true }
        @{ Id = 'I7'; Stage = 'info'; Title = '电池/供电状态 CBC'; Cmd = 'AT+CBC?'; Expect = '(?m)^\+CBC'; Timeout = 3000; Optional = $true }

        # ---- sim：SIM / 注网 ----
        @{ Id = 'S1'; Stage = 'sim'; Title = 'SIM 卡状态 CPIN'; Cmd = 'AT+CPIN?'; Expect = '(?m)^\+CPIN:\s*READY'; Timeout = 4000
           Note = '非 READY 时后续注网/联网测试无意义' }
        @{ Id = 'S2'; Stage = 'sim'; Title = 'SIM 卡号 ICCID'; Cmd = 'AT+ICCID'; Expect = '(?m)^\+ICCID'; Timeout = 4000 }
        @{ Id = 'S3'; Stage = 'sim'; Title = '信号强度 CSQ'; Cmd = 'AT+CSQ'; Expect = '(?m)^\+CSQ:'; Timeout = 3000
           Note = 'rssi 99 = 无信号' }
        @{ Id = 'S4'; Stage = 'sim'; Title = '网络注册 CEREG'; Cmd = 'AT+CEREG?'; Expect = '(?m)^\+CEREG:'; Timeout = 4000
           Note = 'stat=1 已注册本地网，stat=5 已注册漫游' }
        @{ Id = 'S5'; Stage = 'sim'; Title = '运营商信息 COPS'; Cmd = 'AT+COPS?'; Expect = '(?m)^\+COPS:'; Timeout = 6000; Optional = $true }
        @{ Id = 'S6'; Stage = 'sim'; Title = '小区信息 CPSI（V2.3）'; Cmd = 'AT+CPSI?'; Expect = '(?m)^\+CPSI'; Timeout = 4000
           Note = '可复核频段/TAC/CellID/RSRP/SINR' }
        @{ Id = 'S7'; Stage = 'sim'; Title = '分组域附着 CGATT'; Cmd = 'AT+CGATT?'; Expect = '(?m)^\+CGATT:'; Timeout = 4000; Optional = $true }

        # ---- net：内置协议栈 ----
        @{ Id = 'N1'; Stage = 'net'; Title = 'APN 配置查询'; Cmd = 'AT+QICSGP=1'; Expect = '(?m)^\+QICSGP'; Timeout = 4000; Optional = $true }
        @{ Id = 'N2'; Stage = 'net'; Title = '开启数据网络 NETOPEN'; Cmd = 'AT+NETOPEN'; Expect = 'SUCCESS|0'; Timeout = 20000
           Note = '官方期望 +NETOPEN: SUCCESS / 0' }
        @{ Id = 'N3'; Stage = 'net'; Title = '数据网络状态 NETOPEN?'; Cmd = 'AT+NETOPEN?'; Expect = '(?m)^\+NETOPEN:\s*1'; Timeout = 5000
           Note = 'net_state=1 表示数据网络已打开；模块无“查询本机 IP”指令' }
        @{ Id = 'N4'; Stage = 'net'; Title = 'DNS 解析 MDNSGIP'; Cmd = 'AT+MDNSGIP=www.baidu.com'; Expect = '\d+\.\d+\.\d+\.\d+'; Timeout = 15000; Optional = $true }
        @{ Id = 'N5'; Stage = 'net'; Title = 'Ping 目标 MPING'; Cmd = 'AT+MPING=www.baidu.com,1,1,32,3'; Expect = '\+MPING'; Timeout = 15000
           Note = '显式限定 1 次 ping，否则默认 4 次会长时间占用串口' }
        @{ Id = 'N6'; Stage = 'net'; Title = 'NTP 授时 QNTP'; Cmd = "AT+QNTP=1,`"$NtpServer`",123,1"; Expect = '\+QNTP'; Timeout = 60000
           Note = '实测响应延迟约 30s，超时给足 60s' }
        @{ Id = 'N7'; Stage = 'net'; Title = 'NTP 后校时 CCLK'; Cmd = 'AT+CCLK?'; Expect = '(?m)^\+CCLK'; Timeout = 8000 }
        @{ Id = 'N8'; Stage = 'net'; Title = '关闭数据网络 NETCLOSE'; Cmd = 'AT+NETCLOSE'; Expect = 'SUCCESS|0'; Timeout = 30000 }

        # ---- pwr：功耗/休眠（只读查询）----
        @{ Id = 'W1'; Stage = 'pwr'; Title = '指令休眠设置 SYSSLEEP'; Cmd = 'AT+SYSSLEEP?'; Expect = '(?m)^\+SYSSLEEP'; Timeout = 4000; Optional = $true }
        @{ Id = 'W2'; Stage = 'pwr'; Title = 'DTR 休眠设置 CSCLK'; Cmd = 'AT+CSCLK?'; Expect = '(?m)^\+CSCLK'; Timeout = 4000; Optional = $true }
        @{ Id = 'W3'; Stage = 'pwr'; Title = 'GNSS 开关状态 MGPSC'; Cmd = 'AT+MGPSC?'; Expect = '(?m)^\+MGPSC'; Timeout = 4000; Optional = $true }
        @{ Id = 'W4'; Stage = 'pwr'; Title = '模块复位/开机时长（供功耗测试参考）'; Cmd = 'AT+CFUN?'; Expect = '(?m)^\+CFUN'; Timeout = 4000; Optional = $true }
    )
}

function Get-DisabledStageHint {
    param([string] $Name)
    switch ($Name) {
        'net'  { return 'net 阶段会开数据网络，需要 -AllowStateChange' }
        'ppp'  { return 'ppp 阶段会发 ATD*99# 拨号，需要 -AllowStateChange' }
        'tcp'  { return 'tcp 阶段会建立真实 TCP 连接，需要 -AllowStateChange' }
        'aprs' { return 'aprs 阶段会连接 APRS-IS 服务器，需要 -AllowStateChange' }
        'gnss' { return 'gnss 阶段会上电 GNSS/天线，需要 -AllowStateChange' }
        default { return '' }
    }
}

# ---------------------------------------------------------------- 特殊流程
function Invoke-EchoTest {
    param([System.IO.Ports.SerialPort] $Sp)
    $r1 = Send-At -Sp $Sp -Cmd 'ATE0'
    $r2 = Send-At -Sp $Sp -Cmd 'AT'
    $r3 = Send-At -Sp $Sp -Cmd 'ATE1'
    $raw = (Format-Resp $r1) + "`n--`n" + (Format-Resp $r2) + "`n--`n" + (Format-Resp $r3)
    $echoOffWorked = (($r2 -notmatch '(?m)^AT\s*$') -and ($r2 -match 'OK'))
    $echoBack = ($r3 -match '(?m)^OK')
    $status = if ($echoOffWorked -and $echoBack) { 'PASS' } else { 'WARN' }
    $note = if ($echoOffWorked) { 'ATE0/ATE1 回显控制有效' } else { 'ATE0 未生效或模块不回 OK' }
    Add-Result -Id 'L2' -Group 'link' -Title '回显控制 ATE0/ATE1' -Cmd 'ATE0 -> AT -> ATE1' `
        -Response $raw -Status $status -Note $note | Out-Null
}

function Invoke-PppProbe {
    param([System.IO.Ports.SerialPort] $Sp)

    $r = Send-At -Sp $Sp -Cmd 'AT+CGDCONT?' -MaxMs 5000
    if ($r -match '(?m)^\+CGDCONT') {
        Add-Result -Id 'P2' -Group 'ppp' -Title 'PDP 上下文 CGDCONT' -Cmd 'AT+CGDCONT?' -Response (Format-Resp $r) `
            -Status 'PASS' -Note '模块暴露了 PDP 上下文配置面' | Out-Null
    }
    elseif ($r -match 'ERROR') {
        Add-Result -Id 'P2' -Group 'ppp' -Title 'PDP 上下文 CGDCONT' -Cmd 'AT+CGDCONT?' -Response (Format-Resp $r) `
            -Status 'WARN' -Note '不支持 CGDCONT，官方固件大概只走内置协议栈' | Out-Null
    }
    else {
        Add-Result -Id 'P2' -Group 'ppp' -Title 'PDP 上下文 CGDCONT' -Cmd 'AT+CGDCONT?' -Response (Format-Resp $r) `
            -Status 'WARN' -Note '无响应/空响应' | Out-Null
    }

    $r = Send-At -Sp $Sp -Cmd 'AT+CGACT?' -MaxMs 5000
    Add-Result -Id 'P3' -Group 'ppp' -Title 'PDP 激活状态 CGACT' -Cmd 'AT+CGACT?' -Response (Format-Resp $r) `
        -Status $(if ($r -match '(?m)^\+CGACT') { 'PASS' } else { 'WARN' }) | Out-Null

    # 关键：ATD*99# 是否回 CONNECT
    Write-Host '        正在拨号 ATD*99#（最长等 12s）...' -ForegroundColor DarkGray
    $dial = Send-At -Sp $Sp -Cmd 'ATD*99#' -Quiet 1200 -MaxMs 12000
    $dialTxt = Format-Resp $dial
    $connected = ($dialTxt -match 'CONNECT')

    if ($connected) {
        Add-Result -Id 'P4' -Group 'ppp' -Title 'PPP 拨号 ATD*99#' -Cmd 'ATD*99#' -Response $dialTxt `
            -Status 'PASS' -Note '进入 CONNECT，模块支持 UART PPP，可用 esp_modem 路径' | Out-Null
        # 尽快退出数据态，回命令行
        Start-Sleep -Milliseconds 1200
        [void]$Sp.Write('+++')
        Start-Sleep -Milliseconds 1200
        $esc = Read-UntilQuiet -Sp $Sp -Quiet 500 -MaxMs 3000
        $ath = Send-At -Sp $Sp -Cmd 'ATH' -MaxMs 4000
        $back = Send-At -Sp $Sp -Cmd 'AT' -MaxMs 3000
        Add-Result -Id 'P4b' -Group 'ppp' -Title '退出 PPP 数据态并复位连接' -Cmd '+++ / ATH / AT' `
            -Response ((Format-Resp $esc) + "`n--`n" + (Format-Resp $ath) + "`n--`n" + (Format-Resp $back)) `
            -Status $(if ($back -match '(?m)^OK') { 'PASS' } else { 'WARN' }) -Note '需确认回到 AT 命令模式' | Out-Null
    }
    else {
        $status = if ($dialTxt -match 'ERROR|NO CARRIER|BUSY') { 'FAIL' } else { 'WARN' }
        Add-Result -Id 'P4' -Group 'ppp' -Title 'PPP 拨号 ATD*99#' -Cmd 'ATD*99#' -Response $dialTxt `
            -Status $status -Note '未见 CONNECT：官方固件未开放 UART PPP，4G 联网需走内置协议栈或换模块' | Out-Null
    }
}

function Invoke-TcpTest {
    param([System.IO.Ports.SerialPort] $Sp)

    # CIPMODE 必须在开启数据网络前设置
    $r = Send-At -Sp $Sp -Cmd 'AT+CIPMODE?' -MaxMs 4000
    Add-Result -Id 'T1' -Group 'tcp' -Title '查询传输模式 CIPMODE' -Cmd 'AT+CIPMODE?' -Response (Format-Resp $r) `
        -Status $(if ($r -match '\+CIPMODE') { 'PASS' } else { 'WARN' }) | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+CIPMODE=0' -MaxMs 4000
    Add-Result -Id 'T2' -Group 'tcp' -Title '设为 AT 指令模式' -Cmd 'AT+CIPMODE=0' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'OK') { 'PASS' } else { 'WARN' }) -Note '必须在 NETOPEN 之前设置' | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+NETOPEN' -MaxMs 20000
    $netOk = ($r -match 'SUCCESS|(?m)^\+NETOPEN:\s*0')
    Add-Result -Id 'T3' -Group 'tcp' -Title '开启数据网络' -Cmd 'AT+NETOPEN' -Response (Format-Resp $r) `
        -Status $(if ($netOk) { 'PASS' } else { 'FAIL' }) | Out-Null
    if (-not $netOk) { return }

    $openCmd = "AT+CIPOPEN=1,`"TCP`",`"$TcpHost`",$TcpPort"
    $r = Send-At -Sp $Sp -Cmd $openCmd -MaxMs 25000
    $openOk = ($r -match 'SUCCESS|(?m)^\+CIPOPEN:\s*0,\s*1')
    Add-Result -Id 'T4' -Group 'tcp' -Title "建立 TCP 连接 $TcpHost`:$TcpPort" -Cmd $openCmd -Response (Format-Resp $r) `
        -Status $(if ($openOk) { 'PASS' } else { 'FAIL' }) `
        -Note '失败时先查 APN/流量/目标端口是否可达' | Out-Null
    if (-not $openOk) {
        [void](Send-At -Sp $Sp -Cmd 'AT+NETCLOSE' -MaxMs 20000)
        return
    }

    # 用 HTTP HEAD 当载荷，能拿到回包就证明双向通路可用
    [void]$Sp.Write("AT+CIPSEND=1`r`n")
    $prompt = Read-UntilQuiet -Sp $Sp -Quiet 500 -MaxMs 5000 -StopOn '>'
    $payload = "HEAD / HTTP/1.0`r`nHost: $TcpHost`r`n`r`n"
    if ($prompt -match '>') {
        [void]$Sp.Write($payload)
        Start-Sleep -Milliseconds 300
        [void]$Sp.Write([char]0x1A)
        $send = Read-UntilQuiet -Sp $Sp -Quiet 2500 -MaxMs 15000
        Add-Result -Id 'T5' -Group 'tcp' -Title 'AT 模式发数据 CIPSEND' -Cmd 'AT+CIPSEND=1 -> <payload> -> 0x1A' `
            -Response ((Format-Resp $prompt) + "`n--`n" + (Format-Resp $send)) `
            -Status $(if ($send -match 'HTTP/|\+CIPSEND') { 'PASS' } else { 'WARN' }) `
            -Note '看到 HTTP/1.x 回包即证明收发双向可用' | Out-Null
    }
    else {
        Add-Result -Id 'T5' -Group 'tcp' -Title 'AT 模式发数据 CIPSEND' -Cmd 'AT+CIPSEND=1' `
            -Response (Format-Resp $prompt) -Status 'FAIL' -Note '未收到 > 提示符，无法进入数据输入态' | Out-Null
    }

    $r = Send-At -Sp $Sp -Cmd 'AT+CIPCLOSE=1' -MaxMs 8000
    Add-Result -Id 'T6' -Group 'tcp' -Title '关闭 TCP 连接' -Cmd 'AT+CIPCLOSE=1' -Response (Format-Resp $r) `
        -Status $(if ($r -match '(?m)^OK') { 'PASS' } else { 'WARN' }) `
        -Note $(if ($r -match 'FAIL') { '返回 +CIPCLOSE:FAIL：连接可能已被对端关闭' } else { '' }) | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+NETCLOSE' -MaxMs 20000
    Add-Result -Id 'T7' -Group 'tcp' -Title '关闭数据网络' -Cmd 'AT+NETCLOSE' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'SUCCESS|OK') { 'PASS' } else { 'WARN' }) | Out-Null

    if (-not $Transparent) {
        Add-Note '透传模式（CIPMODE=1 / ATO / +++）未测试，需要时加 -Transparent 重跑 tcp 阶段。'
        return
    }

    # ---- 透传模式：igate 实际会走的路径 ----
    Write-Host '        测试透传模式 CIPMODE=1 / ATO ...' -ForegroundColor DarkGray
    foreach ($c in @('AT+CIPMODE=1', 'AT+NETOPEN')) {
        $r = Send-At -Sp $Sp -Cmd $c -MaxMs 20000
        Add-Result -Id 'T8' -Group 'tcp' -Title "透传前置 $c" -Cmd $c -Response (Format-Resp $r) `
            -Status $(if ($r -match 'OK|SUCCESS') { 'PASS' } else { 'FAIL' }) | Out-Null
    }
    $openCmd0 = "AT+CIPOPEN=0,`"TCP`",`"$TcpHost`",$TcpPort"
    $r = Send-At -Sp $Sp -Cmd $openCmd0 -MaxMs 25000
    # CIPMODE=1 时模块可能不回 SUCCESS，而是直接给出 > 数据态提示符
    $openOk0 = ($r -match 'SUCCESS|(?m)^\+CIPOPEN:\s*0,\s*0|>')
    Add-Result -Id 'T9' -Group 'tcp' -Title '透传模式建立连接（link 0）' -Cmd $openCmd0 -Response (Format-Resp $r) `
        -Status $(if ($openOk0) { 'PASS' } else { 'FAIL' }) `
        -Note $(if ($r -match '>') { '模块直接进入 > 数据态（未回 SUCCESS），CIPMODE=1 时 link_num 必须为 0' } else { 'CIPMODE=1 时 link_num 必须为 0' }) | Out-Null
    if ($openOk0) {
        # 先按 > 数据态直发（与 CIPSEND 流程一致）
        [void]$Sp.Write("HEAD / HTTP/1.0`r`nHost: $TcpHost`r`n`r`n")
        Start-Sleep -Milliseconds 300
        [void]$Sp.Write([char]0x1A)
        $rx = Read-UntilQuiet -Sp $Sp -Quiet 2500 -MaxMs 15000
        $how = '数据态直发 + 0x1A'

        if ($rx -notmatch 'HTTP/') {
            # 直发没有回包，退出来按手册走 ATO 透传路径
            $back1 = Invoke-AtGuarded -Sp $Sp -Cmd 'AT'
            if ($back1 -match '(?m)^OK') {
                $openRetry = Send-At -Sp $Sp -Cmd $openCmd0 -MaxMs 25000
                [void]$Sp.WriteLine('ATO')
                Start-Sleep -Milliseconds 800
                [void]$Sp.Write("HEAD / HTTP/1.0`r`nHost: $TcpHost`r`n`r`n")
                $rx2 = Read-UntilQuiet -Sp $Sp -Quiet 2500 -MaxMs 15000
                $rx = (Format-Resp $rx) + "`n--ATO--`n" + (Format-Resp $rx2)
                $how = 'ATO 透传 + 裸数据'
            }
        }
        Add-Result -Id 'T10' -Group 'tcp' -Title '透传收发' -Cmd $how `
            -Response (Format-Resp $rx) -Status $(if ($rx -match 'HTTP/') { 'PASS' } else { 'WARN' }) `
            -Note '拿到 HTTP 回包说明透传可用，igate 可复用该路径' | Out-Null

        $back = Invoke-AtGuarded -Sp $Sp -Cmd 'AT'
        Add-Result -Id 'T11' -Group 'tcp' -Title '退出透传 +++ 回到 AT 模式' -Cmd '+++ / AT' `
            -Response (Format-Resp $back) `
            -Status $(if ($back -match '(?m)^OK') { 'PASS' } else { 'FAIL' }) -Note '必须确认回到 AT 命令模式' | Out-Null
    }
    $r = Send-At -Sp $Sp -Cmd 'AT+CIPCLOSE=0' -MaxMs 8000
    if ($r -match 'FAIL') { Add-Note '透传 link0 关闭返回 FAIL（连接可能已被对端断开），请复查 +CIPOPEN?。' }
    [void](Wait-Idle -Sp $Sp -Quiet 400 -MaxMs 4000)
    [void](Send-At -Sp $Sp -Cmd 'AT+CIPMODE=0' -MaxMs 4000)
    [void](Send-At -Sp $Sp -Cmd 'AT+NETCLOSE' -MaxMs 30000)
    [void](Wait-Idle -Sp $Sp -Quiet 400 -MaxMs 5000)
}

function Invoke-AprsTest {
    <#
        用模块内置协议栈直连 APRS-IS，验证 igate 实际要走的端到端通路。
        只读服务器问候语，不发送登录行、不注入任何 APRS 报文，对网络无副作用。
    #>
    param([System.IO.Ports.SerialPort] $Sp)

    # 先按 APRS-IS 官方算法本地自校验 passcode，避免把“码错”误判成“服务器拒绝”
    if ($AprsCallsign) {
        $call = ($AprsCallsign -split '-')[0].Trim().ToUpperInvariant()
        $hash = 0x73e2
        for ($i = 0; $i -lt $call.Length; $i += 2) {
            $hash = $hash -bxor ([int][char]$call[$i] -shl 8)
            if (($i + 1) -lt $call.Length) { $hash = $hash -bxor [int][char]$call[$i + 1] }
        }
        $calc = $hash -band 0x7fff
        $pcOk = ($AprsPasscode -eq $calc)
        Add-Result -Id 'A0' -Group 'aprs' -Title 'passcode 本地自校验' -Cmd "call=$call pass=$AprsPasscode" `
            -Response ("服务器算法应为 $calc") -Status $(if ($pcOk) { 'PASS' } else { 'FAIL' }) `
            -Note $(if ($pcOk) { '码值正确，可期待 logresp verified' } else { '码值与算法不符，登录会得到 unverified（只读）' }) | Out-Null
    }

    $r = Send-At -Sp $Sp -Cmd 'AT+CIPMODE=0' -MaxMs 4000
    Add-Result -Id 'A1' -Group 'aprs' -Title '设为 AT 指令模式' -Cmd 'AT+CIPMODE=0' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'OK') { 'PASS' } else { 'WARN' }) | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+NETOPEN' -MaxMs 20000
    $netOk = ($r -match 'SUCCESS')
    Add-Result -Id 'A2' -Group 'aprs' -Title '开启数据网络' -Cmd 'AT+NETOPEN' -Response (Format-Resp $r) `
        -Status $(if ($netOk) { 'PASS' } else { 'FAIL' }) | Out-Null
    if (-not $netOk) { return }
    [void](Wait-Idle -Sp $Sp -Quiet 400 -MaxMs 3000)

    $r = Send-At -Sp $Sp -Cmd "AT+MDNSGIP=$AprsHost" -MaxMs 15000
    $dnsOk = ($r -match '\d+\.\d+\.\d+\.\d+')
    Add-Result -Id 'A3' -Group 'aprs' -Title "解析 APRS-IS 域名 $AprsHost" -Cmd "AT+MDNSGIP=$AprsHost" -Response (Format-Resp $r) `
        -Status $(if ($dnsOk) { 'PASS' } else { 'FAIL' }) `
        -Note $(if ($dnsOk) { '' } else { '解析失败先查 DNS/APN 与域名是否仍有效，不要先怀疑模块' }) | Out-Null

    $conn = "AT+CIPOPEN=1,`"TCP`",`"$AprsHost`",$AprsPort"
    $r = Send-At -Sp $Sp -Cmd $conn -MaxMs 25000
    $ok = ($r -match 'SUCCESS')
    # 建连成功后服务器问候语常常紧跟 +CIPRXGET 一起到达，不能只看后面的被动读
    $bannerInConn = ($r -match '#\s*aprsc|#\s*javAPRSSrvr')
    Add-Result -Id 'A4' -Group 'aprs' -Title "建立 APRS-IS 连接 $AprsHost`:$AprsPort" -Cmd $conn -Response (Format-Resp $r) `
        -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) `
        -Note $(if ($ok) { '' } else { '14580 是 APRS-IS 过滤端口，连不上先确认域名/端口与实际可用性' }) | Out-Null
    if (-not $ok) {
        [void](Send-At -Sp $Sp -Cmd 'AT+NETCLOSE' -MaxMs 30000)
        return
    }

    # APRS-IS 建连后会主动下发 "# aprsc ..." 问候语，收到即证明链路可用
    $banner = Format-Resp (Read-UntilQuiet -Sp $Sp -Quiet 4000 -MaxMs 20000)
    $gotBanner = ($banner -match '#\s*aprsc|#\s*javAPRSSrvr|^#') -or $bannerInConn
    Add-Result -Id 'A5' -Group 'aprs' -Title '接收 APRS-IS 服务器问候语' -Cmd '(passive read 20s)' `
        -Response $(if ($banner) { $banner } else { ($r | Select-String -Pattern '#\s*aprsc' | ForEach-Object { $_.Line }) }) `
        -Status $(if ($gotBanner) { 'PASS' } else { 'WARN' }) `
        -Note $(if ($gotBanner) { '端到端通路可用：模块内置 TCP 可以承载 APRS-IS 文本协议' } else { '未收到问候语，可能被服务器限速/需先发登录行' }) | Out-Null

    # ---- A8：真实登录 + 下行验证（需要呼号与 passcode）----
    if ($AprsCallsign -and $AprsPasscode -ge 0 -and $ok) {
        $login = "user $AprsCallsign pass $AprsPasscode vers ESP32APRS 1.8"
        if ($AprsFilter) { $login = "$login filter $AprsFilter" }

        [void]$Sp.Write("AT+CIPSEND=1`r`n")
        $prompt = Read-UntilQuiet -Sp $Sp -Quiet 800 -MaxMs 6000 -StopOn '>'
        if ($prompt -match '>') {
            [void]$Sp.Write($login + "`r`n")
            Start-Sleep -Milliseconds 300
            [void]$Sp.Write([char]0x1A)
            $resp = Format-Resp (Read-UntilQuiet -Sp $Sp -Quiet 3000 -MaxMs 20000)
            $verified = ($resp -match '#\s*logresp\s+\S+\s+verified')
            $unverified = ($resp -match '#\s*logresp\s+\S+\s+unverified')
            Add-Result -Id 'A8' -Group 'aprs' -Title '发送登录行并校验 logresp' -Cmd $login -Response $resp `
                -Status $(if ($verified) { 'PASS' } elseif ($unverified) { 'FAIL' } else { 'WARN' }) `
                -Note $(if ($verified) { '登录通过（verified）：可发送报文' }
                    elseif ($unverified) { 'verified 未通过，服务器判为只读（通常 passcode 不对）' }
                    else { '未收到 logresp，需复查登录行格式/服务器是否限速' }) | Out-Null

            # 登录后继续收一段，确认下行数据通路（纯接收，不注入任何报文）
            $rx = Format-Resp (Read-UntilQuiet -Sp $Sp -Quiet 6000 -MaxMs 30000)
            $pkts = ([regex]::Matches($rx, '(?m)^[A-Z0-9\-]+>')).Count
            $hasKeepalive = ($rx -match '#\s*aprsc')
            Add-Result -Id 'A9' -Group 'aprs' -Title '下行数据通路（按 filter 收包）' -Cmd "filter $AprsFilter" -Response $rx `
                -Status $(if ($pkts -gt 0) { 'PASS' } elseif ($rx) { 'WARN' } else { 'WARN' }) `
                -Note ("收到 APRS 报文行数 ≈ " + $pkts + "；本项只接收不发送") | Out-Null
        }
        else {
            Add-Result -Id 'A8' -Group 'aprs' -Title '发送登录行并校验 logresp' -Cmd $login -Response (Format-Resp $prompt) `
                -Status 'FAIL' -Note '未拿到 > 提示符，无法发送登录行' | Out-Null
        }
    }
    elseif ($AprsCallsign) {
        Add-Result -Id 'A8' -Group 'aprs' -Title '发送登录行并校验 logresp' -Cmd '(需要 -AprsCallsign 与 -AprsPasscode)' `
            -Response '(skipped)' -Status 'SKIP' -Note '连接未建立，跳过登录' | Out-Null
    }

    $r = Send-At -Sp $Sp -Cmd 'AT+CIPCLOSE=1' -MaxMs 8000
    Add-Result -Id 'A6' -Group 'aprs' -Title '关闭 APRS-IS 连接' -Cmd 'AT+CIPCLOSE=1' -Response (Format-Resp $r) `
        -Status $(if ($r -match '(?m)^OK') { 'PASS' } else { 'WARN' }) | Out-Null
    [void](Wait-Idle -Sp $Sp -Quiet 400 -MaxMs 4000)

    $r = Send-At -Sp $Sp -Cmd 'AT+NETCLOSE' -MaxMs 30000
    Add-Result -Id 'A7' -Group 'aprs' -Title '关闭数据网络' -Cmd 'AT+NETCLOSE' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'SUCCESS|OK') { 'PASS' } else { 'WARN' }) | Out-Null
    [void](Wait-Idle -Sp $Sp -Quiet 400 -MaxMs 5000)

    if (-not $AprsCallsign) {
        Add-Note '未发送登录行（避免以呼号身份出现在 APRS-IS 上）。加 -AprsCallsign/-AprsPasscode 可跑 A8/A9 真实登录与下行测试。'
    }
}

function Invoke-GnssTest {
    param([System.IO.Ports.SerialPort] $Sp)

    function Get-NmeaCount {
        param([string] $Text)
        return ([regex]::Matches($Text, '(?m)^\$G[PNLBA]')).Count
    }

    if ($ActiveAntenna) {
        foreach ($c in @('AT+CGDRT=12,1', 'AT+CGSETV=12,1', 'AT+CGGETV=12')) {
            $r = Send-At -Sp $Sp -Cmd $c -MaxMs 4000
            Add-Result -Id 'G0' -Group 'gnss' -Title '有源天线供电配置' -Cmd $c -Response (Format-Resp $r) `
                -Status $(if ($r -match 'OK') { 'PASS' } else { 'WARN' }) -Note '厂商底板+有源天线才需要' | Out-Null
        }
    }
    else {
        Add-Result -Id 'G0' -Group 'gnss' -Title '有源天线供电配置' -Cmd 'AT+CGDRT=12,1 / AT+CGSETV=12,1 / AT+CGGETV=12' `
            -Response '(skipped)' -Status 'SKIP' -Note '未加 -ActiveAntenna；仅厂商底板+有源天线需要' | Out-Null
    }

    $r = Send-At -Sp $Sp -Cmd 'AT+MGPSC?' -MaxMs 4000
    Add-Result -Id 'G1' -Group 'gnss' -Title 'GNSS 当前开关状态' -Cmd 'AT+MGPSC?' -Response (Format-Resp $r) `
        -Status 'INFO' | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+MGPSC=1' -MaxMs 10000
    Add-Result -Id 'G2' -Group 'gnss' -Title '开启 GNSS' -Cmd 'AT+MGPSC=1' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'success|OK') { 'PASS' } else { 'FAIL' }) | Out-Null

    # GPSMODE 在 GNSS 关闭时会回 +CME ERROR: 4，必须在开机后再查
    $r = Send-At -Sp $Sp -Cmd 'AT+GPSMODE?' -MaxMs 5000
    Add-Result -Id 'G2b' -Group 'gnss' -Title 'GPS 启动模式 GPSMODE' -Cmd 'AT+GPSMODE?' -Response (Format-Resp $r) `
        -Status $(if ($r -match '(?m)^\+GPSMODE') { 'PASS' } else { 'WARN' }) `
        -Note '1=热启动 2=温启动 3=冷启动' | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+MGPSGET=ALL,1' -MaxMs 5000
    Add-Result -Id 'G3' -Group 'gnss' -Title 'NMEA 输出使能 MGPSGET' -Cmd 'AT+MGPSGET=ALL,1' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'OK|\+MGPSGET') { 'PASS' } else { 'WARN' }) | Out-Null

    # 被动抓 NMEA：若能直接从 MAIN_UART(COM6) 读到 $Gx 语句，就不必再拆 AUX 串口
    $nmea = Format-Resp (Read-Fixed -Sp $Sp -Ms 5000)
    $hasNmea = ($nmea -match '(?m)^\$(G[PNLBA]|BD|GN)')
    Add-Result -Id 'G4' -Group 'gnss' -Title 'MAIN_UART 被动抓 NMEA' -Cmd '(passive read 5s)' -Response $nmea `
        -Status $(if ($hasNmea) { 'PASS' } else { 'WARN' }) `
        -Note $(if ($hasNmea) { 'NMEA 也走 MAIN_UART，可直接用 C3 UART1 复用（注意与 AT 指令交织）' } else { 'MAIN_UART 未见 NMEA；NMEA 在 AUX_TXD，需要第二个串口（任务 M1）' }) | Out-Null

    # ---- NMEA 端口选择：能否只走 AUX，不污染 MAIN_UART ----
    $q = Send-At -Sp $Sp -Cmd 'AT+MGPSGET?' -MaxMs 5000
    Add-Result -Id 'G4a' -Group 'gnss' -Title '查询 NMEA 输出设置' -Cmd 'AT+MGPSGET?' -Response (Format-Resp $q) -Status 'INFO' | Out-Null

    $base = Format-Resp (Read-Fixed -Sp $Sp -Ms 4000)
    $baseCount = Get-NmeaCount $base
    Add-Result -Id 'G4b' -Group 'gnss' -Title 'MAIN_UART NMEA 基线（ALL,1）' -Cmd '(passive read 4s)' `
        -Response ("MAIN_UART 上 1Hz 的 NMEA 行数 = " + $baseCount) -Status 'INFO' | Out-Null

    foreach ($cand in @('AT+MGPSGET=1,1', 'AT+MGPSGET=UART1,1', 'AT+MGPSGET=AUX,1')) {
        $r = Send-At -Sp $Sp -Cmd $cand -MaxMs 5000
        if ($r -match 'ERROR|CME') {
            Add-Result -Id 'G4c' -Group 'gnss' -Title "NMEA 端口尝试 $cand" -Cmd $cand -Response (Format-Resp $r) `
                -Status 'WARN' -Note '固件不接受该写法' | Out-Null
            continue
        }
        $echo = Send-At -Sp $Sp -Cmd 'AT+MGPSGET?' -MaxMs 5000
        $after = Format-Resp (Read-Fixed -Sp $Sp -Ms 4000)
        $cnt = Get-NmeaCount $after
        Add-Result -Id 'G4c' -Group 'gnss' -Title "NMEA 端口尝试 $cand" -Cmd "$cand ; AT+MGPSGET?" `
            -Response ((Format-Resp $echo) + " | MAIN NMEA 行数=" + $cnt) `
            -Status $(if ($cnt -eq 0) { 'PASS' } else { 'WARN' }) `
            -Note $(if ($cnt -eq 0) { 'MAIN_UART 已静音，NMEA 仅剩 AUX' } else { 'MAIN_UART 仍在输出，说明该写法不能按端口静音' }) | Out-Null
    }
    [void](Send-At -Sp $Sp -Cmd 'AT+MGPSGET=ALL,1' -MaxMs 5000)
    [void](Wait-Idle -Sp $Sp -Quiet 600 -MaxMs 3000)

    Write-Host "        等待定位（最长 $GpsFixWaitSec s）..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddSeconds($GpsFixWaitSec)
    $lastTxt = ''
    $lastFix = ''
    $fixed = $false
    $rounds = 0
    $lastAnt = ''
    while ((Get-Date) -lt $deadline) {
        $rounds++
        [void](Read-Fixed -Sp $Sp -Ms 1200)   # 先排掉 NMEA 洪流，避免把 +GPSSTEX 结果行挤掉
        $lastTxt = Format-Resp (Send-At -Sp $Sp -Cmd 'AT+GPSSTEX' -MaxMs 6000)
        $m = [regex]::Match($lastTxt, '\+GPS(5TEX|STEX)[:：]\s*(\d+)\s*,\s*(\d+)\s*,\s*([-0-9.]+)\s*,\s*([-0-9.]+)\s*,\s*([-0-9.]+)\s*,\s*([-0-9.]+)\s*,\s*(\d+)\s*,\s*(\d+)')
        if ($m.Success) {
            $lastFix = "fix_status={0} 经度={1} 高度={2} 纬度={3} 速度={4} 可见星={5} 参与定位星={6}" -f `
                $m.Groups[2].Value, $m.Groups[4].Value, $m.Groups[5].Value, $m.Groups[6].Value, `
                $m.Groups[7].Value, $m.Groups[8].Value, $m.Groups[9].Value
            if ($m.Groups[2].Value -eq '1') { $fixed = $true; break }
        }
        $antM = [regex]::Match($lastTxt, 'ANTSTATUS=(\w+)')
        if ($antM.Success) { $lastAnt = $antM.Groups[1].Value }
        Start-Sleep -Seconds 2
    }
    Add-Result -Id 'G5' -Group 'gnss' -Title '查询定位 GPSSTEX' -Cmd 'AT+GPSSTEX' -Response $lastTxt `
        -Status $(if ($fixed) { 'PASS' } else { 'WARN' }) -Note $lastFix | Out-Null
    Add-Result -Id 'G5b' -Group 'gnss' -Title '定位结论' -Cmd ("轮询 " + $rounds + " 次") `
        -Response $(if ($fixed) { '已定位' } else { '未定位' }) `
        -Status $(if ($fixed) { 'PASS' } else { 'WARN' }) `
        -Note $(if ($fixed) { '定位成功，可用于 APRS 位置上报' }
            elseif ($lastAnt -and $lastAnt -ne 'OK') { "未定位；NMEA 报 ANTSTATUS=$lastAnt（室内通常如此）。天线已接且户外定位正常时，本项按环境限制处理（任务 M5）" }
            else { '未定位：室内、天线未接或需要更久冷启动（天线就绪时属环境限制）' }) | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+CPSI?' -MaxMs 5000
    Add-Result -Id 'G6' -Group 'gnss' -Title 'GSM/LTE 小区信息' -Cmd 'AT+CPSI?' -Response (Format-Resp $r) `
        -Status $(if ($r -match '(?m)^\+CPSI') { 'PASS' } else { 'WARN' }) -Note 'GSM 基站定位/网络质量参考' | Out-Null

    $r = Send-At -Sp $Sp -Cmd 'AT+MGPSC=0' -MaxMs 8000
    Add-Result -Id 'G7' -Group 'gnss' -Title '关闭 GNSS（省电复位）' -Cmd 'AT+MGPSC=0' -Response (Format-Resp $r) `
        -Status $(if ($r -match 'success|OK') { 'PASS' } else { 'WARN' }) | Out-Null
}

# ---------------------------------------------------------------- 主流程
if ($Stage -contains 'all') {
    $Stage = @('link', 'info', 'sim', 'net', 'ppp', 'tcp', 'aprs', 'gnss', 'pwr')
}

$stateStages = @('net', 'ppp', 'tcp', 'aprs', 'gnss')
$wantedState = @($Stage | Where-Object { $stateStages -contains $_ })
if ($wantedState.Count -gt 0 -and -not $AllowStateChange -and -not $ListOnly) {
    Write-Host "已请求会改变模块状态的阶段: $($wantedState -join ', ')" -ForegroundColor Yellow
    foreach ($s in $wantedState) { Write-Host ("  - " + (Get-DisabledStageHint $s)) -ForegroundColor Yellow }
    Write-Host '拒绝执行。确认硬件接线与供电后加 -AllowStateChange 重跑。' -ForegroundColor Yellow
    exit 2
}

$tests = Get-AtTests
$planned = @($tests | Where-Object { $Stage -contains $_.Stage })

if ($ListOnly) {
    Write-Output ''
    Write-Output 'DX-CT511N 测试任务表（不连硬件）'
    Write-Output ('端口 {0} @ {1} 8N1，默认阶段 {2}' -f $Port, $Baud, ((@('link','info','sim')) -join ','))
    Write-Output ''
    $planned | ForEach-Object {
        '{0,-5} {1,-6} {2,-28} {3}' -f $_.Id, $_.Stage, $_.Title, $_.Cmd
    }
    Write-Output ''
    Write-Output '只读阶段 : link / info / sim / pwr'
    Write-Output '变更阶段 : net / ppp / tcp / aprs / gnss（需 -AllowStateChange）'
    Write-Output '特殊流程 : L2 回显控制 / P2,P3,P4 PPP 拨号探测 / T1..T11 TCP 与透传 / A1..A7 APRS-IS / G0..G7 GNSS'
    Write-Output '手动任务: M1 AUX NMEA 抓包 / M2 电平转换验电 / M3 电源跌落 / M4 ESP32-C3 联调 / M6 户外 TTFF'
    exit 0
}

if ($planned.Count -eq 0 -and $Stage.Count -eq 0) {
    Write-Host '没有可用阶段。' -ForegroundColor Red
    exit 2
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $LogDir "ct511n_$stamp.log"
$csvPath = Join-Path $LogDir "ct511n_$stamp.csv"

Write-Head "DX-CT511N AT 测试 @ $Port"
Write-Host ("阶段: {0}   波特率: {1} 8N1   状态变更: {2}" -f ($Stage -join ','), $Baud, [bool]$AllowStateChange)
Write-Log ("# DX-CT511N AT 测试 端口=$Port 波特率=$Baud 阶段=" + ($Stage -join ',') + " 时间=" + (Get-Date -Format s))

$sp = $null
try {
    $sp = Open-CtPort -Name $Port -Rate $Baud
}
catch {
    Write-Host ("打开 $Port 失败: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host '检查：端口是否被 PlatformIO Monitor 占用；USB-TTL 驱动是否正常。' -ForegroundColor Yellow
    exit 3
}

try {
    # 有状态变更阶段时，先无条件把模块拉回 AT 命令模式，避免上次中断残留在透传/数据态
    if (@($Stage | Where-Object { $stateStages -contains $_ }).Count -gt 0) {
        $back = Invoke-AtGuarded -Sp $sp -Cmd 'AT'
        Write-Host ("        [guard] 强制回 AT 模式: " + $(if ($back -match '(?m)^OK') { 'OK' } else { '无应答' })) -ForegroundColor DarkGray
    }

    # ---------- link ----------
    if ($Stage -contains 'link') {
        Write-Head 'link 串口链路'
        $probe = Send-At -Sp $sp -Cmd 'AT' -MaxMs 3000
        if ($probe -notmatch 'OK') {
            Write-Host 'AT 无 OK，尝试自动扫描常见波特率...' -ForegroundColor Yellow
            $sp.Close()
            $found = 0
            foreach ($rate in @(9600, 19200, 38400, 57600, 115200, 230400)) {
                try {
                    $tsp = Open-CtPort -Name $Port -Rate $rate
                    $t = Send-At -Sp $tsp -Cmd 'AT' -Quiet 300 -MaxMs 1500
                    $tsp.Close(); $tsp.Dispose()
                    if ($t -match 'OK') { $found = $rate; break }
                }
                catch { }
            }
            if ($found -gt 0) {
                Write-Host "在 $found 波特率上找到模块，后续使用该速率。" -ForegroundColor Yellow
                Add-Note "模块实际波特率为 $found，与请求的 $Baud 不同，建议 AT+IPR=$Baud 固定。"
                $Baud = $found
                $sp = Open-CtPort -Name $Port -Rate $Baud
            }
            else {
                Add-Result -Id 'L1' -Group 'link' -Title 'AT 基本应答' -Cmd 'AT' -Response (Format-Resp $probe) `
                    -Status 'FAIL' -Note '所有常见波特率均无 OK：检查 TX/RX 交叉、共地、1.8V 电平转换、PWRKEY 是否开机' | Out-Null
            }
        }
        if ($sp.IsOpen) {
            foreach ($t in ($planned | Where-Object { $_.Stage -eq 'link' })) {
                $resp = Send-At -Sp $sp -Cmd $t['Cmd'] -MaxMs $t['Timeout']
                $fmt = Format-Resp $resp
                $ok = $fmt -match $t['Expect']
                Add-Result -Id $t['Id'] -Group $t['Stage'] -Title $t['Title'] -Cmd $t['Cmd'] -Response $fmt `
                    -Status $(if ($ok) { 'PASS' } else { 'FAIL' }) -Note $(if ($ok) { '' } else { $t['Note'] }) | Out-Null
            }
            Invoke-EchoTest -Sp $sp
        }
    }

    # ---------- info / sim ----------
    foreach ($group in @('info', 'sim', 'pwr')) {
        if ($Stage -notcontains $group) { continue }
        Write-Head "$group"
        foreach ($t in ($planned | Where-Object { $_.Stage -eq $group })) {
            $resp = Send-At -Sp $sp -Cmd $t['Cmd'] -MaxMs $t['Timeout']
            $fmt = Format-Resp $resp
            $ok = $fmt -match $t['Expect']
            $status = if ($ok) { 'PASS' } elseif ($t['Optional']) { 'WARN' } else { 'FAIL' }
            Add-Result -Id $t['Id'] -Group $t['Stage'] -Title $t['Title'] -Cmd $t['Cmd'] -Response $fmt `
                -Status $status -Note $(if ($ok) { '' } else { $t['Note'] }) | Out-Null
        }
    }

    # ---------- net ----------
    if ($Stage -contains 'net') {
        Write-Head 'net 内置协议栈联网'
        if ($Apn) {
            $apnCmd = "AT+QICSGP=1,1,`"$Apn`",`"`",`"`""
            $r = Send-At -Sp $sp -Cmd $apnCmd -MaxMs 5000
            Add-Result -Id 'N0' -Group 'net' -Title '配置 APN' -Cmd $apnCmd -Response (Format-Resp $r) `
                -Status $(if ($r -match 'OK') { 'PASS' } else { 'WARN' }) | Out-Null
        }
        foreach ($t in ($planned | Where-Object { $_.Stage -eq 'net' })) {
            $resp = Send-At -Sp $sp -Cmd $t['Cmd'] -MaxMs $t['Timeout']
            $fmt = Format-Resp $resp
            $ok = $fmt -match $t['Expect']
            $status = if ($ok) { 'PASS' } elseif ($t['Optional']) { 'WARN' } else { 'FAIL' }
            Add-Result -Id $t['Id'] -Group $t['Stage'] -Title $t['Title'] -Cmd $t['Cmd'] -Response $fmt `
                -Status $status -Note $(if ($ok) { '' } else { $t['Note'] }) | Out-Null
            # 有些指令（MPING/NETOPEN/NETCLOSE）会异步续吐结果，先排空再发下一条
            [void](Wait-Idle -Sp $sp -Quiet 400 -MaxMs 4000)
        }
    }

    # ---------- ppp ----------
    if ($Stage -contains 'ppp') {
        Write-Head 'ppp 拨号能力探测（关键未知项）'
        Invoke-PppProbe -Sp $sp
    }

    # ---------- tcp ----------
    if ($Stage -contains 'tcp') {
        Write-Head 'tcp 内置透传'
        Invoke-TcpTest -Sp $sp
    }

    # ---------- gnss ----------
    # ---------- aprs ----------
    if ($Stage -contains 'aprs') {
        Write-Head "aprs 直连 APRS-IS（$AprsHost`:$AprsPort）"
        Invoke-AprsTest -Sp $sp
    }

    # ---------- gnss ----------
    if ($Stage -contains 'gnss') {
        Write-Head 'gnss 定位'
        Invoke-GnssTest -Sp $sp
    }
}
finally {
    if ($sp -and $sp.IsOpen) { $sp.Close() }
    if ($sp) { $sp.Dispose() }
}

# ---------------------------------------------------------------- 汇总
Write-Head '结果汇总'
$script:Results | Format-Table -AutoSize Id, Stage, Status, Title | Out-String -Width 200 | Write-Host

$counts = $script:Results | Group-Object Status | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }
Write-Host ("统计: " + ($counts -join '  '))
Write-Log ''
Write-Log ("统计: " + ($counts -join '  '))

if ($script:Notes.Count -gt 0) {
    Write-Host ''
    Write-Host '备注:' -ForegroundColor Yellow
    foreach ($n in $script:Notes) { Write-Host ("  - " + $n) -ForegroundColor Yellow }
    Write-Log '备注:'
    foreach ($n in $script:Notes) { Write-Log ("  - " + $n) }
}

$script:Results | Select-Object Id, Stage, Title, Command, Status, Note, Response |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Set-Content -Path $logPath -Value $script:Log.ToString() -Encoding UTF8

Write-Host ''
Write-Host ("日志: $logPath")
Write-Host ("结果: $csvPath")

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
