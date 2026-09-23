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

## 已实现功能（第一阶段）

- [x] USB HID 枚举（VID/PID 过滤，并打印实际值）
- [x] 打开 / 关闭设备（hidapi）
- [x] HID 应用帧编解码（ID / Flags / Sequence / Length / Command / Group / Data）
- [x] Sequence / 错误标志校验
- [x] Device Info：Serial、Model、HW、Status、7 项版本号
- [x] 协议常量集中管理（无 magic number）
- [x] Debug 模式 TX/RX hex dump
- [x] 分层：`HIDTransport` / `NIRProtocol` / `NIRDevice`
- [x] `Spectrum` / `SpectrumPoint` 数据模型（供后续 GUI）
- [x] 扫描相关命令骨架（scan config / perform / status / file read）

## 尚未实现 / 当前限制

- **SwiftUI GUI**（CLI 稳定后再做）
- **`nir-cli scan` 完整扫描链路**（协议层已预留；需真机验证 Simplex 路径）
- **Complete scan（flag `0x00`）的 `dlpspec_scan_interpret` 解释**  
  厂家 SDK **没有 macOS `.dylib`**，`dlpspec` / `IscSpec` 仅有 Windows/Linux/Android/STM32 二进制。  
  **不伪造 wavelength/intensity。** 路径：
  1. 首选 **Simplex**（`PERFORM_SCAN` flag `0x5A`）→ FILE `0x0C` 波长 + `0x0D` 强度（Tiva ≥ 2.5.0，设备端已解释）
  2. Complete raw 存 `.bin`，待厂家 Mac 库或 `dlpspec` 源码
- Simplex 元素类型（float32/int32 vs float64）文档未写死，解析时做范围校验并拒绝伪造
- USB 多包 `FILE_GET_DATA` continuation 布局 PDF 未逐字节定义（见 `docs/sdk-analysis.md`）
- Intel Mac：代码无平台绑定，未做通用二进制打包

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
