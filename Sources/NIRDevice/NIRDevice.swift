import Foundation
import HIDTransport
import NIRProtocol

// MARK: - Spectrum model (for GUI / CSV later)

public struct SpectrumPoint: Sendable, Equatable {
    /// Wavelength in nanometers.
    public let wavelength: Double
    /// Detector intensity. Wire type is integer in EasyNIRLib (`unsigned int` / `int`).
    public let intensity: Int

    public init(wavelength: Double, intensity: Int) {
        self.wavelength = wavelength
        self.intensity = intensity
    }
}

public struct Spectrum: Sendable, Equatable {
    public let timestamp: Date
    public let points: [SpectrumPoint]
    public let temperature: Double?
    public let humidity: Double?
    public let serialNumber: String?
    public let source: Source

    public enum Source: String, Sendable, Equatable {
        /// Device-interpreted Simplex files 0x0C / 0x0D (PERFORM_SCAN flag 0x5A).
        case simplex
        /// Complete scan (flag 0x00) — raw only until dlpspec is available on macOS.
        case completeRaw
    }

    public init(
        timestamp: Date = Date(),
        points: [SpectrumPoint],
        temperature: Double? = nil,
        humidity: Double? = nil,
        serialNumber: String? = nil,
        source: Source
    ) {
        self.timestamp = timestamp
        self.points = points
        self.temperature = temperature
        self.humidity = humidity
        self.serialNumber = serialNumber
        self.source = source
    }
}

public struct NIRDeviceInfo: Sendable, Equatable {
    public var serialNumber: String
    public var modelName: String
    public var versions: NIRVersions
    public var deviceStatus: UInt32
    public var hardwareVersionBytes: [UInt8]
    public var mainBoardADC: UInt32
    public var detectorBoardADC: UInt32

    public var hardwareVersion: String {
        // Live device returns ASCII like "F.B.C.A" (main.DMD.detector.optical).
        // Fall back to dotted bytes when not printable.
        let isASCII = hardwareVersionBytes.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0 }
        if isASCII, hardwareVersionBytes.contains(where: { $0 != 0 }) {
            return NIRLE.asciiCString(hardwareVersionBytes)
        }
        return hardwareVersionBytes.map { String($0) }.joined(separator: ".")
    }

    public var scanInProgress: Bool {
        deviceStatus & NNODeviceStatusBit.scanInProgress != 0
    }

    public init(
        serialNumber: String,
        modelName: String,
        versions: NIRVersions,
        deviceStatus: UInt32,
        hardwareVersionBytes: [UInt8],
        mainBoardADC: UInt32,
        detectorBoardADC: UInt32
    ) {
        self.serialNumber = serialNumber
        self.modelName = modelName
        self.versions = versions
        self.deviceStatus = deviceStatus
        self.hardwareVersionBytes = hardwareVersionBytes
        self.mainBoardADC = mainBoardADC
        self.detectorBoardADC = detectorBoardADC
    }
}

// MARK: - Device actor

/// Serializes all USB/protocol traffic. Never issue concurrent HID commands.
public actor NIRDevice {
    private let transport: HIDTransport
    private let proto: NIRProtocolClient
    private var connected = false

    public init(debugLogging: Bool = false) {
        let t = HIDTransport(debugLogging: debugLogging)
        self.transport = t
        self.proto = NIRProtocolClient(transport: t)
    }

    // MARK: - Connection

    public static func listDevices() -> [HIDTransport.DeviceInfo] {
        HIDTransport.enumerateNIRR2()
    }

    public static func listAllHID() -> [HIDTransport.DeviceInfo] {
        HIDTransport.enumerate(vendorID: nil, productID: nil)
    }

    public func connect() throws -> HIDTransport.DeviceInfo {
        let info = try transport.openFirstMatching()
        connected = true
        return info
    }

    public func connect(path: String) throws {
        try transport.open(path: path)
        connected = true
    }

    public func disconnect() {
        transport.close()
        connected = false
    }

    public var isConnected: Bool { connected }

    public func setDebugLogging(_ enabled: Bool) {
        proto.isDebugLoggingEnabled = enabled
    }

    // MARK: - Device Info (Phase 1)

    public func getDeviceInfo() throws -> NIRDeviceInfo {
        guard connected else { throw NIRProtocolError.deviceNotFound }

        let serial = try proto.readSerialNumber()
        let versions = try proto.readVersions()
        let status = try proto.readDeviceStatus()
        let board = try proto.readBoardLevel()
        let model = try proto.readModelName()

        return NIRDeviceInfo(
            serialNumber: serial,
            modelName: model,
            versions: versions,
            deviceStatus: status,
            hardwareVersionBytes: board.versions,
            mainBoardADC: board.mainADC,
            detectorBoardADC: board.detectorADC
        )
    }

    public func getSerialNumber() throws -> String {
        try proto.readSerialNumber()
    }

    public func getVersions() throws -> NIRVersions {
        try proto.readVersions()
    }

    public func getDeviceStatus() throws -> UInt32 {
        try proto.readDeviceStatus()
    }

    // MARK: - Scan primitives (Phase 2+)

    public func getEstimatedScanTimeMS() throws -> UInt32 {
        let resp = try proto.sendCommand(
            group: NNOGroup.system.rawValue,
            command: NNOSystemCommand.readScanTime
        )
        return try NIRLE.u32(resp.payload)
    }

    public func getScanStatus() throws -> UInt8 {
        let resp = try proto.sendCommand(
            group: NNOGroup.system.rawValue,
            command: NNOSystemCommand.scanGetStatus
        )
        guard let first = resp.payload.first else {
            throw NIRProtocolError.invalidPayloadLength(expected: 1, actual: 0)
        }
        return first
    }

    public func getScanConfigCount() throws -> UInt8 {
        let resp = try proto.sendCommand(
            group: NNOGroup.system.rawValue,
            command: NNOSystemCommand.scanCfgNum
        )
        guard let first = resp.payload.first else {
            throw NIRProtocolError.invalidPayloadLength(expected: 1, actual: 0)
        }
        return first
    }

    public func getActiveScanConfigIndex() throws -> UInt8 {
        let resp = try proto.sendCommand(
            group: NNOGroup.system.rawValue,
            command: NNOSystemCommand.scanGetActiveCfg
        )
        guard let first = resp.payload.first else {
            throw NIRProtocolError.invalidPayloadLength(expected: 1, actual: 0)
        }
        return first
    }

    public func setActiveScanConfigIndex(_ index: UInt8) throws -> UInt32 {
        let resp = try proto.writeCommand(
            group: NNOGroup.system.rawValue,
            command: NNOSystemCommand.scanSetActiveCfg,
            payload: [index]
        )
        return try NIRLE.u32(resp.payload)
    }

    public func startScan(flag: NNOScanFlag = .simplex) throws {
        _ = try proto.writeCommand(
            group: NNOGroup.system.rawValue,
            command: NNOSystemCommand.performScan,
            payload: [flag.rawValue]
        )
    }

    public func waitScanComplete(timeoutMS: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            let status = try getScanStatus()
            if status == NNOScanStatus.complete.rawValue {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(NIRExchange.scanPollIntervalMS) * 1_000_000)
        }
        throw NIRProtocolError.scanTimeout
    }

    /// Simplex path: device already interpreted wavelength + intensity (Tiva ≥ 2.5.0).
    public func readSimplexSpectrum() throws -> Spectrum {
        let wlRaw = try proto.readFile(fileType: .simplexScanWavelength)
        let inRaw = try proto.readFile(fileType: .simplexScanIntensity)
        return try Self.parseSimplex(wavelengthRaw: wlRaw, intensityRaw: inRaw)
    }

    /// Complete path: serialized scan data. Not interpreted on macOS without dlpspec.
    public func readCompleteScanRaw() throws -> [UInt8] {
        try proto.readFile(fileType: .scanData)
    }

    public func readFileRaw(fileType: NNOFileType) throws -> [UInt8] {
        try proto.readFile(fileType: fileType)
    }

    // MARK: - Simplex parse (documented types are provisional)

    /// Parse Simplex files.
    ///
    /// PDF does not state element width. EasyNIRLib exposes `double wavelength[]` and
    /// `unsigned int intensity[]` after interpretation. This parser tries:
    ///   1) float32 LE wavelength + int32 LE intensity
    ///   2) float64 LE wavelength + int32 LE intensity
    /// and rejects values outside a sane NIR range rather than inventing data.
    public static func parseSimplex(wavelengthRaw: [UInt8], intensityRaw: [UInt8]) throws -> Spectrum {
        if let points = try? parseWavelengthFloat32(wavelengthRaw, intensityRaw: intensityRaw) {
            return Spectrum(points: points, source: .simplex)
        }
        if let points = try? parseWavelengthFloat64(wavelengthRaw, intensityRaw: intensityRaw) {
            return Spectrum(points: points, source: .simplex)
        }
        throw NIRProtocolError.spectrumParseFailed(
            "simplex wavelength/intensity sizes wl=\(wavelengthRaw.count) in=\(intensityRaw.count) not recognized as float32/int32 or float64/int32"
        )
    }

    private static func parseWavelengthFloat32(
        _ wlRaw: [UInt8],
        intensityRaw: [UInt8]
    ) throws -> [SpectrumPoint] {
        guard wlRaw.count % 4 == 0, intensityRaw.count % 4 == 0 else {
            throw NIRProtocolError.spectrumParseFailed("size not multiple of 4")
        }
        let n = min(wlRaw.count / 4, intensityRaw.count / 4)
        guard n > 0 else {
            throw NIRProtocolError.spectrumParseFailed("empty spectrum")
        }
        var points: [SpectrumPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let wbits = UInt32(wlRaw[i * 4])
                | (UInt32(wlRaw[i * 4 + 1]) << 8)
                | (UInt32(wlRaw[i * 4 + 2]) << 16)
                | (UInt32(wlRaw[i * 4 + 3]) << 24)
            let w = Double(Float(bitPattern: wbits))
            let inten = Int32(bitPattern: UInt32(intensityRaw[i * 4])
                | (UInt32(intensityRaw[i * 4 + 1]) << 8)
                | (UInt32(intensityRaw[i * 4 + 2]) << 16)
                | (UInt32(intensityRaw[i * 4 + 3]) << 24))
            // NIR-M-R2 STD is 900–1700 nm; allow a little margin.
            guard w > 700, w < 2500 else {
                throw NIRProtocolError.spectrumParseFailed("wavelength[\(i)]=\(w) out of NIR range")
            }
            points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
        }
        return points
    }

    private static func parseWavelengthFloat64(
        _ wlRaw: [UInt8],
        intensityRaw: [UInt8]
    ) throws -> [SpectrumPoint] {
        guard wlRaw.count % 8 == 0, intensityRaw.count % 4 == 0 else {
            throw NIRProtocolError.spectrumParseFailed("size not float64/int32")
        }
        let n = min(wlRaw.count / 8, intensityRaw.count / 4)
        guard n > 0 else {
            throw NIRProtocolError.spectrumParseFailed("empty spectrum")
        }
        var points: [SpectrumPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            var wbits: UInt64 = 0
            for b in 0..<8 {
                wbits |= UInt64(wlRaw[i * 8 + b]) << (8 * b)
            }
            let w = Double(bitPattern: wbits)
            let inten = Int32(bitPattern: UInt32(intensityRaw[i * 4])
                | (UInt32(intensityRaw[i * 4 + 1]) << 8)
                | (UInt32(intensityRaw[i * 4 + 2]) << 16)
                | (UInt32(intensityRaw[i * 4 + 3]) << 24))
            guard w > 700, w < 2500 else {
                throw NIRProtocolError.spectrumParseFailed("wavelength[\(i)]=\(w) out of NIR range")
            }
            points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
        }
        return points
    }
}
