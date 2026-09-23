# NIR-M-R2 厂家 SDK 分析报告

分析对象：`二次开发资料SDK/`（与 `portable_spectrometer/3-二次开发资料SDK/` 同源）。

分析原则：**协议字段、命令 ID、数据格式全部以厂家 PDF / 头文件 / Demo / 库符号为准**；未在资料中出现的不写死。

---

## 1. SDK 目录结构

```text
二次开发资料SDK/
├── easynirlib二次开发指南-V1.1.pdf          # EasyNIRLib 编程指南（宣称支持 Win/Mac/Linux）
├── 串口通信及指令资料/
│   ├── ISC NIRScan USB and UART Command Description v1.2.pdf   # ★ 协议唯一权威
│   ├── HDD16005_ISC NIR Module UART Connector Link Guide_v0.8.pdf
│   └── ISC_NIRScan_UART_GUI-Qt-v1.3.1/     # Windows Qt GUI + libiscspec.dll
├── SDK for C++/
│   ├── 普通版/V1.1.2-普通版/               # Windows easynirlib.dll/.lib + demo.cpp + easynirwrapper.h
│   ├── 通用版/V1.1.2-通用版/               # Windows 基本类型封装 API
│   └── 普通版和通用版区别.txt
├── SDK for C#/
│   ├── V1.1.3.zip                          # Windows DLL + 头文件
│   └── demo.zip                            # C# P/Invoke Demo
├── SDK for Linux/
│   ├── X64/  libeasynirlib.so.1.1.2 / .a.1.1.2 + demo.c + easynirwrapper.h
│   └── X86/  libeasynirlib.so.1.1.2 + easynirwrapper.h
├── SDK for Linux-ARM-Raspberry Pi/
│   └── X86/  (实际是 ARM 32 .so) + demo.c
├── SDK for Android/1.0.0 | 1.1.0/          # libpynect-lib.so (arm64/armeabi/x86/x86_64) + 用户手册
├── SDK for Labview/                        # labview-demo.zip, V1.1.2.rar
└── SDK for STM32/
    └── stm32f4/
        ├── DLPLIB/EasyNIRWrapper.h
        ├── DLPLIB/libeasynir.a / libeasynird.a   # 含 dlpspec*.o + NIRDriver.o
        ├── USER/test.c                         # 串口 + getFormatSpectrum 示例
        └── HARDWARE/FIFO/…                     # 串口 FIFO 收发
```

**关键事实：整个 SDK 包内没有任何 macOS `.dylib` / `.framework` / Mach-O 库。**

---

## 2. USB 通信方式

| 项目 | 值 | 来源 |
|------|-----|------|
| 传输类 | USB 1.1 **HID**（免驱） | Command Description §2.1；EasyNIRLib 指南「USB 访问」 |
| VID | `0x0451` (Texas Instruments) | Command Description §2.1 |
| PID | `0x4200` | Command Description §2.1 |
| HID packet 最大长度 | **64 bytes** | Command Description §2.1 |
| 字节序 | **LSB first（小端）** | Command Description §2.1 |
| PC 栈 | **hidapi**（`hid_enumerate` / `hid_open` / `hid_write` / `hid_read` / `hid_read_timeout`） | Linux `libeasynirlib.so` 内嵌 `hid.o` 与 `hidapi.h` 符号/字符串 |
| HID 缓冲 | `unsigned char buf[65]; buf[0]=Report ID=0x00; 帧从 buf[1] 开始` | EasyNIRLib 实现惯例 + hidapi numbered report 行为（`uses_numbered_reports`） |

### 2.0 真机实测（macOS hidapi，2025-09）

对序列号 `C36R011` 的 NIR-M-R2 实测结论（**覆盖文档中未写清的部分**）：

| 项目 | 实测值 |
|------|--------|
| HID Report Descriptor | `06 00 FF 0A 00 FF A1 01 15 00 25 FF 75 08 95 40 09 01 81 00 09 02 91 00 09 03 B1 02 C0` |
| Report ID | **无**（descriptor 中无 `0x85`） |
| MaxInput/Output/Feature Report | **均为 64 bytes** |
| Usage Page / Usage | `0xFF00` / `0xFF00`（Vendor） |
| `hid_write(65)`（Report ID + 帧） | 返回成功，**设备无响应** |
| `hid_write(64)`（纯应用帧） | **正常工作** |
| `hid_read` | 64 字节，**无** Report ID 前缀 |

**请求帧（TX，64 bytes，与 Table 2-1 一致）：**

```text
[0]=0x00 Protocol ID
[1] Flags
[2] Sequence
[3] Length LSB   (= Command+Group+Data)
[4] Length MSB
[5] Command
[6] Group
[7...] Data
```

**响应帧（RX，64 bytes，实测紧凑格式 — 与 Table 2-1 不同）：**

```text
[0] Flags
[1] Sequence
[2] Length LSB   (= Data 字节数，不含 Command/Group)
[3] Length MSB
[4...] Data
```

响应 **无** Protocol ID、**无** Command/Group 回显。实例：

- `NNO_CMD_SERIAL_NUMBER_READ` → `C0 00 09 00 43 33 36 52 30 31 31 00 …`  
  Flags=C0, Seq=00, Len=9, Data=`C36R011\0`
- `NNO_CMD_TIVA_VER` → `C0 00 1C 00 03 06 02 00 …`  
  Flags=C0, Seq=01, Len=28, Data=7×uint32
- `NNO_CMD_GET_BOARD_LEVEL` → Data 前 8 字节为 ASCII `F.B.C.A`，随后 mainADC、detectorADC 各 uint32

> 官方 PDF Table 2-1 描述的是对称帧行为；真机 USB 响应为紧凑格式。实现以真机为准，并在 `NIRFrame.decodeHIDRead` 中保留完整帔回退。

### 2.1 HID 应用帧格式（Table 2-1，请求方向）

| Byte | 字段 | 说明 |
|------|------|------|
| 0 | USB Header ID | 固定 `0x00` |
| 1 | Flags | 见下表 |
| 2 | Sequence | 多包时对包编号；单包通常 `0x00` |
| 3 | Length LSB | **Command + Group + Data** 的字节数（**不含** byte 0–4） |
| 4 | Length MSB | 同上，小端 16-bit |
| 5 | Command Byte | 命令 ID |
| 6 | Group Byte | 命令组 |
| 7..N+6 | Data | 载荷 |

`Length = 1 (Command) + 1 (Group) + len(Data)`。

### 2.2 Flags（byte 1）

| Bit | 含义 |
|-----|------|
| 7 | R/W：`0`=Write，`1`=Read |
| 6 | Ready/Reply：主机请求回复时置 `1`；设备 Ready=`1`，Busy=`0` |
| 5:4 | Error：`0`=Success，`1`=Error，`2`=Busy |
| 3:0 | Reserved |

主机常用 Flags：

- Read + 要回复：`0xC0`（`0x80 | 0x40`）
- Write + 要回复：`0x40`

> 注：UART 版 Flags bit6 文档写作 “Reply requested”，USB 版 Table 2-1 写作 “Ready (0=Busy, 1=Ready)”。主机发起命令时按 UART 示例与 EasyNIRLib 习惯 **bit6=1 表示期望回复**。响应侧 bit5:4 才是 error/busy。

### 2.3 Request / Response 对应

- 主机带 Sequence 的包，设备回包 **Sequence 应与请求匹配**（USB Read Transaction Sequence §2.1.1.1）。
- Write 且 Flags.bit6=1 时，设备至少回命令字节确认；未知命令/参数错误时 Error 位置位（NACK）。
- Read 成功时回包含：匹配 Sequence、Length、Command/Group 回显、Data。

### 2.4 多包传输

- 单命令 > 64 bytes 时，拆成多个 USB packet，用 **Sequence 对包编号**，设备按序组装（§2.1.1.1 steps 3）。
- `NNO_CMD_FILE_GET_DATA` 的 **响应** 载荷可远大于 64 bytes（UART 示例 Length=0x0200）。USB 上必须多次 `hid_read` 组装。
- **文档未给出 USB continuation 的逐字节布局**（是否每包都带 7 字节头、Sequence 如何递增）。厂家 Linux 库用 hidapi 自行处理。实现时：dump 每包 raw，按 “去掉帧头后拼接，直到凑满 FILE_GET_READSIZE 字节数” 策略重组；若真机不符，对照 log 调整，**禁止静默发明偏移**。

### 2.5 Timeout

- 协议 PDF **未规定** USB timeout 数值。
- Linux 库使用 `hid_read_timeout`（符号存在）。
- EasyNIRLib 有 `getEstimatedScanTime()`（命令 `NNO_CMD_READ_SCAN_TIME`），扫描完成轮询应以此为超时基准，另加传输余量。
- STM32 示例 IORead 用 `delay_ms(30)` 轮询 FIFO，说明设备响应非瞬时。
- 建议：普通命令 1–2 s；扫描超时 = `estimated_ms + 传输余量`。

### 2.6 接口优先级

UART > Bluetooth > USB（Command Description §1.2）。  
（EasyNIRLib 指南另写 “USB > 串口> 蓝牙”，与协议 PDF **矛盾**。**以 Command Description 为准**。）  
测 USB 时不要让 UART 命令口有主机在发包。

---

## 3. 命令列表（与扫描 / Device Info 相关）

权威：Command Description Table 1-1 / Table 2-2。Group/Command 均为十六进制。

### 3.1 File 组 `0x00`

| 名称 | R/W | Cmd | 入参 | 出参 |
|------|-----|-----|------|------|
| `NNO_CMD_FILE_GET_READSIZE` | READ | `0x2D` | 1: File type | 4: size (uint32 LE) |
| `NNO_CMD_FILE_GET_DATA` | READ | `0x2E` | 0 | Variable: 文件内容 |
| `NNO_CMD_FILE_SET_WRITESIZE` | WRITE | `0x2A` | 6 | 0 |
| `NNO_CMD_FILE_WRITE_DATA` | WRITE | `0x25` | Variable | 0 |
| `NNO_CMD_READ_FILE_LIST_SIZE` | READ | `0x2B` | 1: type | 4 |
| `NNO_CMD_READ_FILE_LIST` | READ | `0x2C` | 1: type | Variable |

### 3.2 System 组 `0x02`（Device Info / Scan 主路径）

| 名称 | R/W | Cmd | 入参 | 出参 |
|------|-----|-----|------|------|
| `NNO_CMD_TIVA_VER` | READ | `0x16` | 0 | **28** = 7×uint32 LE |
| `NNO_CMD_PERFORM_SCAN` | WRITE | `0x18` | 1: scan flag | 0 |
| `NNO_CMD_SCAN_GET_STATUS` | READ | `0x19` | 0 | 1: 0=in progress, 1=complete |
| `NNO_CMD_TIVA_RESET` | WRITE | `0x1A` | 0 | 0 |
| `NNO_CMD_SET_PGA` | WRITE | `0x1B` | 1: PGA | 0 |
| `NNO_CMD_SCAN_CFG_APPLY` | WRITE | `0x1E` | Variable: serialized scanConfig | 4: number of patterns |
| `NNO_CMD_SCAN_CFG_READ` | READ | `0x20` | 1: index | Variable |
| `NNO_CMD_SCAN_CFG_NUM` | READ | `0x22` | 0 | 1 |
| `NNO_CMD_SCAN_GET_ACT_CFG` | READ | `0x23` | 0 | 1: index |
| `NNO_CMD_SCAN_SET_ACT_CFG` | WRITE | `0x24` | 1: index | 4: patterns |
| `NNO_CMD_SET_DLPC_ONOFF_CTRL` | WRITE | `0x25` | 1 | 0 |
| `NNO_CMD_GET_PGA` | READ | `0x28` | 0 | 1 |
| `NNO_CMD_SCAN_NUM_REPEATS` | WRITE | `0x2E` | 2 | 0 |
| `NNO_CMD_SERIAL_NUMBER_READ` | READ | `0x33` | 0 | **8** |
| `NNO_CMD_READ_SCAN_TIME` | READ | `0x37` | 0 | **4** = uint32 ms LE |
| `NNO_CMD_MODEL_NAME_WRITE` | WRITE | `0x3B` | （表内 in/out 标注疑似对调） | |
| `NNO_CMD_MODEL_NAME_READ` | READ | `0x3C` | （表内标注疑似对调，**优先用 0x03/0xFD**） | |
| `NNO_CMD_READ_LAMP_USAGE` | READ | `0x80` | 0 | 8 |

### 3.3 Sensor 组 `0x03`

| 名称 | R/W | Cmd | 入参 | 出参 |
|------|-----|-----|------|------|
| `NNO_CMD_READ_TEMP` | READ | `0x00` | 0 | 8：ambient + detector，单位 0.01 °C |
| `NNO_CMD_READ_HUM` | READ | `0x02` | 0 | 8：HDC temp + humidity %，0.01 |
| `NNO_CMD_READ_MODEL_NAME` | READ | `0xFD` | 0 | **16** model name |
| `NNO_CMD_GET_BOARD_LEVEL` | READ | `0xFE` | 0 | **16** HW 版本 X.X.X.X + ADC |
| `NNO_CMD_READ_FLASH_UID` | READ | `0xFF` | 0 | 8 |

### 3.4 Status 组 `0x04`

| 名称 | R/W | Cmd | 入参 | 出参 |
|------|-----|-----|------|------|
| `NNO_CMD_READ_DEVICE_STATUS` | READ | `0x03` | 0 | **4** Device status bits |
| `NNO_CMD_READ_ERROR_STATUS` | READ | `0x04` | 0 | **24** error status + codes |
| `NNO_CMD_RESET_ERROR_STATUS` | WRITE | `0x05` | 0 | 0 |
| `NNO_CMD_SET_FIXED_PGA` | WRITE | `0x0C` | 2: isFixed, PGA | 0 |

### 3.5 GET_VERSION 载荷（28 bytes = 7 × uint32 LE）

```
[0] Tiva SW version
[1] DLPC SW version
[2] DLPC flash version
[3] ISC spectrum library version
[4] Calibration coefficients version
[5] Reference calibration version
[6] Scan configuration version
```

与 `easynirwrapper.h` 的 `getVersions(...7 个 unsigned int*)` 一一对应。

### 3.6 Device Status 位（Appendix A.1）

| Bit / Value | 含义 |
|-------------|------|
| 1 | Tiva Active |
| 2 | Scan In Progress |
| 4 | SD Card Present |
| 8 | SD Card I/O |
| 16 | Bluetooth Active |
| 32 | Bluetooth Connected |
| 64 | Scan Interpretation In Progress |
| 128 | Scan Button Pressed |
| 256 | Battery In Charge |

### 3.7 PERFORM_SCAN 载荷（**文档内部不一致，已核实**）

| 来源 | 含义 |
|------|------|
| Table 1-1 / 2-2 | “Store in SD: 0 = do not store, 1 = store” |
| UART 示例 §3.3.6 Table 3-10 | **`0x00` = Complete Scan Data；`0x5A` = Simplex Scan Data** |

§3.3.6 正文明确写：

> If the user wants to get the complete scan data, send the scan flag as **0x00**. If the user wants to get the simplex scan data, send the scan flag as **0x5A**.

EasyNIRLib `getFormattedSpectrum(double *wl, unsigned int *intensity)` 返回已解释光谱，与 **Simplex（设备端已解释）** 路径一致。

**本项目约定：**

- `0x00` → `NNO_FILE_SCAN_DATA`（serialized，需 `dlpspec_scan_interpret`）
- `0x5A` → Simplex（`NNO_FILE_SIMPLEX_SCAN_WAVELENGTH` `0x0C` + `NNO_FILE_SIMPLEX_SCAN_INTENSITY` `0x0D`）
- Simplex 需要 **Tiva ≥ v2.5.0**（§3.3.1）

### 3.8 File Type（Table 3-12 注释 + Table 1-1）

| 名称 | 值 |
|------|----|
| `NNO_FILE_SCAN_DATA` | `0x00` |
| `NNO_FILE_SCAN_CONFIG` | `0x01` |
| `NNO_FILE_REF_CAL_DATA` | `0x02` |
| `NNO_FILE_REF_CAL_MATRIX` | `0x03` |
| `NNO_FILE_HADSNR_DATA` | `0x05` |
| `NNO_FILE_SCAN_CONFIG_LIST` | `0x06` |
| `NNO_FILE_SCAN_LIST` | `0x07` |
| `NNO_FILE_SCAN_DATA_FROM_SD` | `0x08` |
| `NNO_FILE_INTERPRET_DATA` | `0x09` |
| `NNO_FILE_SIMPLEX_SCAN_WAVELENGTH` | `0x0C` |
| `NNO_FILE_SIMPLEX_SCAN_INTENSITY` | `0x0D` |

（Table 1-1 另列 lamp ADC 等 factory 文件类型，本项目不用。）

---

## 4. 完整扫描流程（以协议 §1.4.1 + UART 示例为准）

```text
Open HID (VID 0451 / PID 4200)
    ↓
(可选) SET_DATE_TIME 同步时间 — 设备无内置时钟，用于扫描元数据
(可选) TIVA_VER 读固件版本；Simplex 要求 Tiva ≥ 2.5.0
    ↓
【1. Scan Configuration】二选一：
   (a) SCAN_CFG_APPLY  ← 发送 dlpspec_scan_write_configuration() 序列化的 scanConfig
   (b) SCAN_SET_ACT_CFG ← 选用 EEPROM 内已存配置（index）
    → 设备生成 patterns 存入外部 SDRAM
    ↓
【2. Perform Scan】
   (a) 可选 SCAN_NUM_REPEATS 覆盖重复次数
   (b) SET_FIXED_PGA：Auto: isFixed=1,PGA=0；Fixed: isFixed=1,PGA=1/2/…/64
   (c) 灯控：默认 Auto（扫描内开关）；或 SET_DLPC_ONOFF_CTRL + DLPC_ENABLE 手动
       Auto 时 WRITE_LAMP_DELAY 至少 625 ms
   (d) READ_SCAN_TIME → estimated_ms（作为轮询超时基准，不含传输时间）
   (e) PERFORM_SCAN flag=0x00 或 0x5A
   (f) 轮询 SCAN_GET_STATUS 或 READ_DEVICE_STATUS（bit1 = SCAN_IN_PROGRESS）
       直到 complete
    ↓
【3. Acquire Scan Data】
   FILE_GET_READSIZE(file_type) → size
   FILE_GET_DATA → 重复读直到收满 size
    ↓
【4. Interpret】
   A) Complete (0x00)：NNO_FILE_SCAN_DATA 为 serialized scan data
      必须 dlpspec_scan_interpret() / IscSpec_InterpretScanData()
      → scanResults{ wavelength[], intensity[], temperature, humidity, … }
   B) Simplex (0x5A)：Tiva 已解释
      FILE type 0x0C → wavelength
      FILE type 0x0D → intensity
      分别读取，**无需** dlpspec
```

### Device Info 最小命令集（本阶段 CLI `info`）

1. `enumerate` HID  
2. `open`  
3. `NNO_CMD_SERIAL_NUMBER_READ` (0x02/0x33) → 8 bytes  
4. `NNO_CMD_TIVA_VER` (0x02/0x16) → 28 bytes  
5. `NNO_CMD_READ_DEVICE_STATUS` (0x04/0x03) → 4 bytes  
6. `NNO_CMD_GET_BOARD_LEVEL` (0x03/0xFE) → 16 bytes（Hardware Version）  
7. `NNO_CMD_READ_MODEL_NAME` (0x03/0xFD) → 16 bytes  

这些命令 ID 与载荷长度全部来自 Table 1-1 / 2-2，无猜测。

---

## 5. 光谱数据解析流程

### 5.1 USB 拿到的是什么？

| PERFORM_SCAN flag | 读取文件 | 内容 | 是否已是 wavelength+intensity |
|-------------------|----------|------|--------------------------------|
| `0x00` | `NNO_FILE_SCAN_DATA` (0x00) | **Serialized scan data**（含 header、scanConfig、原始数据…） | **否**，必须 interpret |
| `0x5A` | `0x0C` + `0x0D` | wavelength 文件 + intensity 文件 | **是**（Tiva 已解释） |

§3.3.7 原文：

> The complete scan data is a larger data which includes header data, scan configuration, wavelength, and intensity. After the complete scan data is completely collected, it must be de-serialized… The ISC spectrum library provides a function (**IscSpec_InterpretScanData()**)…  
> The **simplex** scan data only includes wavelength and intensity… These data **has interpreted in Tiva**.

### 5.2 解析函数与是否有源码

| 函数 | 作用 | 源码？ | 库形态 |
|------|------|--------|--------|
| `dlpspec_scan_interpret` | Complete scan → scanResults | **无 .c 源码** | 嵌在 `libeasynirlib.a/.so`、`libeasynir.a`、Windows DLL 内的 **目标文件** |
| `IscSpec_InterpretScanData` | ISC 封装的 interpret | **无源码** | `libiscspec.dll`（Win32）、Android `libpynect-lib.so` |
| `getFormattedSpectrum` | 高层 API，内部完成 scan+读+解释 | 仅头文件声明 | 同上各平台二进制 |
| `dlpspec_scan_write_configuration` / `read_configuration` | 序列化 scanConfig | 无源码 | 同上 |
| `dlpspec_util_columnToNm` 等 | 波长映射 | 无源码 | 同上 |

Linux `libeasynirlib.a.1.1.2` 成员：`dlpspec.o`, `dlpspec_calib.o`, `dlpspec_scan.o`, `dlpspec_util.o`, `tpl.o`, `hid.o`, `usb.o`, …  
STM32 `libeasynir.a` 成员：`NIRDriver.o`, `tpl.o`, `dlpspec_*.o`。  
`nm` 可见 `dlpspec_scan_interpret`、`dlpspec_deserialize` 等 **T 符号**，但是：

- Linux `.o` = **ELF x86-64**
- STM32 `.a` = **ARM Cortex-M (GCC)**
- Android `.so` = **ELF aarch64 / armv7 / x86**
- Windows = **PE DLL**

**没有 macOS Mach-O / arm64 dylib，无法在 macOS 上直接链接。**

### 5.3 Simplex 元素类型（谨慎结论）

- EasyNIRLib 对外：`double *pWavelength` + `unsigned int *pData`（或通用版 `int *pData`）。
- 协议 PDF **未写明** Simplex 文件在 USB 上的元素宽度。
- 先前 ESP32 PoC 以 **float32 LE 波长 / int32 LE 强度** 解析并做范围校验；**尚未在真机日志确认**。
- 映射到 Swift 模型时：`intensity` 用整数（与 SDK 一致），`wavelength` 用 `Double` 承载；底层 raw 类型待真机确认后再锁定。

### 5.4 样例规模

UART 示例 complete scan size = **3822 bytes**；`SCAN_CFG_APPLY` 响应 patterns = **228**。  
PC CSV 样例曾见 228 点，与 patterns 数一致。

---

## 6. macOS 可直接复用的代码

| 资产 | 可复用性 |
|------|----------|
| Command Description PDF 全部命令表 | **完全可复用**（协议实现唯一依据） |
| `easynirwrapper.h` API 形状 | 可复用作高层 API 设计参考 |
| Linux/C++ `demo.c` 调用顺序 | 可复用（enumerate → open → serial → versions → scan） |
| STM32 `getFormatSpectrum(activeIndex, isFixed, gain, repeats, …)` | 参数语义可复用 |
| hidapi 用法（Linux .so 内） | **推荐** macOS 也用 hidapi（与厂家 PC 路径一致） |
| `portable_spectrometer/nir_esp32_poc` 的 `nir_defs.h` / `nir_protocol.c` / `nir_device.c` | **协议常量、帧编解码、Simplex 文件读取策略可移植**（去掉 ESP-IDF 依赖） |

**不可直接链接：** 任何 `easynirlib` / `libeasynir` / `libiscspec` / `libpynect-lib` 二进制。

---

## 7. Windows / Linux 专属代码

| 平台 | 专属内容 |
|------|----------|
| Windows | `easynirlib.dll/.lib`（x86/x64 Debug/Release）、C# P/Invoke、LabVIEW、`libiscspec.dll`（Qt GUI 用）、COM |
| Linux x86/x64 | `libeasynirlib.so/.a`，依赖 **libudev + libusb-1.0**，需 root；`hidraw` |
| Linux ARM (RPi) | 32-bit `libeasynirlib.so` |
| Android | `libpynect-lib.so` + JNI，含 `dlpSpecScan*` |
| STM32 | `libeasynir.a` + UART FIFO + `registerDataSrc` 回调 |
| **macOS** | **无任何二进制**；指南宣称 “OSX 10.5 or later / Mac 有 *.dylib*”，**但压缩包未提供** |

---

## 8. 当前缺失的依赖

1. **macOS `libeasynirlib.dylib`（arm64/x86_64）** — 文档宣称支持 Mac，包内没有。  
2. **`dlpspec_*` / `IscSpec_*` 源码** — 仅有 ELF/PE/ARM 目标文件，无 `.c/.h` 实现。  
3. **USB 多包 FILE_GET_DATA 的 continuation 字节级说明** — PDF 只展示 UART 大包示例。  
4. **Simplex 文件元素类型官方说明**（float32? double? int32? uint16?）。  
5. **官方 USB timeout / retry 推荐值**。  
6. 真机 USB 抓包或厂家 Mac 库日志（用于最终确认 Report ID 与多包布局）。

---

## 9. macOS 实现风险点

| 风险 | 等级 | 缓解 |
|------|------|------|
| 无 Mac 库，complete 路径无法 interpret | **高** | 第一阶段用 **Simplex `0x5A`** 得到设备端 wavelength+intensity；raw complete 先存 `.bin` |
| HID Report ID / 64 vs 65 | 中 | hidapi `buf[0]=0` + 65 字节；若失败试 64；log raw |
| FILE_GET_DATA 多包布局未完全定义 | 中 | dump 每包，按 size 拼 body；真机校正 |
| PERFORM_SCAN flag 文档冲突 | 中 | 实现两种 flag，CLI 可选；默认 `0x5A` |
| Simplex 元素类型未官方确认 | 中 | 解析后打印 size/首尾/范围；异常则保留 `.bin` |
| Tiva < 2.5.0 无 Simplex | 中 | 先 `TIVA_VER`；过旧则提示用 complete+外部 interpret |
| 接口优先级 PDF 与指南矛盾 | 低 | 以 Command Description 为准（UART 最高） |
| hidapi 与系统 HID 权限 | 低 | brew hidapi；必要时用户态授权 |
| Intel Mac | 低 | 协议与 hidapi 同源；arm64 优先，x86_64 可交叉/通用二进制 |

---

## 10. 结论与实现路线

1. **不要链接厂家 EasyNIRLib 二进制**（无 Mac 架构）。  
2. **USB HID 协议完全公开**，用 hidapi 自研 `HIDTransport` + `NIRProtocol` 是正确路径。  
3. **Device Info 阶段零依赖解释库**：Serial / Versions / Status / HW / Model 全部走明文命令。  
4. **Scan 阶段**：  
   - 首选 Simplex `0x5A` + FILE `0x0C`/`0x0D` → 直接得到光谱（不伪造波长）；  
   - Complete `0x00` raw 存 `.bin`，待获取 `dlpspec` 源码或厂家 Mac 库后再 interpret。  
5. 若必须 complete 路径在 Mac 解释：向厂家索取 **macOS dylib** 或 **dlpspec/ISC spectrum 源码**；或对照 TI DLP NIRscan Nano 公开的 `dlpspec` 结构做合法移植（需单独评估，不在本阶段做）。

---

## 11. 参考文件索引

| 内容 | 路径 |
|------|------|
| 协议权威 | `二次开发资料SDK/串口通信及指令资料/ISC NIRScan USB and UART Command Description v1.2.pdf` |
| EasyNIRLib API | `…/easynirlib二次开发指南-V1.1.pdf`，`SDK for Linux/X64/easynirwrapper.h` |
| Linux Demo | `SDK for Linux/X64/demo.c` |
| STM32 Demo | `SDK for STM32/stm32f4/USER/test.c`，`DLPLIB/EasyNIRWrapper.h` |
| 已整理协议常量 | `portable_spectrometer/nir_esp32_poc/docs/PROTOCOL.md`，`…/nir_defs.h` |
