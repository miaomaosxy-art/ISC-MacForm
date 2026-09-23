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
    public let detectorTemperature: Double?
    public let serialNumber: String?
    public let configurationName: String?
    public let pga: Int?
    public let source: Source
    /// Complete serialized scan blob (for optional raw export). nil for averages.
    public let raw: [UInt8]?
    /// Fields present in the serialized scan config / protocol. Not invented.
    public let config: ScanConfigInfo?

    public enum Source: String, Sendable, Equatable {
        /// Device-interpreted Simplex files 0x0C / 0x0D (PERFORM_SCAN flag 0x5A).
        case simplex
        /// Complete scan decoded by official DLP Spectrum Library.
        case dlpspec
        /// Complete raw without decode (debug only).
        case completeRaw
    }

    public init(
        timestamp: Date = Date(),
        points: [SpectrumPoint],
        temperature: Double? = nil,
        humidity: Double? = nil,
        detectorTemperature: Double? = nil,
        serialNumber: String? = nil,
        configurationName: String? = nil,
        pga: Int? = nil,
        source: Source,
        raw: [UInt8]? = nil,
        config: ScanConfigInfo? = nil
    ) {
        self.timestamp = timestamp
        self.points = points
        self.temperature = temperature
        self.humidity = humidity
        self.detectorTemperature = detectorTemperature
        self.serialNumber = serialNumber
        self.configurationName = configurationName
        self.pga = pga
        self.source = source
        self.raw = raw
        self.config = config
    }

    public var wavelengthRange: (min: Double, max: Double)? {
        guard let first = points.first, let last = points.last else { return nil }
        return (min(first.wavelength, last.wavelength), max(first.wavelength, last.wavelength))
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
        try getEstimatedScanTimeViaCommand()
    }

    func getEstimatedScanTimeViaCommand() throws -> UInt32 {
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

    /// Full Simplex scan pipeline (Command Description §1.4.1 + UART §3.3.6):
    /// estimated time → PERFORM_SCAN(0x5A) → poll status → FILE 0x0C/0x0D → parse.
    /// On parse failure, raw bytes are still returned so they can be saved as `.bin`.
    public struct ScanArtifacts: Sendable {
        public var spectrum: Spectrum?
        public var wavelengthRaw: [UInt8]
        public var intensityRaw: [UInt8]
        public var completeScanRaw: [UInt8]
        public var interpretRaw: [UInt8]
        public var estimatedScanTimeMS: UInt32
        public var elapsedMS: Int
        public var serialNumber: String?
        public var mode: String
    }

    /// Scan pipeline. Prefers Simplex (0x5A → FILE 0x0C/0x0D). On this firmware
    /// those files have been empty; then falls back to Complete (0x00) +
    /// NNO_FILE_INTERPRET_DATA (0x09) after NNO_CMD_START_SCAN_INTERPRET.
    /// Full complete-scan pipeline (primary path):
    /// estimated time → PERFORM_SCAN(0x00) → poll → FILE NNO_FILE_SCAN_DATA.
    /// Returns serialized scan blob for `DLPSpectrumDecoder.decode`.
    public struct CompleteScanResult: Sendable {
        public var raw: [UInt8]
        public var estimatedScanTimeMS: UInt32
        public var elapsedMS: Int
        public var serialNumber: String?
    }

    public func runCompleteScan(timeoutMS: Int? = nil) async throws -> CompleteScanResult {
        let serial = try? proto.readSerialNumber()
        let estimated = (try? getEstimatedScanTimeViaCommand()) ?? 3000
        let budget = timeoutMS ?? Int(estimated) + 5000

        let t0 = Date()
        try startScan(flag: .complete)
        try await waitScanComplete(timeoutMS: budget)
        let raw = try proto.readFile(fileType: .scanData)
        return CompleteScanResult(
            raw: raw,
            estimatedScanTimeMS: estimated,
            elapsedMS: Int(Date().timeIntervalSince(t0) * 1000),
            serialNumber: serial
        )
    }

    /// Simplex path (debug / compatibility). Primary path is `runCompleteScan` + DLPSpectrumDecoder.
    public func runSimplexScan(timeoutMS: Int? = nil) async throws -> ScanArtifacts {
        let serial = try? proto.readSerialNumber()
        let estimated = (try? getEstimatedScanTimeViaCommand()) ?? 3000
        let budget = timeoutMS ?? Int(estimated) + 5000

        // --- Simplex path ---
        let t0 = Date()
        try startScan(flag: .simplex)
        try await waitScanComplete(timeoutMS: budget)
        let wlRaw = (try? proto.readFile(fileType: .simplexScanWavelength)) ?? []
        let inRaw = (try? proto.readFile(fileType: .simplexScanIntensity)) ?? []
        if !wlRaw.isEmpty, !inRaw.isEmpty,
           let s = try? Self.parseSimplex(wavelengthRaw: wlRaw, intensityRaw: inRaw) {
            return ScanArtifacts(
                spectrum: Spectrum(points: s.points, serialNumber: serial, source: .simplex),
                wavelengthRaw: wlRaw,
                intensityRaw: inRaw,
                completeScanRaw: [],
                interpretRaw: [],
                estimatedScanTimeMS: estimated,
                elapsedMS: Int(Date().timeIntervalSince(t0) * 1000),
                serialNumber: serial,
                mode: "simplex"
            )
        }

        // --- Complete + Tiva interpret fallback ---
        try startScan(flag: .complete)
        try await waitScanComplete(timeoutMS: budget)
        let complete = (try? proto.readFile(fileType: .scanData)) ?? []

        // Device-side interpretation (Command Description §1.4.1 step 4 / cmds 0x39, 0x3A).
        _ = try? proto.writeCommand(group: NNOGroup.system.rawValue, command: NNOSystemCommand.startScanInterpret)
        let interpDeadline = Date().addingTimeInterval(3)
        while Date() < interpDeadline {
            if let st = try? proto.sendCommand(group: NNOGroup.system.rawValue, command: NNOSystemCommand.scanInterpretGetStatus),
               let b = st.payload.first, b == 1 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let interpret = (try? proto.readFile(fileType: .interpretData)) ?? []

        var spectrum: Spectrum?
        if !interpret.isEmpty, let s = try? Self.parseInterpretData(interpret) {
            spectrum = Spectrum(points: s, serialNumber: serial, source: .simplex)
        }

        return ScanArtifacts(
            spectrum: spectrum,
            wavelengthRaw: wlRaw,
            intensityRaw: inRaw,
            completeScanRaw: complete,
            interpretRaw: interpret,
            estimatedScanTimeMS: estimated,
            elapsedMS: Int(Date().timeIntervalSince(t0) * 1000),
            serialNumber: serial,
            mode: "complete+interpret"
        )
    }

    /// Complete path: serialized scan data. Not interpreted on macOS without dlpspec.
    public func readCompleteScanRaw() throws -> [UInt8] {
        try proto.readFile(fileType: .scanData)
    }

    public func readFileRaw(fileType: NNOFileType) throws -> [UInt8] {
        try proto.readFile(fileType: fileType)
    }

    // MARK: - CSV

    public static func csvString(from spectrum: Spectrum, metadata: [String: String] = [:]) -> String {
        var lines: [String] = []
        var meta = metadata
        if let serialNumber = spectrum.serialNumber { meta["serial"] = serialNumber }
        if let configurationName = spectrum.configurationName { meta["config"] = configurationName }
        if let temperature = spectrum.temperature {
            meta["temperature_c"] = String(format: "%.2f", temperature)
        }
        if let detectorTemperature = spectrum.detectorTemperature {
            meta["detector_temperature_c"] = String(format: "%.2f", detectorTemperature)
        }
        if let humidity = spectrum.humidity {
            meta["humidity_percent"] = String(format: "%.2f", humidity)
        }
        if let pga = spectrum.pga { meta["pga"] = "\(pga)" }
        meta["points"] = "\(spectrum.points.count)"
        meta["timestamp"] = ISO8601DateFormatter().string(from: spectrum.timestamp)
        for key in meta.keys.sorted() {
            lines.append("# \(key)=\(meta[key] ?? "")")
        }
        lines.append("wavelength_nm,intensity")
        for p in spectrum.points {
            lines.append(String(format: "%.3f,%d", p.wavelength, p.intensity))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parse NNO_FILE_INTERPRET_DATA (0x09) after Tiva START_SCAN_INTERPRET.
    ///
    /// Live 1024-byte dump shows repeating 8-byte groups of 4×uint16 LE that look like
    /// (dark, sample, ref_a, ref_b) or similar ADC/intensity quads — NOT float wavelengths.
    /// Until the official layout is confirmed, try documented/simple encodings only:
    ///   1) interleaved float32 wavelength/intensity pairs
    ///   2) two float32 arrays (wl[n], int[n])
    ///   3) two uint16 arrays (wl×100 as nm×100, intensity)
    /// If none fit, throw — caller keeps raw bytes. Do not invent wavelengths.
    public static func parseInterpretData(_ raw: [UInt8]) throws -> [SpectrumPoint] {
        // 1) interleaved f32 pairs: w,i,w,i…
        if raw.count % 8 == 0 {
            let n = raw.count / 8
            if n >= 8 {
                var points: [SpectrumPoint] = []
                var ok = true
                for i in 0..<n {
                    let w = Double(Float(bitPattern: leU32(raw, i * 8)))
                    let inten = Double(Float(bitPattern: leU32(raw, i * 8 + 4)))
                    if w < 700 || w > 2500 { ok = false; break }
                    points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
                }
                if ok { return points }
            }
        }
        // 2) two f32 halves
        if raw.count % 8 == 0 {
            let n = raw.count / 16 * 2
            let half = raw.count / 2
            if half % 4 == 0 {
                let m = half / 4
                var points: [SpectrumPoint] = []
                var ok = m >= 8
                for i in 0..<m where ok {
                    let w = Double(Float(bitPattern: leU32(raw, i * 4)))
                    let inten = Double(Float(bitPattern: leU32(raw, half + i * 4)))
                    if w < 700 || w > 2500 { ok = false; break }
                    points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
                }
                if ok { return points }
            }
            _ = n
        }
        throw NIRProtocolError.spectrumParseFailed(
            "interpret data \(raw.count)B layout not recognized as wavelength/intensity (kept as raw)"
        )
    }

    // MARK: - Simplex parse (documented types are provisional)

    /// Parse Simplex files.
    ///
    /// PDF does not state element width. EasyNIRLib exposes `double wavelength[]` and
    /// `unsigned int intensity[]`. This parser tries common wire layouts and rejects
    /// values outside a sane NIR range rather than inventing data:
    ///   wavelength: float32 LE or float64 LE
    ///   intensity:  int32 / uint16 / int16 LE
    public static func parseSimplex(wavelengthRaw: [UInt8], intensityRaw: [UInt8]) throws -> Spectrum {
        let attempts: [(String, ( [UInt8], [UInt8]) throws -> [SpectrumPoint])] = [
            ("f32/i32", parseWLFloat32_i32),
            ("f32/u16", parseWLFloat32_u16),
            ("f32/i16", parseWLFloat32_i16),
            ("f64/i32", parseWLFloat64_i32),
        ]
        var errors: [String] = []
        for (name, fn) in attempts {
            do {
                let points = try fn(wavelengthRaw, intensityRaw)
                return Spectrum(points: points, source: .simplex)
            } catch {
                errors.append("\(name): \(error)")
            }
        }
        throw NIRProtocolError.spectrumParseFailed(
            "simplex wl=\(wavelengthRaw.count)B in=\(intensityRaw.count)B not recognized — \(errors.joined(separator: "; "))"
        )
    }

    private static func leU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func leU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func checkWavelength(_ w: Double, index i: Int) throws {
        // NIR-M-R2 STD is 900–1700 nm; allow a little margin.
        guard w > 700, w < 2500 else {
            throw NIRProtocolError.spectrumParseFailed("wavelength[\(i)]=\(w) out of NIR range")
        }
    }

    private static func parseWLFloat32_i32(_ wlRaw: [UInt8], intensityRaw: [UInt8]) throws -> [SpectrumPoint] {
        guard wlRaw.count % 4 == 0, intensityRaw.count % 4 == 0 else {
            throw NIRProtocolError.spectrumParseFailed("size not f32/i32")
        }
        let n = min(wlRaw.count / 4, intensityRaw.count / 4)
        guard n > 0 else { throw NIRProtocolError.spectrumParseFailed("empty") }
        var points: [SpectrumPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let w = Double(Float(bitPattern: leU32(wlRaw, i * 4)))
            try checkWavelength(w, index: i)
            let inten = Int32(bitPattern: leU32(intensityRaw, i * 4))
            points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
        }
        return points
    }

    private static func parseWLFloat32_u16(_ wlRaw: [UInt8], intensityRaw: [UInt8]) throws -> [SpectrumPoint] {
        guard wlRaw.count % 4 == 0, intensityRaw.count % 2 == 0 else {
            throw NIRProtocolError.spectrumParseFailed("size not f32/u16")
        }
        let n = min(wlRaw.count / 4, intensityRaw.count / 2)
        guard n > 0 else { throw NIRProtocolError.spectrumParseFailed("empty") }
        var points: [SpectrumPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let w = Double(Float(bitPattern: leU32(wlRaw, i * 4)))
            try checkWavelength(w, index: i)
            points.append(SpectrumPoint(wavelength: w, intensity: Int(leU16(intensityRaw, i * 2))))
        }
        return points
    }

    private static func parseWLFloat32_i16(_ wlRaw: [UInt8], intensityRaw: [UInt8]) throws -> [SpectrumPoint] {
        guard wlRaw.count % 4 == 0, intensityRaw.count % 2 == 0 else {
            throw NIRProtocolError.spectrumParseFailed("size not f32/i16")
        }
        let n = min(wlRaw.count / 4, intensityRaw.count / 2)
        guard n > 0 else { throw NIRProtocolError.spectrumParseFailed("empty") }
        var points: [SpectrumPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let w = Double(Float(bitPattern: leU32(wlRaw, i * 4)))
            try checkWavelength(w, index: i)
            let inten = Int16(bitPattern: leU16(intensityRaw, i * 2))
            points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
        }
        return points
    }

    private static func parseWLFloat64_i32(_ wlRaw: [UInt8], intensityRaw: [UInt8]) throws -> [SpectrumPoint] {
        guard wlRaw.count % 8 == 0, intensityRaw.count % 4 == 0 else {
            throw NIRProtocolError.spectrumParseFailed("size not f64/i32")
        }
        let n = min(wlRaw.count / 8, intensityRaw.count / 4)
        guard n > 0 else { throw NIRProtocolError.spectrumParseFailed("empty") }
        var points: [SpectrumPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            var wbits: UInt64 = 0
            for b in 0..<8 {
                wbits |= UInt64(wlRaw[i * 8 + b]) << (8 * b)
            }
            let w = Double(bitPattern: wbits)
            try checkWavelength(w, index: i)
            let inten = Int32(bitPattern: leU32(intensityRaw, i * 4))
            points.append(SpectrumPoint(wavelength: w, intensity: Int(inten)))
        }
        return points
    }
}
