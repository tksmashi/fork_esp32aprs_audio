# DX-CT511 / DX-CT511N 4G Cat.1 模块资料整理与 ESP32-C3 结合可行性分析

> 整理自资料包：`E:\GIT\DX-CT511&CT511N资料包`
> 主要参考文档：
> - 01 模块技术手册 / DX-CT511、DX-CT511N-4G模块技术手册.pdf（v2.1, 2024-08-20）
> - 02 模块功能应用指导 / DX-CT511&CT511N_串口UART_应用指导.pdf（v2.1, 2024-04-16）
> - 02 模块功能应用指导 / DX-CT511N-NMEA0183协议规范.pdf（v1.0, 2024-07-30）
> - 02 模块功能应用指导 / DX-CT511&CT511N_SIM卡流量操作示例.pdf

> 官方在线复核（2026-09-23）：
> - 产品详情：`https://www.szdx-smart.com/lyzhq/lyzRJ45/126.html`
> - 资料下载：`https://www.szdx-smart.com/zlxz/4Gmk/4Gmokuai/407.html`
> - 官网当前技术手册为 **V2.4（2026-09-09）**，串口应用指导为 **V2.3（2026-08-14）**；本地资料包分别还是 V2.1。
> - 官网最新版仍未公开 `ATD*99#`、`AT+CGDCONT` 等 PPP 拨号指令，官方明确路径仍是模块内置协议栈和 TCP/UDP 透传；PPP-over-UART 是否可用仍必须实测。

---

## 1. 资料包内容概览

| 目录 | 内容 |
|---|---|
| 01 模块技术手册 | 本地 DX-CT511/DX-CT511N-4G模块技术手册.pdf（V2.1，42页）；官网最新 V2.4，43页 |
| 02 模块功能应用指导 | 本地串口 UART 应用指导（V2.1，37页）；官网最新 V2.3，38页；NMEA0183 协议规范（14页）；SIM 卡流量操作示例 |
| 03 模块测试工具 | 4G_DTU（RAR）；Android 测试 APP（DX-SMART，仅 MQTT 可用）；PC 串口助手（sscom5.13.1、CH340 驱动）；定位测试工具（MobiletekGNSSTool，公众号获取）；TCP/UDP/HTTP 测试网址 |
| 04 模块硬件资料 | PCB Footprint & 原理图（AD/PADS）；底板封装：PJ14(-A)/PJ20(-B) |
| 05 单片机例程+视频教程 | 例程网盘、B 站视频教程链接 |

- TCP/UDP 测试平台：`http://netlab.luatos.com/`；HTTP 测试：`https://httpbin.org/`
- 例程网盘：`https://pan.baidu.com/s/1TM_bhhZxs1XYpwCInLnWmQ?pwd=DXLQ`
- B 站教程：CT511 视频 `BV1BM4m1z7x1`；GNSS 多卫星定位 `BV1ovG1zuEh7`

---

## 2. 模块核心参数（以官网 V2.4 复核）

### 2.1 型号与形态（官网 V2.4 新增说明）

| 形态 | 型号 | 说明 |
|---|---|---|
| 贴片模块 | DX-CT511 / DX-CT511N | 17.7×15.8×2.3mm，109-pin LCC+LGA，VBAT 3.3~4.5V |
| 底板款 | DX-CT511-A / DX-CT511N-A | 带底板，底板 VIN 5~16V |
| Mini 底板款 | DX-CT511-B / DX-CT511N-B | 带 Mini 底板，底板 VIN 5~16V |

官网产品卡片中的“22.3×21×2.3mm、工作电压 5~16V”是底板/成品形态参数，不能与贴片模块的 VBAT 3.3~4.5V 混用。

| 项目 | 参数 |
|---|---|
| 厂商 | 深圳大夏龙雀科技有限公司（www.szdx-smart.com） |
| 型号 | DX-CT511 / **DX-CT511N（带 GNSS）** |
| 网络制式 | LTE Cat.1bis：TDD B34/B38/B39/B40/B41；FDD B1/B3/B5/B8 |
| 速率 | FDD 下行 10Mbps / 上行 5Mbps；TDD 下行 8.96Mbps / 上行 3.1Mbps |
| 发射功率 | 23dBm±2dB |
| 芯片 | ARM Cortex-R5 @ 614MHz（内部型号 LYNQ L511C_2C，ASR 平台），2MB Flash |
| 工作电压 | 3.3V ~ 4.5V（推荐 3.8V）；**峰值电流 1.2A** |
| 功耗 | V2.4 概述标注 CT511N-B Mini 底板款：空闲 13mA、休眠 0.7mA、关机 6uA；详细功耗表另列 CT511N Flight mode 0.77mA、LTE Standby 0.96mA、峰值 1.2A |
| 尺寸/封装 | 17.7×15.8×2.3mm；109-pin LCC+LGA |
| 工作温度 | -40℃ ~ +85℃ |
| 接口 | 主控芯片支持 3×UART（MAIN/AUX/DBG）、USB2.0、I2C、ADC、SIM(1.8/3.0V)、PCM、SPI、GPIO、扬声器；**V2.4 明确说明这些只是芯片能力，是否开放取决于出厂固件和底板设计** |
| 内置协议 | TCP / UDP / HTTP / MQTT / NMEA-0183 |
| 认证 | CCC、SRRC |

### GNSS（仅 CT511N）

| 项目 | 参数 |
|---|---|
| 星座 | GPS / BeiDou / GLONASS |
| 接收通道 | 64 |
| 灵敏度 | 跟踪 -165dBm；热启 -155dBm；冷启 -148dBm |
| TTFF | 冷启 28s；热启 1s |
| 精度 | 2.0m CEP50；速度 0.1m/s |
| 更新率 | 1Hz；支持 1PPS |
| 输出 | NMEA 0183；GNSS 功能默认关闭，开启 GNSS 后 NMEA 输出参数默认为 1；CT511N 的 AUX_UART 与内部 GNSS 串口复用 |

---

## 3. 关键引脚（技术手册 V2.4 2.2 / 2.8 节）

| 引脚 | 名称 | 说明 |
|---|---|---|
| 2 | ANT-GNSS | GNSS 天线（仅 CT511N 用） |
| 7 | PWRKEY | 开机键：拉低 >1s 开机；拉低 >3s 关机；可 1K 电阻下拉实现上电自开机 |
| 15 | RESET_N | 复位，低有效（1.8V 域），拉低 1s |
| 16 | NET_STATUS | 网络状态指示（64ms/800ms 未注册，64ms/3000ms 已注册） |
| 17 / 18 | MAIN_RXD / MAIN_TXD | 主串口（AT + 数据，默认 115200/8/N/1） |
| 19 / 20 / 21 / 22 / 23 | MAIN_DTR / RI / DCD / CTS / RTS | 完整流控/唤醒信号 |
| 28 / 29 | AUX_RXD / AUX_TXD | 辅助串口；**CT511N 上与 GNSS 串口复用，NMEA 由此输出** |
| 35 | ANT_MAIN | LTE 主天线 |
| 38 / 39 | DBG_RXD / DBG_TXD | 调试串口（115200 日志） |
| 59 / 60 / 61 | USB_DP / USB_DM / USB_VBUS | USB2.0（仅从模式） |
| 98 | PPS | 秒脉冲（GNSS 版才有） |
| 11~14 | USIM_DATA/RST/CLK/VDD | SIM 卡（支持 1.8/3.0V 自动检测） |

**V2.4 重要限定：** 上表是主控芯片的引脚能力，不代表所有引脚都已由出厂固件开放；实际可用功能要结合 CT511N 具体固件版本和所用底板确认。

**注意事项：**
- GPIO、UART、I2C、PCM 等通用数字接口为 **1.8V 电压域**，与 3.3V 的 ESP32 连接必须加电平转换（文档推荐 TXB0108RGYR）；但 PWRKEY 是 0~VBAT、USB_VBUS 是 5V、USIM 是 1.8/3.0V，不能概括成“所有 IO 都是 1.8V”。
- 贴片模块供电要求 VBAT 走线 ≥1.2mm、电源具备 ≥1.2A 能力；官方建议压差较大时用 DC/DC，并在输出侧加大于 330uF 电容。底板款 VIN 才是 5~16V。
- 使用厂商底板且接有源 GNSS 天线时，开启定位前按顺序发 `AT+CGDRT=12,1`、`AT+CGSETV=12,1`、`AT+CGGETV=12`；这三条是底板天线供电配置，不应默认当成裸模块通用指令。

---

## 4. 串口与 AT 指令（UART 应用指导）

### 4.1 串口基本参数
- 默认 115200/8/N/1；V2.4 技术手册明确 MAIN_UART 支持 2400、4800、9600、14400、19200、38400、57600、76800、115200、230400bps，**没有官方 460800/921600 依据**；DBG_UART 固定 115200bps。
- 三种模式：AT 指令模式（默认）/ 数据传输模式 / 休眠模式。

### 4.2 联网 AT 命令（模块内置协议栈，非 PPP）
| 功能 | 指令 | 说明 |
|---|---|---|
| 测试 | `AT` | 返回 OK |
| 关/开回显 | `ATE0` / `ATE1` | |
| 模块信息 | `ATI` | 返回 LYNQ_L511C_2C 等 |
| 波特率 | `AT+IPR=115200` | 断电保存 |
| SIM 识别 | `AT+ICCID` | 返回 ICCID 则正常 |
| 注册状态 | `AT+CEREG?` | stat=1/5 可上网 |
| 信号强度 | `AT+CSQ` | 0~31（rssi），99 无信号 |
| 配置 APN | `AT+QICSGP=1,1,"CMIOT","",""` | |
| 开数据网络 | `AT+NETOPEN` | 返回 +NETOPEN:SUCCESS |
| 关数据网络 | `AT+NETCLOSE` | |
| NTP 时间 | `AT+QNTP=1,"服务器",123,1` | |
| 查询时间 | `AT+CCLK?` | UTC |
| DNS 解析 | `AT+MDNSGIP=域名` | |
| Ping | `AT+MPING=域名,1` | |

### 4.3 TCP/UDP
| 功能 | 指令 |
|---|---|
| 配置 APN | `AT+QICSGP=1,1,"","",""` |
| 开启网络 | `AT+NETOPEN` |
| 设传输模式 | `AT+CIPMODE=1`（1=透传） |
| 建立连接 | `AT+CIPOPEN=0,"TCP","主机",端口` |
| 发数据（AT 模式） | `AT+CIPSEND=0` → `>` 后发数据 → HEX `1A` 结束 |
| 进入透传 | `ATO` |
| 退出透传 | `+++`（无回车） |
| 关闭连接 | `AT+CIPCLOSE=0` |

### 4.4 MQTT / HTTP
- MQTT：`AT+MCONFIG` → `AT+MIPSTART="host",port` → `AT+MCONNECT=1,60` → `AT+MSUB` / `AT+MPUB` / `AT+MPUBEX` → `AT+MDISCONNECT` → `AT+MIPCLOSE`。
- HTTP：`AT$HTTPOPEN` → `AT$HTTPPARA=url,port` → `AT$HTTPRQH` / `AT$HTTPDATAEX` / `AT$HTTPDATA` / `AT$HTTPSEND` → `AT$HTTPACTION=0|1|3` → `AT$HTTPCLOSE`。

### 4.5 GNSS 相关 AT 命令（CT511N）
| 功能 | 指令 |
|---|---|
| 开启 GPS | `AT+MGPSC=1`（返回 `+GPS: start up success.`） |
| 关闭 GPS | `AT+MGPSC=0` |
| GPS 启动模式 | `AT+GPSMODE=1/2/3`（热/温/冷启动） |
| 使能 NMEA 输出 | `AT+MGPSGET=ALL,1`（0 关闭 / 1 开启，文档标注默认 1） |
| 直接查询定位 | V2.3 指导已将旧 `AT+GPSST` 修正为 **`AT+GPSSTEX`**：`+GPSSTEX:fix,module,lon,high,lat,speed,可见卫星,参与定位卫星` |
| AGNSS 下载 | `AT+AGNSSGET=pos.asrmicro.com`（需联网） |
| AGNSS 应用 | `AT+AGNSSSET` |
| 基站信息 | V2.3 新增 `AT+CPSI?`，可返回 LTE 频段、TAC、Cell ID、RSRP/RSRQ/RSSI/SINR 等 |
| 有源天线配置 | `AT+CGDRT=12,1` / `AT+CGSETV=12,1` / `AT+CGGETV=12` |

> 注意：V2.3 更新记录明确说明修正了查询定位指令错误，当前应以 `AT+GPSSTEX` 为准；返回顺序仍为 **lon, high, lat**，坐标系 WGS-84。官网示例响应头写成 `+GPS5TEX`，疑为文档笔误，实测以真实返回为准。

---

## 5. NMEA 0183 协议（CT511N）

- 发送器标识：`$GP`（GPS/SBAS/QZSS）、`$BD`（北斗）、`$GL`（GLONASS）、`$GN`（多系统组合）。
- 支持语句：**GGA、GLL、GSA、GSV、RMC、VTG、ZDA、TXT、GST**。
- 坐标格式为度分格式（ddmm.mmmm），WGS-84。
- 例：`$GNRMC,073028.600,A,2236.40101,N,11349.73472,E,0.00,0.00,090724,,,A,V*00`。
- 定位质量：GGA 第 6 域 FS=1 为 SPS 有效定位；RMC status=A 有效。
- 该协议为标准 NMEA 0183，TinyGPSPlus 可直接解析。

---

## 6. SIM 卡与流量（文档 2）

- 通过微信公众号“大夏龙雀通信专家”→“拿样攻略”→“4G 数传流量充值”，按 ICCID 登录查询/充值。
- 叠加包流量月末清零；流量查询约有 3 小时延迟。

---

## 7. 与 ESP32-C3 + ESP32APRS 固件的结合可行性分析

### 7.1 目标
用 ESP32-C3（`esp32c3-nodisp` 环境，已开 `-DPPPOS`）连接 DX-CT511N，实现：
1. 4G Cat.1 联网（APRS-IS 等）；
2. GNSS 坐标获取（APRS 定位上报）。

### 7.2 硬件接线（关键点）
| ESP32-C3 资源 | 连接 | 说明 |
|---|---|---|
| UART1（`esp32c3-nodisp` 默认 RX=GPIO21、TX=GPIO20） | 模块 MAIN_UART（pin18=TXD→C3 RX、pin17=RXD←C3 TX） | 模块 AT / PPP 数据通道；若坚持改到 GPIO18/19，必须显式改配置，且 GPIO18/19 是 C3 的 USB D-/D+，不建议占用 |
| UART0（固件默认 RX=GPIO3、TX=GPIO1） | 模块 AUX_TXD（pin29，NMEA 输出） | `gnss_channel=1` 选择 UART0；若 GNSS 实际接 GPIO20，必须同步设置 `uart0_rx_gpio=20` 并启用 UART0 |
| GPIO（任意） | 模块 PWRKEY（pin7） | 开机：拉低 >1s；或 1K 下拉实现上电自开机 |
| 电源 | 底板 VIN 5~16V（底板自带 DC/DC） | 模块 VBAT 需 3.8V/1.2A，**不能由 C3 的 3.3V LDO 供电** |

**必须加 1.8V ↔ 3.3V 电平转换**（模块串口为 1.8V 域，推荐 TXB0108 或双向电平转换）。

对应固件配置至少需要：

- MAIN/PPP：`uart1` 对应引脚与 `ppp_rx_gpio` / `ppp_tx_gpio` 分别配置；`ppp_serial=1` 只选择 UART 编号，不会自动继承 UART1 的 GPIO。
- GNSS：`uart0_enable=true`、`uart0_baudrate` 等于 AUX 实测波特率、`gnss_channel=1`。只设 `gnss_enable` 不会初始化 `Serial0`。

### 7.3 定位（GNSS）可行性：✅ 硬件可行，固件需小修
- CT511N 的 AUX_UART 是 GNSS 专用 NMEA 输出，**与通信串口物理隔离**，4G 上网与定位互不干扰——这是该模块相对"单串口 4G+GPS"模块的最大优势。
- 官方流程：`AT+MGPSC=1` 开启 GNSS；`AT+MGPSGET=ALL,1` 的输出参数默认就是 1，通常只需配置开 GPS 这一条。C3 的 UART0 持续收到 NMEA → 固件 `taskGPS()` 中 `gps.encode()` 可直接复用（TinyGPSPlus 兼容 $GN 前缀）。
- 配置：`config.gnss_enable=true`、`config.gnss_channel=1`（UART0）、`uart0_enable=true` 并设置正确波特率。
- 不需要固件里 `ppp_gnss`（那是给 Quectel QGPS 命令用的，本模块用 `AT+MGPSC`/`AT+MGPSGET`，**不要勾选 ppp_gnss**）。

**当前代码阻塞点：** `main.cpp:3869` 和 `main.cpp:6074` 写成了 `strstr("AT", config.gnss_at_command)`，haystack/needle 顺序反了。配置 `AT+MGPSC=1` 时不会发送；只有配置串是字面量 `"AT"` 的子串时才会发。应改为 `strstr(config.gnss_at_command, "AT") != NULL`。此外 `gnss_at_command` 只有一个字段，建议只填 `AT+MGPSC=1`。

### 7.4 联网（PPPoS）可行性：⚠️ 需先验证 PPP 拨号
- ESP32APRS 固件的 4G 联网依赖 **esp_modem 的 PPP over Serial**（`PPP.begin(model, uart, baud)`，拨号串一般为 `ATD*99#`）。
- 复核官网最新 V2.4 技术手册和 V2.3 串口指导后，**仍未出现 `ATD*99#`、`AT+CGDCONT`、`AT+CGACT`、`AT+CGDATA` 等串口 PPP/分组数据拨号指令**；AT 指令总表给出的官方路径仍是 `AT+QICSGP` → `AT+NETOPEN` → `AT+CIPOPEN`/MQTT/HTTP。
- 应用指导错误码里出现“203：PPP 正在关闭”和“149：PDP 认证失败”，说明模块内部网络子系统可能使用 PPP/PDP，但这**不等于对外提供 UART PPP 拨号能力**。ASR/LYNQ 平台即便底层具备 PPP，也必须实测。
- 当前代码 `main.cpp:80` 实际硬编码的是 `PPP_MODEM_MODEL PPP_MODEM_SIM800`；`config.ppp_model` 和 Web 页的 pppModel 没有传给 `PPP.begin()`。文中如需改成 generic，必须确认当前 pioarduino/esp_modem 版本确实提供该枚举。

#### 分情况结论：
- **情形 A：模块支持 PPP 拨号（推荐，需实测）**
  - 实测方法：串口助手发送 `ATD*99#`（或 `ATD*99*1#`）看是否回 `CONNECT`。
  - 若支持：`config.ppp_enable=true`、`ppp_serial=1`、`ppp_serial_baudrate=115200`，并显式配置 `ppp_rx_gpio=21`、`ppp_tx_gpio=20`；再根据实际握手序列选择 `PPP_MODEM_SIM800` 或可用的 generic 驱动（main.cpp:80 修改 `PPP_MODEM_MODEL`）。
  - 固件改动很小；PPPoS 成功后整个 TCP/IP 栈可用，APRS-IS、NTP、MQTT、Web 均正常工作。

- **情形 B：模块不支持 PPP**
  - 只能走模块透传 TCP：`AT+NETOPEN` → `AT+CIPOPEN=0,"TCP","aprs服务器",14580` → `ATO`，把模块当"串口 TCP 管道"。
  - 这会与固件中 `WiFiClient`/`AsyncClient` 的网络层冲突，需要**改写 igate 的 APRS-IS 连接逻辑**（改用串口读写），工作量大、维护成本高；且 Web 服务、NTP、多连接等功能需另想办法。
  - 备选：让模块直接用 MQTT/HTTP 上报位置到自定义服务器（但 APRS-IS 是 TCP 文本协议，不适用）。

### 7.5 固件层面的其他调整点
1. `PPPOS_Start()` 无条件对 `config.ppp_rst_gpio` 执行 `pinMode/digitalWrite`（main.cpp:8346-8352）；默认值为 -1 时属于无效操作。最简单方案是 PWRKEY 通过 1K 电阻接地、上电即开机且 `ppp_rst_gpio=-1`，同时给代码加 `-1` 保护；若要 GPIO 控制，因 PWRKEY 电压域为 0~VBAT，建议用开漏/三极管而不是直接把 3.3V GPIO 当普通推挽输出。
2. `ppp_gnss` 那段 Quectel QGPS 命令（main.cpp:8374-8383）对本模块无效，**保持关闭**。
3. GNSS 不占用 PPP 串口，因此 C3 两个 UART（UART0=GNSS NMEA，UART1=模块 AT/PPP）分配合理，与 Web 配置页只支持 UART0/UART1 的限制吻合。
4. `PPP.begin(..., 115200)` 先以固定 115200 启动，之后才调用 `PPP.setBaudrate(config.ppp_serial_baudrate)`；因此首轮验证应先保持模块 115200，避免初始化阶段就波特率不匹配。

### 7.6 资源与功耗约束（ESP32-C3）
- **内存**：C3 无 PSRAM（约 360KB 可用）。PPP + LWIP + WebServer + 软件解调本身已经很紧，作者已通过 NOOTA 分区 + 精简列表（`TLMLISTSIZE 5`、`PKGLISTSIZE 20`）压内存。实测若 OOM，需关闭不用的功能（TLS/MQTT/过滤等）。
- **CPU**：C3 单核 160MHz，PPPoS + NMEA + AFSK 解调同时运行有负载风险，建议监测。
- **功耗**：概述中的空闲 13mA 是 CT511N-B Mini 底板款口径，峰值 1.2A 则由贴片模块功耗表确认；电池供电的 tracker 需考虑 4G 发射瞬态，建议电源按 ≥1.2A 设计。

---

## 8. 结论与待办清单

### 结论
| 项目 | 结论 |
|---|---|
| DX-CT511N + ESP32-C3 获取坐标 | ✅ **硬件可行**（AUX_UART 专出 NMEA，独立于通信串口）；但需先修 `strstr` 参数顺序 bug，并启用/配置 UART0 |
| DX-CT511N + ESP32-C3 4G 联网 | ⚠️ **PPPoS 低置信、未获官方文档支持**；官方路径是模块内置 AT 协议栈，与固件 PPPoS 架构不同 |
| 需固件改动量 | GNSS：修 `strstr` 顺序 + UART0 配置；情形 A（PPP 可用）：再改型号枚举和接线；情形 B（无 PPP）：需改写 igate 网络层，较大 |

### 官方复核结果

| 核对项 | 结果 |
|---|---|
| 技术手册版本 | 本地 V2.1（2024-08-20）；官网最新 V2.4（2026-09-09） |
| 串口应用指导版本 | 本地 V2.1（2024-04-16）；官网最新 V2.3（2026-08-14） |
| NMEA0183 规范 | 官网资料包内文件与本地 V1.0 SHA-256 完全一致 |
| PPP 拨号 | 最新官方资料仍未公开 UART PPP 拨号指令 |
| 定位查询 | 旧 `AT+GPSST` 已被 V2.2/V2.3 修正为 `AT+GPSSTEX` |
| 频段命名 | V2.3 已把 Band34/38/39/40/41 正确标成 TDD，不能沿用旧表中的 FDD 误标 |

### 待验证清单（上电实测）
1. `ATI` 确认固件版本；`AT+IPR=115200` 固定波特率。
2. 插 SIM → `AT+ICCID`、`AT+CEREG?`、`AT+CSQ`。
3. **测试 PPP**：先发 `AT+CGDCONT?` 看是否支持，再发 `ATD*99#` 是否回 `CONNECT`；若两条都无响应，基本可判定官方固件未开放串口 PPP。
4. 测试内置 TCP 透传：`AT+NETOPEN` → `AT+CIPMODE=1` → `AT+CIPOPEN=0,"TCP","aprs.dprns.com",14580` → `ATO`。
5. GNSS：先修 `strstr` 顺序并启用 UART0，再发 `AT+MGPSC=1` → 从 AUX_TXD 抓 NMEA（AUX 波特率官方未明确，需实测 9600/115200）；用 `AT+GPSSTEX` 与 `AT+CPSI?` 复核新版指令。
6. 电平转换与电源：确认 1.8V/3.3V 转换、VBAT 3.8V/1.2A 供电。

---

## 9. 上电实测更新（2026-09-24，COM6）

> 完整任务编排、判据与原始日志见 `doc/DX-CT511N_测试任务编排.md` 与 `tmp/ct511n_logs/`。
> 被测模块：LYNQ_L511CN_2C，固件 `L511CN_2Cv04.01b01.00`（2025/01/22），IMEI <IMEI>。

| 原待验证项 | 实测结论 |
|---|---|
| 1 模块身份/波特率 | ✅ `ATI/CGMR/CGSN` 正常；`AT+IPR?` = 115200（命令需 CRLF 结束） |
| 2 SIM / 注网 | ✅ CPIN READY、ICCID `<ICCID>`、CEREG=1、COPS 46000、LTE Band40 |
| 3 PPP 拨号 | ❌ `AT+CGDCONT?` 支持且 PDP 已激活（1,1），但 `ATD*99#` **稳定返回 ERROR** → 官方固件未开放 UART PPP，第 7.4 节“情形 A”被否定，只能走情形 B |
| 4 内置 TCP 透传 | ✅ AT 模式与 `CIPMODE=1` 透传都能收发；直连 `china.aprs2.net:14580` 收到 `# aprsc 2.1.19-g730c5c0`，并以 BD4WMA 登录成功（`# logresp BD4WMA verified, server T2NANJING`）、30s 内收到 6 个真实报文。**注意原清单里的 `aprs.dprns.com` 已无法公网解析** |
| 5 GNSS | ✅ 命令链 `AT+MGPSC=1` → `AT+MGPSGET=ALL,1` → `AT+GPSSTEX` → `AT+MGPSC=0` 全部可用；用户确认户外定位正常。**但 NMEA 会同时从 MAIN_UART 以 1Hz 输出**（见下） |
| 6 电平转换与电源 | ⏳ 待硬件测量（任务 M2/M3） |

补充修正：

1. 第 7.3 节“AUX_UART 与通信串口物理隔离”的假设**不成立**：`AT+MGPSGET=ALL,1` 下 MAIN_UART 上同样持续输出 `$GNRMC/$GNGGA/...`；用 `=1,1`/`=UART1,1`/`=AUX,1` 尝试按端口静音均无效，需向厂商确认该指令第一参数的取值域。
2. 第 7.3 节提到的 `strstr` 参数顺序 bug 已复核确认：`src/main.cpp:3869`、`src/main.cpp:6074` 均为 `strstr("AT", config.gnss_at_command)`。
3. 第 7.4 节提到的 `PPP_MODEM_MODEL` 硬编码已复核：`src/main.cpp:80` 与 `:8361` 未使用 `config.ppp_model`。
4. 模块无“查询本机 IP”指令，网络状态只能用 `AT+NETOPEN?`（0/1）判断。
