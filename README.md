# NIR-M-R2 macOS 控制软件

通过 **USB HID** 控制 InnoSpectra / Pynect **NIR-M-R2** 近红外光谱仪（兼容 TI DLP NIRscan Nano 命令集）的 macOS 原生工具。

```text
Mac (Swift)
  → HIDTransport (hidapi)
  → NIRProtocol  (HID 应用帧编解码)
  → NIRDevice    (设备 actor / 串行化访问)
  → NIR-M-R2 (USB HID)
```

## 系统要求

- macOS 13+（优先 Apple Silicon `arm64`）
- Swift 5.9+ / Xcode 命令行工具
- [hidapi](https://github.com/libusb/hidapi)

```bash
brew install hidapi
```

## 支持设备

| 型号 | USB VID | PID | 传输 |
|------|---------|-----|------|
| NIR-M-R2（及同命令集 ISC NIRScan 模块） | `0x0451` | `0x4200` | USB HID |

## 编译

```bash
cd nir-m-r2-macos
swift build
```

产物：`.build/debug/nir-cli`

## CLI 用法

```bash
# 枚举 NIR-M-R2（VID 0451 / PID 4200）
swift run nir-cli list

# 列出系统全部 HID 设备（排查识别问题）
swift run nir-cli list --all

# 打开第一台设备并读取 Device Info
swift run nir-cli info

# 调试：打印 TX/RX HID hex dump 与协议日志
swift run nir-cli info --debug
```

### `info` 输出字段

全部来自厂家协议 Command Description Table 1-1 / 2-2：

| 字段 | 命令 |
|------|------|
| Serial Number | `NNO_CMD_SERIAL_NUMBER_READ` `0x02/0x33` |
| Model Name | `NNO_CMD_READ_MODEL_NAME` `0x03/0xFD` |
| Hardware Version | `NNO_CMD_GET_BOARD_LEVEL` `0x03/0xFE` |
| Device Status | `NNO_CMD_READ_DEVICE_STATUS` `0x04/0x03` |
| Tiva / DLPC / Spectrum Lib / Cal 版本 | `NNO_CMD_TIVA_VER` `0x02/0x16` |

## 已实现功能（第一阶段 + 扫描）

- [x] USB HID 枚举（VID/PID 过滤，并打印实际值）
- [x] 打开 / 关闭设备（hidapi，64 字节无 Report ID）
- [x] HID 请求帧编解码 + 实测紧凑响应帧
- [x] Device Info：Serial、Model、HW、Status、7 项版本号（真机 C36R011 / Tiva 2.6.3）
- [x] `nir-cli scan`：PERFORM_SCAN → 状态轮询 → FILE 多块读取
- [x] 完整保存 `NNO_FILE_SCAN_DATA`（3822 B）与 `NNO_FILE_INTERPRET_DATA`（1024 B）
- [x] 协议常量集中管理、Debug TX/RX、分层架构、`Spectrum` 模型

## 尚未实现 / 当前限制

- **SwiftUI GUI**
- **`scan.csv` 波长-强度**：当前设备扫描配置为 **Hadamard 1**（见 `scan_complete.bin` 内嵌名）。
  - Simplex 文件 `0x0C`/`0x0D` 在本固件返回空
  - `scan_complete.bin` 为 dlpspec 序列化格式（`tpl` magic），需 `dlpspec_scan_interpret`
  - `scan_interpret.bin` 为设备端解释结果，**布局尚未官方确认**，拒绝伪造 `wavelength_nm`
- 完整光谱 CSV 需要：厂家 macOS 库 / dlpspec 源码，或确认 INTERPRET_DATA 布局

## 真机扫描结果（C36R011）

```text
Mode              : complete+interpret
Complete scan raw : 3822 bytes  → scan_complete.bin
Interpret raw     : 1024 bytes  → scan_interpret.bin
```

## SDK 依赖说明

| 依赖 | 状态 |
|------|------|
| 厂家 EasyNIRLib（Win/Linux/Android/STM32） | **不链接**（无 macOS 架构） |
| 协议 Command Description v1.2 | **已完整解析**，见 `docs/sdk-analysis.md` |
| hidapi | **使用**（与厂家 PC 栈一致） |
| dlpspec / IscSpec 源码 | **缺失**（complete 路径解释所需） |

## 光谱解析方式

| 扫描模式 | 数据来源 | macOS 解析 |
|----------|----------|------------|
| Simplex `0x5A` | FILE `0x0C` + `0x0D` | 自研解析（类型待真机确认，带范围校验） |
| Complete `0x00` | FILE `0x00` serialized | **无法解释** — 保存 `.bin`，不伪造光谱 |

## 项目结构

```text
nir-m-r2-macos/
├── Package.swift
├── README.md
├── docs/
│   └── sdk-analysis.md      # 厂家 SDK 完整分析（协议权威摘录）
└── Sources/
    ├── Chidapi/             # hidapi system module
    ├── HIDTransport/        # USB HID 枚举/开关/读写 + 协议客户端
    ├── NIRProtocol/         # 常量、帧编解码、错误类型
    ├── NIRDevice/           # 设备 actor、Spectrum 模型
    └── nir-cli/             # 命令行入口
```

## 通信协议摘要

- USB HID，64-byte 应用帧，小端
- 帧：`[ID=0][Flags][Seq][LenL][LenH][Command][Group][Data…]`
- Length = Command+Group+Data（不含前 5 字节）
- 主机 Flags：Read+Reply `0xC0`，Write+Reply `0x40`
- hidapi 写缓冲 65 字节：`[Report ID=0][64-byte 帧]`

完整命令表、扫描流程、风险点见 **[docs/sdk-analysis.md](docs/sdk-analysis.md)**。

## 已知问题

1. **无 macOS 厂家动态库** — complete 路径解释被阻塞（设计如此，不绕过）。
2. hidapi Homebrew bottle 可能提示 “built for newer version” 链接警告，不影响功能。
3. 真机首次联调建议使用 `nir-cli info --debug`，对照 `docs/sdk-analysis.md` §2.4 核对 Report ID 与多包布局。

## 下一步

1. 真机验证 `list` / `info`
2. 实现 `nir-cli scan`（Simplex `0x5A` + FILE `0x0C`/`0x0D`）→ `scan.csv`
3. Complete raw `.bin` 保存
4. SwiftUI GUI（连接状态 / 扫描设置 / 光谱图 / Save CSV）
