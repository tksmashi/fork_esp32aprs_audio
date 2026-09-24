# DX-CT511N 硬件测试任务编排（COM6 实测版）

> 硬件：DX-CT511N（LYNQ_L511CN_2C）经 USB-TTL 接 **COM6**
> 被测固件版本：`L511CN_2Cv04.01b01.00`（Build 2025/01/22 17:46）
> 执行器：`tools/ct511n/ct511n_at_test.ps1`（Windows 自带 SerialPort，无需 pyserial）
> 实测日期：2026-09-24 ｜ 串口参数：**115200 8N1**，命令必须以 **CRLF** 结束

---

## 1. 任务编排原则

1. **由外到内、由静到动**：先验证串口链路，再读身份，再验 SIM/注网，最后才做会改变模块状态的操作（开数据网络、拨号、建 TCP、开 GNSS）。
2. **可重复、可回滚**：每条任务都有明确命令、判据、以及测试后的状态恢复动作（`AT+NETCLOSE` / `AT+MGPSC=0` / `+++` 退回 AT 模式）。
3. **状态变更门禁**：`net / ppp / tcp / gnss` 四个阶段会改变模块状态，脚本默认拒绝执行，必须显式加 `-AllowStateChange`，避免误操作。
4. **证据留档**：每轮输出 `.log`（含原始字节）+ `.csv`（结构化结果）到 `tmp/ct511n_logs/`。

---

## 2. 阶段与任务清单

### 阶段一：link 串口链路（只读）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| L1 | AT 基本应答 | `AT` | 回 `OK` | ✅ PASS |
| L2 | 回显控制 | `ATE0` → `AT` → `ATE1` | 关回显后无 echo 且仍回 OK | ✅ PASS |
| L3 | 串口波特率 | `AT+IPR?` | `+IPR: 115200` | ✅ PASS |

> L1 失败时脚本会自动扫 9600/19200/38400/57600/115200/230400，并在结论里提示实际波特率。

### 阶段二：info 模块身份（只读）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| I1 | 型号标识 | `ATI` | 返回厂商/型号/版本/IMEI | ✅ PASS |
| I2 | 厂商型号 | `AT+CGMM` | `+CGMM` | ✅ PASS |
| I3 | 固件版本 | `AT+CGMR` | `+CGMR` | ✅ PASS |
| I4 | IMEI | `AT+CGSN` | 15 位数字（带引号也接受） | ✅ PASS |
| I5 | 模块时钟 | `AT+CCLK?` | `+CCLK` | ✅ PASS |
| I6 | 功能开关 | `AT+CFUN?` | `+CFUN: 1` | ✅ PASS |
| I7 | 电池/供电状态 | `AT+CBC?` | `+CBC` | ⚠️ WARN（该固件不支持，返回 ERROR） |

### 阶段三：sim SIM 与注网（只读）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| S1 | SIM 卡状态 | `AT+CPIN?` | `+CPIN: READY` | ✅ PASS |
| S2 | SIM 卡号 | `AT+ICCID` | `+ICCID` | ✅ PASS |
| S3 | 信号强度 | `AT+CSQ` | `+CSQ: <rssi>,<ber>`，99=无信号 | ✅ PASS（rssi 25~30） |
| S4 | 网络注册 | `AT+CEREG?` | stat=1 本地 / 5 漫游 | ✅ PASS（3,1） |
| S5 | 运营商 | `AT+COPS?` | `+COPS` | ✅ PASS（46000 中国移动） |
| S6 | 小区信息 | `AT+CPSI?` | `+CPSI` | ✅ PASS（LTE Band40） |
| S7 | 分组域附着 | `AT+CGATT?` | `+CGATT: 1` | ✅ PASS |

### 阶段四：pwr 功耗/休眠状态（只读）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| W1 | 指令休眠设置 | `AT+SYSSLEEP?` | `+SYSSLEEP` | ✅ PASS（0） |
| W2 | DTR 休眠设置 | `AT+CSCLK?` | `+CSCLK` | ✅ PASS（0） |
| W3 | GNSS 开关状态 | `AT+MGPSC?` | `+MGPSC` | ✅ PASS（0） |
| W4 | 功能开关 | `AT+CFUN?` | `+CFUN` | ✅ PASS（1） |

### 阶段五：net 内置协议栈联网（状态变更）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| N1 | APN 查询 | `AT+QICSGP=1` | `+QICSGP` | ✅ PASS（`"cmiot"`） |
| N2 | 开启数据网络 | `AT+NETOPEN` | `+NETOPEN:SUCCESS` | ✅ PASS |
| N3 | 数据网络状态 | `AT+NETOPEN?` | `+NETOPEN:1` | ✅ PASS |
| N4 | DNS 解析 | `AT+MDNSGIP=www.baidu.com` | 返回 IPv4 | ✅ PASS（36.152.44.93） |
| N5 | Ping | `AT+MPING=域名,1,1,32,3` | `+MPING:1,...` | ✅ PASS（RTT 30~45ms） |
| N6 | NTP 授时 | `AT+QNTP=1,"ntp.aliyun.com",123,1` | `+QNTP: 0,"时间"` | ✅ PASS（**延迟约 30s**） |
| N7 | 校时复核 | `AT+CCLK?` | `+CCLK` | ✅ PASS |
| N8 | 关闭数据网络 | `AT+NETCLOSE` | `+NETCLOSE:SUCCESS` | ✅ PASS |

> 注意：`AT+MPING` 省略参数时默认 ping 4 次，会长时间占用串口并顶掉后续命令的响应；测试必须显式给 `num_pings`。
> 注意：模块**没有“查询本机 IP”指令**，只能用 `AT+NETOPEN?` 判断网络状态。

### 阶段六：ppp PPP 拨号能力探测（状态变更，关键未知项）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| P2 | PDP 上下文面 | `AT+CGDCONT?` | 返回 `+CGDCONT` | ✅ 支持（PDP 地址 `10.252.212.239`） |
| P3 | PDP 激活状态 | `AT+CGACT?` | 返回 `+CGACT` | ✅ 已激活（1,1） |
| P4 | **UART PPP 拨号** | `ATD*99#` | 期待 `CONNECT` | ❌ **FAIL：返回 `ERROR`（3 次复现）** |

### 阶段七：tcp 内置 TCP 收发与透传（状态变更）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| T1 | 传输模式查询 | `AT+CIPMODE?` | `+CIPMODE` | ✅ PASS |
| T2 | 设为 AT 指令模式 | `AT+CIPMODE=0` | `OK`（**必须在 NETOPEN 前**） | ✅ PASS |
| T3 | 开启数据网络 | `AT+NETOPEN` | SUCCESS | ✅ PASS |
| T4 | 建 TCP 连接 | `AT+CIPOPEN=1,"TCP","www.baidu.com",80` | `+CIPOPEN: SUCCESS,1` | ✅ PASS |
| T5 | AT 模式发数据 | `AT+CIPSEND=1` → `>` → 数据 → `0x1A` | `+CIPSEND:SUCCESS` 且收到 HTTP 回包 | ✅ PASS（40/40 字节，收到 `HTTP/1.0 200 OK`） |
| T6 | 关连接 | `AT+CIPCLOSE=1` | `OK` | ✅ PASS（`+CIPCLOSE:FAIL` = 对端已断） |
| T7 | 关数据网络 | `AT+NETCLOSE` | SUCCESS | ✅ PASS |
| T8 | 透传前置 | `AT+CIPMODE=1` + `AT+NETOPEN` | OK/SUCCESS | ✅ PASS |
| T9 | 透传建连接 | `AT+CIPOPEN=0,"TCP",...` | 回 `>` 数据态（**不回 SUCCESS**） | ✅ PASS |
| T10 | 透传收发 | 数据态直发 + `0x1A` | 收到 `HTTP/1.0 200 OK` | ✅ PASS |
| T11 | 退出透传 | `+++` → `AT` | 回 `OK` | ✅ PASS |

> 实测发现：`AT+CIPMODE=1` 时 `AT+CIPOPEN=0` 直接返回 `>` 数据态提示符，**不回 `+CIPOPEN: SUCCESS`**；此时直发数据 + `0x1A` 即可收到对端回包，不需要先发 `ATO`。脚本对两条路径都做了尝试。

### 阶段八：gnss GNSS 定位（状态变更）

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| G0 | 有源天线供电 | `AT+CGDRT=12,1` / `AT+CGSETV=12,1` / `AT+CGGETV=12` | 三条 OK 且 `+CGGETV:12,1` | ✅ PASS（仅 `-ActiveAntenna` 时执行） |
| G1 | GNSS 当前状态 | `AT+MGPSC?` | `+MGPSC: 0` | ℹ️ INFO |
| G2 | 开启 GNSS | `AT+MGPSC=1` | `+GPS: start up success.` | ✅ PASS |
| G2b | 启动模式 | `AT+GPSMODE?` | `+GPSMODE` | ✅ PASS（1=热启动） |
| G3 | NMEA 使能 | `AT+MGPSGET=ALL,1` | `OK` | ✅ PASS |
| G4 | **MAIN_UART 抓 NMEA** | 被动读 5s | 出现 `$GNRMC/$GNGGA/...` | ✅ **PASS：NMEA 同时从 MAIN_UART 输出（1Hz）** |
| G4a | 输出设置回显 | `AT+MGPSGET?` | `+GETGPS: ALL,1` | ℹ️ INFO |
| G4b | MAIN NMEA 基线 | 被动读 4s | 统计行数 | ℹ️ INFO（约 36~45 行） |
| G4c | 按端口静音尝试 | `AT+MGPSGET=1,1 / UART1,1 / AUX,1` | MAIN 上 NMEA 归零 | ⚠️ WARN（**三种写法都被接受但都不会静音 MAIN**） |
| G5 | 定位查询 | `AT+GPSSTEX` | `+GPSSTEX: 1,...` | ⚠️ WARN（`0, 1, 0,0,0,0, 00, 00` 未定位） |
| G5b | 定位结论 | 轮询到超时 | fix=1 | ⚠️ WARN（室内无星；**用户已确认户外定位正常**，见 M5） |
| G6 | 小区信息 | `AT+CPSI?` | `+CPSI` | ✅ PASS |
| G7 | 关闭 GNSS | `AT+MGPSC=0` | `+GPS: AGPS poweroff success.` | ✅ PASS |

### 阶段九：aprs 直连 APRS-IS 端到端（状态变更）

目的：验证“模块内置 TCP → APRS-IS 服务器”这条 igate 实际要走的通路，只读取服务器问候语，**不发送登录行、不注入任何报文**，对网络无副作用。

| 任务 | 项目 | 命令 | 判据 | 实测 |
|---|---|---|---|---|
| A1 | 设为 AT 指令模式 | `AT+CIPMODE=0` | `OK` | ✅ PASS |
| A2 | 开启数据网络 | `AT+NETOPEN` | `+NETOPEN:SUCCESS` | ✅ PASS |
| A3 | 解析 APRS-IS 域名 | `AT+MDNSGIP=china.aprs2.net` | 返回 IPv4 | ✅ PASS（47.243.119.157） |
| A4 | 建立连接 | `AT+CIPOPEN=1,"TCP","china.aprs2.net",14580` | `+CIPOPEN: SUCCESS` | ✅ PASS |
| A5 | 收服务器问候语 | 被动读 20s | 出现 `# aprsc ...` | ✅ PASS（`# aprsc 2.1.19-g730c5c0`） |
| A0 | passcode 本地自校验 | 按 APRS-IS 哈希算法复算 | 与所给码一致 | ✅ PASS（BD4WMA → <passcode>，一致） |
| A8 | 真实登录 | `user BD4WMA pass <passcode> vers ESP32APRS 1.8 filter r/31.23/121.47/50` | `# logresp ... verified` | ✅ PASS（`# logresp BD4WMA verified, server T2NANJING`） |
| A9 | 下行数据通路 | 登录后按 filter 接收 30s | 收到 APRS 报文 | ✅ PASS（收到 6 个不重复报文：BD8CMN-5 / BH4FBI-9 / BI4BRJ / BI4BLE-15 / BH4EBS-N / BH4GCQ-QG） |
| A6 | 关连接 | `AT+CIPCLOSE=1` | `OK` | ✅ PASS（`+CIPCLOSE:SUCCESS,1`） |
| A7 | 关数据网络 | `AT+NETCLOSE` | `SUCCESS` | ✅ PASS |

> 注意：旧资料里的 `aprs.dprns.com` **已无法公网解析**（Windows `Resolve-DnsName` 直接失败），脚本默认目标已改为区域轮转服务器 `china.aprs2.net:14580`，可用 `-AprsHost`/`-AprsPort` 覆盖。
> 问候语通常在 `AT+CIPOPEN` 的**同一个读取窗口**里随 `+CIPRXGET` 一起到达，A5 会合并两个窗口的结果判定。
> A8/A9 只在传了 `-AprsCallsign` 与 `-AprsPasscode` 时执行，且**只登录与接收，不注入任何报文**。

---

## 3. 本轮实测关键结论

### 3.1 模块基本能力：全部正常

| 项 | 实测值 |
|---|---|
| 厂商/型号 | LYNQ / LYNQ_L511CN_2C |
| 固件 | L511CN_2Cv04.01b01.00（2025/01/22） |
| IMEI | <IMEI> |
| SIM | READY，ICCID `<ICCID>`（中国移动物联网卡） |
| 注网 | CEREG stat=1；COPS 46000；CGATT=1 |
| 无线 | LTE Band40，EARFCN 38950，RSRP −75~−86dBm，CSQ 25~30 |
| APN | `cmiot`（已预置，无需手工配置） |

### 3.2 4G 数据联网（模块内置协议栈）：可用

`AT+NETOPEN` → `+NETOPEN:SUCCESS`，DNS/Ping/NTP 均成功，NTP 把模块时间校到本地时间（`+CCLK: "26/09/24,11:59:57+32"`）。

### 3.3 ❌ 关键结论一：**DX-CT511N 不支持 UART PPP 拨号**

- `AT+CGDCONT?` 支持，能读到 PDP 上下文和运营商分配的地址 `10.252.212.239`；
- 但 `ATD*99#` 稳定返回 `ERROR`（3 次复现），没有任何 `CONNECT`。
- 含义：**ESP32APRS 现有的 `esp_modem` PPPoS 联网路径（`PPP.begin(...)`）在这颗模块上走不通**。
- 可走路径：模块内置 AT 协议栈 —— `AT+NETOPEN` → `AT+CIPOPEN`（AT 模式或 `CIPMODE=1` 透传）。实测两种模式都能完成完整的 TCP 收发。
- 对固件的影响：igate 的 APRS-IS 连接需要改成“串口 AT/透传管道”而不能复用 `WiFiClient/AsyncClient` 网络层；代价与《DX-CT511N_4G_Cat1_Module.md》第 7.4 节“情形 B”一致。

### 3.4 ❌ 关键结论二：**NMEA 会同时从 MAIN_UART 输出**

原文档假设“NMEA 只在 AUX_TXD，与 AT 串口物理隔离”。实测在 `AT+MGPSGET=ALL,1` 下，MAIN_UART（即 COM6）上以 1Hz 持续输出 `$GNRMC/$GNVTG/$GNGGA/$GPGSA/$BDGSA/$GLGSA/$GNGLL/$GNZDA/$GNGST/$GNTXT`。

- 影响：若用 C3 的同一个 UART 既发 AT/透传数据又收 NMEA，必须按行过滤 `$` 开头的语句；透传模式下 NMEA 会混入 TCP 数据流。
- 尝试用 `AT+MGPSGET=1,1` / `=UART1,1` / `=AUX,1` 单独静音 MAIN 均失败（命令被接受但不生效），需要向厂商确认该指令第一参数的取值域。
- 待验证：AUX_TXD 是否也在输出（任务 M1，需要第二个串口）。

### 3.5 GNSS 功能正常，本轮未定位属室内环境限制（已确认）

- `+GPSSTEX: 0, 1, 0.000000, 0.000000, 0.000000, 0.000000, 00, 00` → 本轮未定位、可见星 0；
- NMEA 里出现 `$GNTXT,01,01,02,ANTSTATUS=UNKNOWN`，室内属正常表现；
- GNSS 芯片已解出有效 UTC 时间（`$GNRMC,...,240926`），说明射频前端与串口输出都在工作；
- **用户已确认：天线已安装，户外定位功能完好。**
- 结论：本轮 GNSS 测试项全部按“功能正常 + 室内环境限制”归档；`AT+MGPSC=1` / `AT+GPSMODE?` / `AT+MGPSGET=ALL,1` / `AT+GPSSTEX` / `AT+MGPSC=0` 全链路命令均验证可用。户外 TTFF 计时留给任务 M6。

### 3.6 ✅ 关键结论三：模块内置 TCP 已完整跑通 APRS-IS（含登录与收发）

用模块内置协议栈直连 `china.aprs2.net:14580`，全链路无人工干预：

| 环节 | 实测 |
|---|---|
| 域名解析 | `+MDNSGIP:china.aprs2.net,47.243.119.157,...` |
| 建立连接 | `+CIPOPEN: SUCCESS,1` |
| 服务器问候语 | `# aprsc 2.1.19-g730c5c0` |
| 登录（`user BD4WMA pass <passcode> vers ESP32APRS 1.8 filter r/31.23/121.47/50`） | `# logresp BD4WMA verified, server T2NANJING` |
| 下行数据 | 30s 内收到 6 个不重复真实报文 |
| 收尾 | `+CIPCLOSE:SUCCESS,1`、`+NETCLOSE:SUCCESS` |

- passcode 用 APRS-IS 哈希算法本地复算过，`BD4WMA → <passcode>` 一致，所以 `verified` 是真通过而非碰巧；
- 含义：**即使 PPP 不可用，DX-CT511N 作为“串口 TCP 管道”承载 APRS-IS 文本协议这条路已被端到端证明可行**（上行发送、下行接收、登录鉴权都验过）；
- 本项只做登录与接收，**没有向 APRS-IS 注入任何报文**，不会以 BD4WMA 的身份出现在网络上；
- 仍待验证的是长期行为：断线重连、`AT+MCIPCFG` 心跳保活（任务 A10）；
- 配合 3.4 的 NMEA 冲突问题：透传模式下 NMEA 会混入 TCP 数据流，固件侧必须做行过滤或确认端口静音能力。

### 3.7 固件侧待修（已核对代码）

| 位置 | 问题 | 说明 |
|---|---|---|
| `src/main.cpp:3869`、`src/main.cpp:6074` | `strstr("AT", config.gnss_at_command)` 参数写反 | 应改为 `strstr(config.gnss_at_command, "AT") != NULL`；否则配置 `AT+MGPSC=1` 永远不会被发送 |
| `src/main.cpp:80`、`src/main.cpp:8361` | `PPP_MODEM_MODEL` 硬编码 `PPP_MODEM_SIM800`，`config.ppp_model` 未生效 | 因 PPP 本身不可用，此项优先级下降；若仍要保留 PPPoS 路径需一并处理 |
| 架构 | igate 网络层依赖 `WiFiClient/AsyncClient` | 走内置 AT 栈需要新增串口 TCP 通道，属于较大改动 |
| `include/config.h:322` | `gnss_at_command[30]` 单条命令 | DX-CT511N 只需 `AT+MGPSC=1`（10 字符）够用；如需同时下发 `AT+MGPSGET=ALL,1` 则需扩展 |

---

## 4. 待做任务（需硬件/人工介入，脚本无法覆盖）

| 任务 | 目标 | 步骤要点 | 判据 |
|---|---|---|---|
| **M1** | AUX_TXD 的 NMEA 与波特率 | 第二个 USB-TTL：接模块 pin29 `AUX_TXD` + GND，分别用 9600 / 115200 抓包 | 能看到 `$GNRMC` 等语句，记录实际波特率 |
| **M2** | 电平转换验电 | 万用表测模块 MAIN_TXD 空闲电平；若为 1.8V 必须加 TXB0108；PWRKEY 为 0~VBAT | ESP32 侧不出现 3.3V 直连 1.8V 域 |
| **M3** | 供电能力 | VBAT 3.8V / ≥1.2A；在 `AT+NETOPEN` 与建连瞬间测跌落 | 发射瞬态跌落可接受、不重启（输出侧建议 ≥330µF） |
| **M4** | ESP32-C3 联调 | UART1(MAIN) 打 AT/透传，UART0(AUX) 收 NMEA；修 `strstr` 后验证定位解析 | `TinyGPSPlus` 能解析出坐标 |
| ~~**M5**~~ | ~~GNSS 天线排查~~ | **已完成（用户确认）**：天线已安装，户外定位正常；本轮室内 `ANTSTATUS=UNKNOWN` 属环境限制 | ✅ 关闭 |
| **M6** | 冷启动 TTFF / AGNSS | 户外冷启动计时（规格 ≤28s）；联网后 `AT+AGNSSGET=pos.asrmicro.com` → `AT+AGNSSSET` 再测 | 记录冷/热启动 TTFF |
| **M7** | 功耗实测 | 空闲/休眠（规格 0.7mA）、`AT+SYSSLEEP=1`、`AT+CSCLK=1` 下分别测 | 与规格同量级 |
| **M8** | MQTT / HTTP（可选） | `AT+MCONFIG/MIPSTART/MCONNECT`；`AT$HTTPOPEN...` | 视业务需要 |
| **A10** | APRS-IS 长期保活 | 登录后挂机 ≥10min，观察断线；配 `AT+MCIPCFG=<秒>` 心跳后复测 | 连接不自掉、掉线可重连 |

---

## 5. 复跑命令

```powershell
# 1) 只看任务表，不连硬件
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -ListOnly

# 2) 只读阶段（安全，默认）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage link,info,sim,pwr -Port COM6

# 3) 联网 + PPP 能力复测
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage net,ppp -Port COM6 -AllowStateChange

# 4) TCP 收发 + 透传（igate 实际会走的路径）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage tcp -Port COM6 -AllowStateChange -Transparent

# 5) GNSS（含天线供电序列，等定位 60s）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage gnss -Port COM6 -AllowStateChange -ActiveAntenna -GpsFixWaitSec 60

# 6) 直连 APRS-IS 端到端（只收问候语，不发登录）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage aprs -Port COM6 -AllowStateChange

# 7) APRS-IS 真实登录 + 下行接收（只登录/接收，不注入报文）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage aprs -Port COM6 -AllowStateChange `
  -AprsCallsign BD4WMA -AprsPasscode <passcode> -AprsFilter 'r/31.23/121.47/50'

# 8) 全量
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage all -Port COM6 -AllowStateChange -Transparent
```

可选参数：`-Baud`（默认 115200）、`-Apn`（默认不改 APN）、`-NtpServer`、`-TcpHost`/`-TcpPort`、`-AprsHost`/`-AprsPort`（默认 `china.aprs2.net:14580`）、`-AprsCallsign`/`-AprsPasscode`/`-AprsFilter`、`-Raw`（打印完整回包）。

结果留档：`tmp/ct511n_logs/ct511n_<时间戳>.log`（原始字节）与 `.csv`（结构化结果表）。

---

## 6. 风险与注意事项

1. **不要手动跑裸 `ATD*99#`**：若某天固件启用 PPP，它会进入数据态；脚本已内置 `+++` + `ATH` 兜底，手工测试请自己准备退路。
2. **串口独占**：测试前先停掉平台 IO Monitor / 串口助手，否则 COM6 打不开。
3. **脚本自带“回 AT 模式”守卫**：每个状态变更阶段开头会发 `+++` + `AT`，即使上一轮中断在透传态也能自愈。
4. **`AT+IPR=<n>` 会掉电保存**，本脚本只在链路失败扫描波特率时提示，不主动改写；要固定波特率请自行确认后执行。
5. **GNSS 上线后 MAIN_UART 会被 NMEA 刷屏**，会让纯文本串口助手看起来很乱，属正常现象。
6. 电源不足会导致联网/建连随机失败，排查时先量 VBAT 跌落，再怀疑模块。
7. 旧资料给出的 APRS-IS 地址 `aprs.dprns.com` 已失效，复测请用 `china.aprs2.net:14580` 或 `rotate.aprs2.net:14580`。

---

## 7. 固件版本与升级渠道核查（2026-09-24）

### 7.1 当前固件

| 项 | 值 |
|---|---|
| 型号 | `LYNQ_L511CN_2C`（DX-CT511N） |
| 固件 Revision | `L511CN_2Cv04.01b01.00` |
| 编译时间 | `2025/01/22 17:46` |
| 查询方式 | `ATI` / `AT+CGMR` |

### 7.2 公开渠道核查结果：**没有公开固件**

| 渠道 | 核查结果 |
|---|---|
| 官网 CT511 下载页 | 仅 3 项：资料包 `.zip`（2026-09-12）、技术手册 `.pdf`（2026-09-12）、应用指导 `.pdf`（2026-08-17） |
| 资料包内部（20251202 版） | 手册 / 应用指导 / 测试工具 / 硬件封装 / 例程与视频链接——**无任何 `.bin` 固件或烧录工具** |
| 官网“资料下载”栏目全站导航 | 无固件专区（只有资料包、文档、开发工具） |
| 官网“技术支持”页 | 内容是“方案定制”流程（销售对接 → 需求文档 → FAE 审核 → 开发 → 生产），不提供固件 |
| 应用指导 V2.3 的 AT 指令全表 | 没有任何升级 / 固件管理命令 |
| 4G_DTU 工具包（4G_DTU.rar） | 只有 `DTU_AT.exe`（AT 配置工具）+ 依赖 DLL，无固件升级功能 |

### 7.3 ⚠️ 但模块内部保留着未公开的 FOTA 接口

主动查询发现：

| 命令 | 响应 | 说明 |
|---|---|---|
| `AT+FOTA?` | `+FOTA: 0` | **固件层存在 FOTA 能力**，但官方文档完全未提及 |
| `AT+UPGRADE?` | `ERROR` | 无 |
| `AT+OTA?` | `ERROR` | 无 |
| `AT+UPDATE?` | `ERROR` | 无 |

含义：模块具备空中升级的底层接口，但属于**厂商内部通道**——没有公开的参数说明、升级服务器和固件包，也没有授权流程，不能自行调用（误用可能导致模块变砖）。本次只做了只读查询，**没有下发任何 FOTA 写操作**。

### 7.4 结论与建议动作

1. **无法自助判断或下载新固件**：必须向厂商索取。
2. 索取渠道：微信公众号「大夏龙雀通信专家」→ 服务支持 → 资料下载（软件工具）；或厂商技术交流 QQ 群 / 官网“联系我们”页；大客户走 FAE。
3. 建议同时问清三个问题（都和我们已实测的结论直接相关）：
   - 是否有比 `L511CN_2Cv04.01b01.00`（2025/01/22）更新的版本？请提供固件包与升级工具/流程。
   - 新版本是否开放 **UART PPP 拨号**（我们实测 `ATD*99#` 返回 `ERROR`）？
   - `AT+MGPSGET` 第一参数能否按端口选择（我们实测 `ALL` 会让 NMEA 同时刷 MAIN_UART，`1,1`/`UART1,1`/`AUX,1` 都静音不了 MAIN）？
4. **升级前提醒**：刷固件有变砖风险，且现有固件行为（PPP 不支持、NMEA 双端口输出、APRS-IS 直连已验证可用）都已固化在测试基线里。升级后建议直接复跑全量：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ct511n\ct511n_at_test.ps1 -Stage all -Port COM6 -AllowStateChange -Transparent `
  -AprsCallsign BD4WMA -AprsPasscode <passcode>
```
