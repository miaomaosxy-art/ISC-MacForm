# MacForm — NIR-M-R2 macOS Desktop Acquisition Tool

**NIR-M-R2 macOS Desktop Acquisition / Diagnostic / Reference Tool**

通过 **USB HID** 控制 InnoSpectra / Pynect **NIR-M-R2** 近红外光谱仪（TI DLP NIRscan Nano 命令集兼容）的 macOS 原生工具。

```text
NIR-M-R2
   ↓ USB HID
MacForm
   ↓
设备控制 · 扫描 · 光谱显示 · 数据保存 · 调试/验证
```

The project is independent from the ESP32 portable spectrometer project.

MacForm does not perform cloud inference or model prediction.
It also serves as a verified reference implementation for future ESP32-S3
NIR-M-R2 USB Host driver development.

Protocol and live findings: [docs/nir-m-r2-driver-reference.md](docs/nir-m-r2-driver-reference.md)

```text
SwiftUI Views
      ↓
SpectrometerController
      ↓
NIRDevice actor
      ↓
NIRProtocol
      ↓
HIDTransport
      ↓
DLPSpectrumDecoder (DLP Spectrum Library 2.0.3)
```

## 系统要求

- macOS 13+（优先 Apple Silicon `arm64`）
- Swift 5.9+ / Xcode CLT
- `brew install hidapi`
- **DLP Spectrum Library 2.0.3 源码**（见 [third_party/THIRD_PARTY.md](third_party/THIRD_PARTY.md)）  
  放入 `third_party/DLPSpectrumLibrary/`（gitignore，不提交公开仓库）

## 支持设备

| 型号 | USB VID | PID | 传输 |
|------|---------|-----|------|
| NIR-M-R2 | `0x0451` | `0x4200` | USB HID（64 字节，无 Report ID） |

## 构建

```bash
brew install hidapi
# 将 dlpspec/tpl 源码放入 third_party/DLPSpectrumLibrary/
swift build
swift test    # Golden Test Vector
```

缺少 DLP 源码时会明确提示，而不是刷一屏编译错误。

## CLI

```bash
swift run nir-cli list
swift run nir-cli info
swift run nir-cli scan --out scan.csv    # 扫描 → 解释 → CSV
swift run nir-cli interpret scan_complete.bin --out scan.csv  # 离线诊断
```

`scan` 主路径：

```text
PERFORM_SCAN(0x00) → FILE_GET_DATA (multi-chunk) → complete raw
→ dlpspec_scan_interpret() → Spectrum → CSV
```

## GUI

```bash
swift run NIRMacApp
```

主界面：

- 连接状态（Disconnected / Connecting / Connected / Reconnecting）
- Device：Serial / Firmware / Model
- Configuration：Name / Type / Range / Patterns / Repeats / Width / Active index
- Environment：Temperature / Humidity / PGA
- Spectrum 图表（自动波长范围；Repeat 后可切换 individual / average）
- `Scan` / `Repeat Scan`（1 / 3 / 5 / 10，串行）/ `Save CSV` / `Save Session`
- 可选 `Save Raw Scan Data`、`Debug Logging`

扫描状态机：`Idle → Starting → Scanning → ReadingData → Decoding → Completed`，异常 `→ Failed → Idle`。

热插拔：1 s 轮询 VID `0x0451` / PID `0x4200`，自动发现 / 连接 / 断开 / 重连。

## 已实现

- [x] USB HID communication
- [x] Device information
- [x] Hot plug / reconnect
- [x] Complete scan acquisition
- [x] Multi-chunk `FILE_GET_DATA`
- [x] DLP Spectrum Library **2.0.3** decode
- [x] Real wavelength / intensity spectrum
- [x] Single scan
- [x] Repeat scan（串行，`Scanning i / N`）
- [x] Average spectrum（波长轴一致才允许）
- [x] SwiftUI spectrum viewer
- [x] CSV export（自动文件名 `C36R011_YYYYMMDD_HHMMSS.csv`）
- [x] Session save（`NIR_<serial>_<ts>/scan_001.csv…average.csv`）
- [x] Optional raw `.bin` export
- [x] Scan config 信息（仅协议 / serialized config 中真实字段）
- [x] Basic diagnostics + Debug Logging
- [x] Driver reference documentation
- [x] Golden Test Vector

## 已测设备（示例，非保证）

| 项目 | 值 |
|------|-----|
| 设备 | NIR-M-R2 `C36R011` |
| 固件 | Tiva 2.6.3 |
| 扫描配置 | Hadamard 1 |
| 点数 | 228 |
| 范围 | 901.816 – 1701.175 nm |
| Raw | 3822 B |
| 波长轴一致性 | \|Δwl\| = 0.000000 nm（同配置 ×5） |

其他设备 / 配置的点数与范围可能不同。**不要把这些数值写死到其他配置。**

## Golden Test

```bash
swift test
```

Fixture：

```text
Tests/NIRMacTests/Fixtures/scan_hadamard1_C36R011.bin   # 3822 B live complete scan
```

期望：

```text
dlpspec PASS · 228 points · 901.816 – 1701.175 nm (± 1e-3)
```

该 raw 为真机采集数据（非 TI 专有源码），可提交用于回归。
TI DLP Spectrum Library 源码仍不进入公开 git。

## CSV 格式

```csv
# serial=C36R011
# config=Hadamard 1
# temperature_c=35.98
# humidity_percent=35.72
# pga=64
# points=228
# timestamp=...
# scan_type=Hadamard
wavelength_nm,intensity
901.816,1522
...
```

每次 scan 使用自己的温湿度 metadata。

## Session 目录

```text
NIR_C36R011_20260923_143012/
├── scan_001.csv
├── scan_002.csv
├── ...
└── average.csv
```

开启 `Save Raw Scan Data` 时额外生成 `scan_001.bin` 等。

## 分层

```text
Sources/
├── HIDTransport/     # hidapi 传输
├── NIRProtocol/      # 帧 / 常量 / 错误 / DebugLog
├── NIRDevice/        # 设备 actor、Spectrum、平均谱、文件名
├── CDLPSpec/         # C bridge + vendor dlpspec 编译单元
├── DLPSpec/          # DLPSpectrumDecoder（Swift）
├── nir-cli/          # 命令行
└── NIRMacApp/        # SwiftUI（SpectrometerController + Views）
```

## 不在范围内

MacForm **不做**：BLE、ESP32 通信、微信小程序、云服务器、模型预测（PLSR/SVR 等）、
用户系统、数据库、黄芪业务逻辑。这些属于其他项目。

## 许可证

- 本项目代码：见仓库
- DLP Spectrum Library：Texas Instruments SLA（`third_party/DLPSpectrumLibrary/DLP_Spectrum_Library_SLA.rtf`）— **源码不进入公开 git**；对外分发二进制前请自行审核再分发条款

## 已知限制

- Intel Mac：未做通用二进制打包
- Simplex `0x0C/0x0D` 在本固件为空，非主路径
- USB 热插拔为 1 s 轮询（非 IOHIDManager 通知）
