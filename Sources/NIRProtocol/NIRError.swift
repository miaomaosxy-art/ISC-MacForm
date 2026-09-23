import Foundation

/// Protocol-layer errors. UI should map these to localized messages,
/// never print raw USB/protocol codes to the user.
public enum NIRProtocolError: Error, Equatable, CustomStringConvertible {
    case deviceNotFound
    case deviceOpenFailed(String)
    case deviceDisconnected
    case usbWriteFailed(String)
    case usbReadTimeout
    case invalidPacket(String)
    case sequenceMismatch(expected: UInt8, got: UInt8)
    case deviceBusy
    case deviceError(flags: UInt8)
    case scanTimeout
    case invalidScanData(String)
    case spectrumParseFailed(String)
    case invalidPayloadLength(expected: Int, actual: Int)
    case unexpectedCommand(expected: UInt8, got: UInt8)
    case fileTruncated(expected: Int, actual: Int)
    case saveFailed(String)

    public var description: String {
        switch self {
        case .deviceNotFound:
            return "DeviceNotFound: NIR-M-R2 (VID 0x0451 / PID 0x4200) not found"
        case .deviceOpenFailed(let detail):
            return "DeviceOpenFailed: \(detail)"
        case .deviceDisconnected:
            return "DeviceDisconnected"
        case .usbWriteFailed(let detail):
            return "USBWriteFailed: \(detail)"
        case .usbReadTimeout:
            return "USBReadTimeout"
        case .invalidPacket(let detail):
            return "InvalidPacket: \(detail)"
        case .sequenceMismatch(let expected, let got):
            return "SequenceMismatch: expected \(expected), got \(got)"
        case .deviceBusy:
            return "DeviceBusy"
        case .deviceError(let flags):
            return "DeviceError: flags=0x\(String(flags, radix: 16))"
        case .scanTimeout:
            return "ScanTimeout"
        case .invalidScanData(let detail):
            return "InvalidScanData: \(detail)"
        case .spectrumParseFailed(let detail):
            return "SpectrumParseFailed: \(detail)"
        case .invalidPayloadLength(let expected, let actual):
            return "InvalidPacket: payload length expected \(expected), got \(actual)"
        case .unexpectedCommand(let expected, let got):
            return "InvalidPacket: expected cmd 0x\(String(expected, radix: 16)), got 0x\(String(got, radix: 16))"
        case .fileTruncated(let expected, let actual):
            return "FILE_GET_DATA truncated: expected \(expected), got \(actual)"
        case .saveFailed(let detail):
            return "SaveFailed: \(detail)"
        }
    }

    /// Short, user-facing Chinese message (for GUI later).
    public var userMessage: String {
        switch self {
        case .deviceNotFound:
            return "未找到 NIR-M-R2 光谱仪，请检查 USB 连接与电源开关。"
        case .deviceOpenFailed:
            return "打开设备失败，请重新插拔 USB 后再试。"
        case .deviceDisconnected:
            return "设备已断开连接。"
        case .usbWriteFailed:
            return "USB 发送失败。"
        case .usbReadTimeout:
            return "设备响应超时。"
        case .invalidPacket, .sequenceMismatch, .unexpectedCommand, .invalidPayloadLength:
            return "收到无法解析的设备响应。"
        case .deviceBusy:
            return "设备忙，请稍后再试。"
        case .deviceError:
            return "设备返回错误状态。"
        case .scanTimeout:
            return "扫描超时。"
        case .invalidScanData, .spectrumParseFailed, .fileTruncated:
            return "扫描数据无效。"
        case .saveFailed:
            return "保存失败。"
        }
    }
}
