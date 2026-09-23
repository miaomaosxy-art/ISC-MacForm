# NIR-M-R2 macOS 控制软件

通过 **USB HID** 控制 InnoSpectra / Pynect **NIR-M-R2** 近红外光谱仪（TI DLP NIRscan Nano 命令集兼容）的 macOS 原生工具。

```text
Mac (Swift / SwiftUI)
  → HIDTransport (hidapi)
  → NIRProtocol  (HID 帧)
  → NIRDevice    (actor)
  → DLPSpectrumDecoder (DLP Spectrum Library 2.0.3)
  → Spectrum → CSV / Chart
  → NIR-M-R2 (USB HID)
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
PERFORM_SCAN(0x00) → FILE_GET_DATA → scan_complete.bin
→ dlpspec_scan_interpret() → Spectrum → scan.csv
```

## GUI

```bash
swift run NIRMacApp
```

第一版：设备检测、连接状态、Serial/Firmware/Config、Start Scan、进度、Charts 光谱曲线、温湿度/PGA、Save CSV、Clear。

## 已实现

- [x] USB HID 枚举 / 打开 / 通信（实测 64B 无 Report ID）
- [x] Device Info（Serial / Model / HW / Status / Versions）
- [x] Complete scan + 多块 `FILE_GET_DATA`
- [x] DLP Spectrum Library **2.0.3** 解码（arm64）
- [x] wavelength / intensity CSV（含 metadata 注释）
- [x] 光谱 sanity check
- [x] `nir-cli scan` 一键出 CSV
- [x] SwiftUI GUI v1

## 已测设备（示例，非保证）

| 项目 | 值 |
|------|-----|
| 设备 | NIR-M-R2 `C36R011` |
| 固件 | Tiva 2.6.3 |
| 扫描配置 | Hadamard 1 |
| 点数 | 228 |
| 范围 | ~901.8–1701.2 nm |

其他设备 / 配置的点数与范围可能不同。

## CSV 格式

```csv
# serial=C36R011
# config=Hadamard 1
# temperature_c=35.98
# humidity_percent=35.72
# pga=64
# points=228
# timestamp=...
wavelength_nm,intensity
901.816,22060
...
```

## 分层

```text
Sources/
├── HIDTransport/     # hidapi 传输
├── NIRProtocol/      # 帧 / 常量 / 错误
├── NIRDevice/        # 设备 actor、Spectrum 模型
├── CDLPSpec/         # C bridge + vendor dlpspec 编译单元
├── DLPSpec/          # DLPSpectrumDecoder（Swift）
├── nir-cli/          # 命令行
└── NIRMacApp/        # SwiftUI
```

## 许可证

- 本项目代码：见仓库
- DLP Spectrum Library：Texas Instruments SLA（`third_party/DLPSpectrumLibrary/DLP_Spectrum_Library_SLA.rtf`）— **源码不进入公开 git**；对外分发二进制前请自行审核再分发条款

## 已知限制

- Intel Mac：未做通用二进制打包
- Simplex `0x0C/0x0D` 在本固件为空，非主路径
- USB 热插拔为 1 s 轮询（非 IOHIDManager 通知）
