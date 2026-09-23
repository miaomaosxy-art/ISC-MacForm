/**
 NIR-M-R2 / ISC NIRScan protocol constants.

 Source of truth:
   ISC NIRScan USB and UART Command Description v1.2.pdf
   (InnoSpectra / Pynect EasyNIRLib; TI DLP NIRscan Nano compatible)
   Cross-checked against portable_spectrometer/nir_esp32_poc/docs/PROTOCOL.md

 Byte order on the wire: little-endian (LSB first).
 */
import Foundation

// MARK: - USB identity

public enum NIRUSB {
    public static let vendorID: UInt16 = 0x0451
    public static let productID: UInt16 = 0x4200
}

// MARK: - HID application packet

public enum NIRExchange {
    /// Application payload max (Command Description §2.1).
    public static let hidPacketSize = 64
    /// On-wire HID report size (no Report ID). Live probe: write/read 64 bytes.
    public static let hidWriteSize = 64
    public static let hidReadSize = 64
    public static let protocolID: UInt8 = 0x00
    /// ID + Flags + Seq + LenL + LenH
    public static let headerSize = 5
    /// Command byte + Group byte
    public static let commandGroupSize = 2
    public static let defaultTimeoutMS: Int = 2000
    public static let scanPollIntervalMS: Int = 100
}

// MARK: - Flags byte (Table 2-1)

public enum NIRFlag {
    public static let read: UInt8 = 0x80
    public static let write: UInt8 = 0x00
    public static let reply: UInt8 = 0x40
    public static let ready: UInt8 = 0x40
    public static let errorMask: UInt8 = 0x30
    public static let errorSuccess: UInt8 = 0x00
    public static let errorError: UInt8 = 0x10
    public static let errorBusy: UInt8 = 0x20

    public static let writeReply: UInt8 = write | reply // 0x40
    public static let readReply: UInt8 = read | reply   // 0xC0
}

// MARK: - Command groups

public enum NNOGroup: UInt8 {
    case file = 0x00
    case factory = 0x01
    case system = 0x02
    case sensor = 0x03
    case status = 0x04
}

// MARK: - File group (0x00)

public enum NNOFileCommand {
    public static let writeData: UInt8 = 0x25
    public static let setWriteSize: UInt8 = 0x2A
    public static let readFileListSize: UInt8 = 0x2B
    public static let readFileList: UInt8 = 0x2C
    public static let getReadSize: UInt8 = 0x2D
    public static let getData: UInt8 = 0x2E
    public static let gotoTivaBootloader: UInt8 = 0x2F
}

// MARK: - Factory / system helpers

public enum NNOFactoryCommand {
    public static let dlpcEnable: UInt8 = 0x05
}

// MARK: - System group (0x02)

public enum NNOSystemCommand {
    public static let tivaVersion: UInt8 = 0x16
    public static let performScan: UInt8 = 0x18
    public static let scanGetStatus: UInt8 = 0x19
    public static let tivaReset: UInt8 = 0x1A
    public static let setPGA: UInt8 = 0x1B
    public static let scanCfgApply: UInt8 = 0x1E
    public static let scanCfgSave: UInt8 = 0x1F
    public static let scanCfgRead: UInt8 = 0x20
    public static let scanCfgEraseAll: UInt8 = 0x21
    public static let scanCfgNum: UInt8 = 0x22
    public static let scanGetActiveCfg: UInt8 = 0x23
    public static let scanSetActiveCfg: UInt8 = 0x24
    public static let setDlpcOnOffCtrl: UInt8 = 0x25
    public static let getPGA: UInt8 = 0x28
    public static let scanNumRepeats: UInt8 = 0x2E
    public static let serialNumberRead: UInt8 = 0x33
    public static let readScanTime: UInt8 = 0x37
    public static let startScanInterpret: UInt8 = 0x39
    public static let scanInterpretGetStatus: UInt8 = 0x3A
    public static let modelNameWrite: UInt8 = 0x3B
    public static let modelNameRead: UInt8 = 0x3C
    public static let readLampUsage: UInt8 = 0x80
    public static let writeLampDelay: UInt8 = 0x81
}

// MARK: - Sensor group (0x03)

public enum NNOSensorCommand {
    public static let readTemp: UInt8 = 0x00
    public static let readHumidity: UInt8 = 0x02
    public static let readModelName: UInt8 = 0xFD
    public static let getBoardLevel: UInt8 = 0xFE
    public static let readFlashUID: UInt8 = 0xFF
}

// MARK: - Status group (0x04)

public enum NNOStatusCommand {
    public static let readDeviceStatus: UInt8 = 0x03
    public static let readErrorStatus: UInt8 = 0x04
    public static let resetErrorStatus: UInt8 = 0x05
    public static let setFixedPGA: UInt8 = 0x0C
}

// MARK: - File types (Table 3-12 / Table 1-1)

public enum NNOFileType: UInt8 {
    case scanData = 0x00
    case scanConfig = 0x01
    case refCalData = 0x02
    case refCalMatrix = 0x03
    case hadSNRData = 0x05
    case scanConfigList = 0x06
    case scanList = 0x07
    case scanDataFromSD = 0x08
    case interpretData = 0x09
    case simplexScanWavelength = 0x0C
    case simplexScanIntensity = 0x0D
}

/// PERFORM_SCAN payload byte.
///
/// Documented discrepancy (Command Description Table 1-1/2-2 vs UART §3.3.6 Table 3-10):
///  - Table 1-1/2-2: "Store in SD: 0/1"
///  - UART §3.3.6: 0x00 = complete scan data; 0x5A = simplex scan data
/// EasyNIRLib getFormattedSpectrum() matches the Simplex / device-interpreted path.
public enum NNOScanFlag: UInt8 {
    case complete = 0x00
    case storeToSD = 0x01
    case simplex = 0x5A
}

// MARK: - Scan status (NNO_CMD_SCAN_GET_STATUS)

public enum NNOScanStatus: UInt8 {
    case inProgress = 0x00
    case complete = 0x01
}

// MARK: - Device status bits (Appendix A.1)

public enum NNODeviceStatusBit {
    public static let tivaActive: UInt32 = 1 << 0
    public static let scanInProgress: UInt32 = 1 << 1
    public static let sdPresent: UInt32 = 1 << 2
    public static let sdIO: UInt32 = 1 << 3
    public static let btActive: UInt32 = 1 << 4
    public static let btConnected: UInt32 = 1 << 5
    public static let scanInterpreting: UInt32 = 1 << 6
    public static let scanButton: UInt32 = 1 << 7
    public static let batteryCharging: UInt32 = 1 << 8
}

// MARK: - Payload sizes from Table 1-1 / 2-2

public enum NNOPayloadSize {
    public static let version = 28          // 7 x uint32
    public static let versionFieldCount = 7
    public static let serialNumber = 8
    public static let deviceStatus = 4
    public static let boardLevel = 16
    public static let modelName = 16
    public static let scanTime = 4
    public static let fileReadSize = 4
    public static let scanStatus = 1
    public static let scanCfgNum = 1
    public static let temperature = 8
    public static let humidity = 8
}

// MARK: - Versions payload (28 bytes = 7 x uint32 LE)

public struct NIRVersions: Sendable, Equatable {
    public var tivaSW: UInt32
    public var dlpcSW: UInt32
    public var dlpcFlash: UInt32
    public var specLib: UInt32
    public var calData: UInt32
    public var refCalData: UInt32
    public var cfgData: UInt32

    public init(
        tivaSW: UInt32 = 0,
        dlpcSW: UInt32 = 0,
        dlpcFlash: UInt32 = 0,
        specLib: UInt32 = 0,
        calData: UInt32 = 0,
        refCalData: UInt32 = 0,
        cfgData: UInt32 = 0
    ) {
        self.tivaSW = tivaSW
        self.dlpcSW = dlpcSW
        self.dlpcFlash = dlpcFlash
        self.specLib = specLib
        self.calData = calData
        self.refCalData = refCalData
        self.cfgData = cfgData
    }

    public static func parse(_ payload: [UInt8]) throws -> NIRVersions {
        guard payload.count >= NNOPayloadSize.version else {
            throw NIRProtocolError.invalidPayloadLength(
                expected: NNOPayloadSize.version,
                actual: payload.count
            )
        }
        let words: [UInt32] = (0..<NNOPayloadSize.versionFieldCount).map { i in
            let o = i * 4
            return UInt32(payload[o])
                | (UInt32(payload[o + 1]) << 8)
                | (UInt32(payload[o + 2]) << 16)
                | (UInt32(payload[o + 3]) << 24)
        }
        return NIRVersions(
            tivaSW: words[0],
            dlpcSW: words[1],
            dlpcFlash: words[2],
            specLib: words[3],
            calData: words[4],
            refCalData: words[5],
            cfgData: words[6]
        )
    }
}
