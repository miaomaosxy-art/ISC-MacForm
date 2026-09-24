import AppKit
import DLPSpec
import Foundation
import HIDTransport
import NIRDevice
import NIRProtocol
import UniformTypeIdentifiers

// MARK: - UI state types

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// Scan pipeline phase. Internal machine; GUI only shows progress text + busy flag.
enum ScanPhase: Equatable {
    case idle
    case starting
    case scanning
    case readingData
    case decoding
    case completed
    case failed

    var isBusy: Bool {
        switch self {
        case .idle, .completed, .failed: return false
        case .starting, .scanning, .readingData, .decoding: return true
        }
    }
}

enum SpectrumDisplayMode: String, CaseIterable, Identifiable {
    case individual = "Show individual scans"
    case average = "Show average"
    var id: String { rawValue }
}

enum ReferenceSource: String, CaseIterable, Identifiable {
    case builtIn = "Built-In"
    case new = "New"
    case previous = "Previous"
    var id: String { rawValue }
}

struct SpectrumPlotPoint: Identifiable {
    let wavelength: Double
    let value: Double
    var id: Double { wavelength }
}

struct SpectrumPlotSeries: Identifiable {
    let id: Int
    let label: String
    let points: [SpectrumPlotPoint]
}

struct ReferenceDetails {
    let timestamp: Date?
    let configName: String?
    let pga: Int?
    let serialNumber: String?
}

// MARK: - Controller

/// Single owner of device lifecycle and scan state.
/// Views observe this object and never talk to `NIRDevice` directly.
@MainActor
final class SpectrometerController: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var deviceInfo: NIRDeviceInfo?
    @Published var scanConfig: ScanConfigInfo?

    @Published var spectrum: Spectrum?
    @Published var recentScans: [Spectrum] = []
    @Published var averageSpectrum: Spectrum?
    @Published var displayMode: SpectrumDisplayMode = .individual
    @Published var quantity: SpectrumQuantity = .intensity
    @Published var referenceSource: ReferenceSource = .builtIn
    @Published private(set) var referenceAnalyses: [ReferenceAnalysis] = []
    @Published private(set) var referenceError: String?
    @Published private(set) var referenceStatus: String = "Factory reference on device"
    @Published private(set) var referenceDetails: ReferenceDetails?
    @Published private(set) var referenceReady = false

    @Published var scanPhase: ScanPhase = .idle
    @Published var scanProgressText: String?
    @Published var lastError: String?
    @Published var statusMessage: String?

    @Published var repeatCount: Int = 5
    @Published var saveRawEnabled = false
    @Published var debugLoggingEnabled = false {
        didSet {
            DebugLog.setEnabled(debugLoggingEnabled)
            let d = device
            Task { await d.setDebugLogging(debugLoggingEnabled) }
        }
    }

    /// Set when app has connected at least once; used to choose Connecting vs Reconnecting.
    private var hasEverConnected = false
    private var isConnecting = false
    private let device = NIRDevice(debugLogging: false)
    private let referenceStore = ReferenceStore()
    private var factoryReferenceRaw: [UInt8]?
    private var factoryReferenceSerial: String?
    private var referenceMatrixRaw: [UInt8]?
    private var localReference: LocalReference?
    private var referenceGeneration = 0
    private var pollTask: Task<Void, Never>?

    private var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isScanning: Bool { scanPhase.isBusy }

    var canScan: Bool {
        isConnected && !scanPhase.isBusy
    }

    var canSampleScan: Bool {
        canScan && referenceReady && referenceSource != .new
    }

    var canSave: Bool {
        !recentScans.isEmpty || spectrum != nil
    }

    var pointCountText: String {
        if !recentScans.isEmpty {
            let n = recentScans[recentScans.count - 1].points.count
            return "\(n) points · \(recentScans.count) scan(s)"
        }
        if let n = spectrum?.points.count {
            return "\(n) points"
        }
        return "—"
    }

    var displayedSeries: [Spectrum] {
        if displayMode == .average, let avg = averageSpectrum {
            return [avg]
        }
        return recentScans.isEmpty ? (spectrum.map { [$0] } ?? []) : recentScans
    }

    var displayedPlotSeries: [SpectrumPlotSeries] {
        if quantity == .intensity {
            return displayedSeries.enumerated().map { index, scan in
                SpectrumPlotSeries(
                    id: index,
                    label: displayMode == .average && averageSpectrum != nil
                        ? "Average" : String(format: "Scan %03d", index + 1),
                    points: scan.points.map {
                        SpectrumPlotPoint(wavelength: $0.wavelength, value: Double($0.intensity))
                    }
                )
            }
        }
        guard referenceAnalyses.count == recentScans.count else { return [] }
        if displayMode == .average, let analysis = averageReferenceAnalysis {
            return [SpectrumPlotSeries(id: 0, label: "Average",
                points: zip(analysis.wavelengths, analysis.values(for: quantity)).compactMap { wavelength, value in
                    value.map { SpectrumPlotPoint(wavelength: wavelength, value: $0) }
                })]
        }
        return referenceAnalyses.enumerated().map { index, analysis in
            SpectrumPlotSeries(
                id: index,
                label: String(format: "Scan %03d", index + 1),
                points: zip(analysis.wavelengths, analysis.values(for: quantity)).compactMap { wavelength, value in
                    value.map { SpectrumPlotPoint(wavelength: wavelength, value: $0) }
                }
            )
        }
    }

    var invalidAbsorbanceCount: Int {
        referenceAnalyses.reduce(0) { $0 + $1.invalidAbsorbanceCount }
    }

    var invalidReflectanceCount: Int {
        referenceAnalyses.reduce(0) { $0 + ($1.reflectance.count - $1.finiteReflectanceCount) }
    }

    var hasDerivedSpectrum: Bool {
        !referenceAnalyses.isEmpty && referenceAnalyses.count == recentScans.count
    }

    var canAverageDerived: Bool { averageReferenceAnalysis != nil }

    private var averageReferenceAnalysis: ReferenceAnalysis? {
        guard let averageSpectrum, let first = referenceAnalyses.first,
              referenceAnalyses.count == recentScans.count,
              referenceAnalyses.allSatisfy({ $0.referenceIntensity == first.referenceIntensity &&
                  $0.wavelengths == first.wavelengths }) else { return nil }
        return try? ReferenceAnalysis.average(sample: averageSpectrum, reference: first)
    }

    private var referenceExportMetadata: ReferenceExportMetadata? {
        guard let referenceDetails else { return nil }
        return ReferenceExportMetadata(source: referenceSource.rawValue,
            referenceTimestamp: referenceDetails.timestamp,
            referenceConfig: referenceDetails.configName,
            referencePGA: referenceDetails.pga)
    }

    var serialForFilename: String? {
        deviceInfo?.serialNumber ?? spectrum?.serialNumber
    }

    // MARK: - Lifecycle

    func start() {
        DebugLog.app("controller start")
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPresence()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        DebugLog.app("controller stop")
        pollTask?.cancel()
        pollTask = nil
        Task { await device.disconnect() }
        connectionState = .disconnected
        referenceReady = false
    }

    /// 1 s presence poll (Phase 1). IOHIDManager callbacks can replace this later.
    private func pollPresence() async {
        let found = !NIRDevice.listDevices().isEmpty

        if found {
            switch connectionState {
            case .disconnected:
                guard !isConnecting, !scanPhase.isBusy else { return }
                await connect(isReconnect: hasEverConnected)
            case .connecting, .reconnecting, .connected:
                break
            }
            return
        }

        // Not found — tear down if we thought we were connected.
        switch connectionState {
        case .connected, .connecting, .reconnecting:
            DebugLog.app("device presence lost")
            if scanPhase.isBusy {
                lastError = "Device disconnected."
                scanPhase = .failed
                scanProgressText = nil
            }
            isConnecting = false
            await device.disconnect()
            connectionState = .disconnected
            deviceInfo = nil
            factoryReferenceRaw = nil
            factoryReferenceSerial = nil
            referenceMatrixRaw = nil
            localReference = nil
            referenceAnalyses = []
            referenceReady = false
            referenceDetails = nil
            scanConfig = mergeScanConfig(scanConfig, active: nil, count: nil)
            statusMessage = "No spectrometer connected"
            DebugLog.app("state → disconnected")
        case .disconnected:
            if statusMessage == nil {
                statusMessage = "No spectrometer connected"
            }
        }
    }

    func connect(isReconnect: Bool = false) async {
        guard !isConnecting else { return }
        if case .connected = connectionState { return }

        isConnecting = true
        lastError = nil
        connectionState = isReconnect || hasEverConnected ? .reconnecting : .connecting
        DebugLog.app("connecting…")
        do {
            let usb = try await device.connect()
            hasEverConnected = true
            connectionState = .connected
            DebugLog.app("connected usb serial=\(usb.serialNumber ?? "?")")

            if let info = try? await device.getDeviceInfo() {
                deviceInfo = info
                DebugLog.app("device info serial=\(info.serialNumber) model=\(info.modelName)")
            }
            factoryReferenceRaw = nil
            factoryReferenceSerial = nil
            referenceMatrixRaw = nil
            localReference = nil
            await refreshScanConfig()
            await prepareReferenceSource()
            statusMessage = nil
        } catch {
            await device.disconnect()
            connectionState = .disconnected
            deviceInfo = nil
            lastError = humanMessage(for: error)
            DebugLog.app("connect failed: \(error)")
        }
        isConnecting = false
    }

    func disconnect() async {
        await device.disconnect()
        connectionState = .disconnected
        deviceInfo = nil
        factoryReferenceRaw = nil
        factoryReferenceSerial = nil
        referenceMatrixRaw = nil
        localReference = nil
        referenceAnalyses = []
        referenceReady = false
        referenceDetails = nil
        statusMessage = "No spectrometer connected"
        DebugLog.app("manual disconnect")
    }

    /// Read active scan config index / count. Name and geometry come from decoded scan config.
    func refreshScanConfig() async {
        var info = scanConfig ?? ScanConfigInfo()
        do {
            let count = try await device.getScanConfigCount()
            info.configCount = Int(count)
            DebugLog.app("scan config count=\(count)")
        } catch {
            DebugLog.app("scan config count failed: \(error)")
        }
        do {
            let idx = try await device.getActiveScanConfigIndex()
            info.activeConfigIndex = Int(idx)
            DebugLog.app("active scan config index=\(idx)")
        } catch {
            DebugLog.app("active scan config index failed: \(error)")
        }
        scanConfig = info
    }

    // MARK: - Reference workflow

    /// Selecting Previous reads only the Mac app's saved white scan. Built-In
    /// reads device files only; neither selection writes reference calibration.
    func prepareReferenceSource() async {
        referenceGeneration += 1
        let generation = referenceGeneration
        referenceAnalyses = []
        referenceError = nil
        referenceReady = false
        referenceDetails = nil
        guard isConnected else {
            referenceStatus = "Connect a spectrometer to use a reference"
            return
        }
        switch referenceSource {
        case .builtIn:
            localReference = nil
            referenceStatus = "Reading factory reference from device…"
            do {
                guard let serial = deviceInfo?.serialNumber, !serial.isEmpty else {
                    referenceError = "Device serial number is unavailable."
                    return
                }
                if factoryReferenceSerial != serial {
                    factoryReferenceRaw = nil
                    referenceMatrixRaw = nil
                    factoryReferenceSerial = serial
                }
                if referenceMatrixRaw == nil {
                    let matrix = try await device.readFileRaw(fileType: .refCalMatrix)
                    guard generation == referenceGeneration else { return }
                    guard !matrix.isEmpty else {
                        referenceError = "Built-in reference calibration matrix is missing."
                        return
                    }
                    referenceMatrixRaw = matrix
                }
                if factoryReferenceRaw == nil {
                    let raw = try await device.readFileRaw(fileType: .refCalData)
                    guard generation == referenceGeneration else { return }
                    guard !raw.isEmpty else {
                        referenceError = "No valid built-in reference calibration data was found. Please acquire a new reference."
                        return
                    }
                    factoryReferenceRaw = raw
                }
                guard let factoryReferenceRaw else { return }
                let decoded = try DLPSpectrumDecoder.decode(factoryReferenceRaw)
                guard decoded.serialNumber == nil || decoded.serialNumber == serial else {
                    referenceError = "Built-in reference belongs to another device."
                    return
                }
                referenceDetails = ReferenceDetails(timestamp: decoded.timestamp,
                    configName: decoded.configurationName, pga: decoded.pga,
                    serialNumber: decoded.serialNumber)
                referenceStatus = "Built-In Factory Reference"
                referenceReady = true
            } catch {
                guard generation == referenceGeneration else { return }
                referenceError = "No valid built-in reference calibration data was found. Please acquire a new reference."
                DebugLog.dlp("factory reference load FAIL: \(error)")
                return
            }
        case .new:
            localReference = nil
            referenceStatus = "Place the standard white target, then scan reference"
        case .previous:
            localReference = nil
            referenceStatus = "Loading local white reference…"
            guard let serial = deviceInfo?.serialNumber else {
                referenceError = "Connect the spectrometer to load its previous reference."
                return
            }
            do {
                guard let saved = try referenceStore.load(serialNumber: serial) else {
                    referenceError = "No local reference is available. Please acquire a new reference first."
                    return
                }
                let decoded = try DLPSpectrumDecoder.decode([UInt8](saved.rawScan))
                guard decoded.serialNumber == nil || decoded.serialNumber == serial else {
                    throw ReferenceStoreError.deviceMismatch
                }
                if referenceMatrixRaw == nil {
                    let matrix = try await device.readFileRaw(fileType: .refCalMatrix)
                    guard generation == referenceGeneration else { return }
                    guard !matrix.isEmpty else { throw ReferenceAnalysisError.missingCalibration }
                    referenceMatrixRaw = matrix
                }
                localReference = saved
                referenceStatus = "Local white reference from \(saved.capturedAt.formatted(date: .abbreviated, time: .shortened))"
                referenceDetails = ReferenceDetails(timestamp: saved.capturedAt,
                    configName: saved.config?.name ?? decoded.configurationName,
                    pga: saved.pga ?? decoded.pga,
                    serialNumber: saved.serialNumber)
                referenceReady = true
            } catch {
                guard generation == referenceGeneration else { return }
                referenceError = "Saved reference cannot be loaded: \(error)"
                return
            }
        }
        if referenceReady { await refreshReferenceAnalyses() }
    }

    /// A normal complete scan of a physical white target; no reference-write
    /// command is sent to the device. Persist only after decode succeeds.
    func scanNewReference() async {
        guard referenceSource == .new, canScan else { return }
        guard let serial = deviceInfo?.serialNumber, !serial.isEmpty else {
            lastError = "Device serial number is required to save a white reference."
            return
        }
        scanPhase = .starting
        scanProgressText = "Scanning white reference…"
        lastError = nil
        referenceError = nil
        do {
            scanPhase = .scanning
            let result = try await device.runCompleteScan()
            scanPhase = .decoding
            scanProgressText = "Validating white reference…"
            let decoded = try DLPSpectrumDecoder.decode(result.raw)
            guard decoded.serialNumber == nil || decoded.serialNumber == serial else {
                throw ReferenceStoreError.deviceMismatch
            }
            let saved = LocalReference(serialNumber: serial, capturedAt: decoded.timestamp,
                rawScan: Data(result.raw), config: decoded.config, pga: decoded.pga,
                temperature: decoded.temperature, humidity: decoded.humidity)
            try referenceStore.save(saved)
            localReference = saved
            referenceSource = .previous
            referenceStatus = "Local white reference from \(saved.capturedAt.formatted(date: .abbreviated, time: .shortened))"
            referenceDetails = ReferenceDetails(timestamp: saved.capturedAt,
                configName: decoded.configurationName, pga: decoded.pga,
                serialNumber: serial)
            referenceReady = true
            scanPhase = .completed
            scanProgressText = nil
            statusMessage = "White reference saved. Previous is now active."
            await refreshReferenceAnalyses()
        } catch {
            scanPhase = .idle
            scanProgressText = nil
            lastError = "White reference scan failed: \(humanMessage(for: error))"
        }
    }

    private func refreshReferenceAnalyses() async {
        guard !recentScans.isEmpty else { return }
        let generation = referenceGeneration
        do {
            let matrix: [UInt8]
            if let cached = referenceMatrixRaw {
                matrix = cached
            } else {
                matrix = try await device.readFileRaw(fileType: .refCalMatrix)
                guard generation == referenceGeneration else { return }
                guard !matrix.isEmpty else { throw ReferenceAnalysisError.missingCalibration }
                referenceMatrixRaw = matrix
            }

            let rawReference: [UInt8]
            if referenceSource == .builtIn {
                if let cached = factoryReferenceRaw {
                    rawReference = cached
                } else {
                    rawReference = try await device.readFileRaw(fileType: .refCalData)
                    guard generation == referenceGeneration else { return }
                    guard !rawReference.isEmpty else { throw ReferenceAnalysisError.referenceMismatch }
                    factoryReferenceRaw = rawReference
                }
            } else {
                guard let localReference else {
                    throw ReferenceAnalysisError.referenceMismatch
                }
                rawReference = [UInt8](localReference.rawScan)
            }

            let analyses = try recentScans.map {
                try ReferenceAnalysis.analyze(sample: $0, referenceRaw: rawReference, matrixRaw: matrix)
            }
            guard generation == referenceGeneration else { return }
            referenceAnalyses = analyses
            referenceError = nil
        } catch {
            guard generation == referenceGeneration else { return }
            referenceAnalyses = []
            if let error = error as? ReferenceAnalysisError {
                referenceError = error.userMessage
            } else {
                referenceError = "Reference interpretation failed: \(humanMessage(for: error))"
            }
            DebugLog.dlp("reference FAIL: \(error)")
        }
    }

    // MARK: - Scan state machine

    func startScan() async {
        guard canSampleScan else {
            if referenceSource == .new && localReference == nil {
                lastError = "Scan a white reference before scanning a sample."
            }
            return
        }
        await runScans(count: 1, isRepeat: false)
    }

    func startRepeatScan() async {
        guard canSampleScan else {
            if referenceSource == .new && localReference == nil {
                lastError = "Scan a white reference before scanning a sample."
            }
            return
        }
        await runScans(count: max(1, repeatCount), isRepeat: true)
    }

    /// Serial scan execution. Never issues concurrent USB commands.
    private func runScans(count: Int, isRepeat: Bool) async {
        guard canScan else {
            if !isConnected {
                lastError = "Spectrometer not found."
            }
            return
        }

        recentScans = []
        referenceAnalyses = []
        referenceError = nil
        averageSpectrum = nil
        spectrum = nil
        lastError = nil
        statusMessage = nil

        for i in 1...count {
            if Task.isCancelled { break }
            // Re-check presence between repeat scans.
            if NIRDevice.listDevices().isEmpty {
                lastError = "Device disconnected."
                scanPhase = .failed
                scanProgressText = nil
                connectionState = .disconnected
                deviceInfo = nil
                break
            }

            if isRepeat {
                scanProgressText = "Scanning \(i) / \(count)"
            } else {
                scanProgressText = nil
            }
            DebugLog.scan("starting complete scan \(i)/\(count)")

            let ok = await runOneScan(index: i, total: count)
            if !ok { break }
        }

        if scanPhase != .failed {
            scanPhase = .completed
            scanProgressText = nil
            if isRepeat, recentScans.count > 1 {
                computeAverage()
                if averageSpectrum != nil {
                    displayMode = .average
                }
            }
            let n = recentScans.last?.points.count ?? spectrum?.points.count ?? 0
            statusMessage = recentScans.count > 1
                ? "Completed \(recentScans.count) scans · \(n) points"
                : "Scan complete"
        }
    }

    /// One scan: Starting → Scanning → ReadingData → Decoding → Completed | Failed.
    /// Returns false on failure (machine already moved to failed/idle recovery).
    private func runOneScan(index: Int, total: Int) async -> Bool {
        scanPhase = .starting
        scanProgressText = total > 1 ? "Scanning \(index) / \(total)" : "Starting scan…"
        DebugLog.scan("phase=starting")

        do {
            let estimated = (try? await device.getEstimatedScanTimeMS()) ?? 3000
            DebugLog.scan("expected time \(estimated) ms")

            scanPhase = .scanning
            scanProgressText = total > 1 ? "Scanning \(index) / \(total)" : "Scanning…"
            DebugLog.scan("phase=scanning")

            let result = try await device.runCompleteScan()

            scanPhase = .readingData
            scanProgressText = total > 1 ? "Reading \(index) / \(total)" : "Reading spectrum…"
            DebugLog.scan("phase=readingData raw=\(result.raw.count) B elapsed=\(result.elapsedMS) ms")
            DebugLog.file("expected/received \(result.raw.count) B complete scan")

            scanPhase = .decoding
            scanProgressText = total > 1 ? "Decoding \(index) / \(total)" : "Decoding spectrum…"
            DebugLog.scan("phase=decoding")
            let decoded = try DLPSpectrumDecoder.decode(result.raw, keepRaw: true)

            // Attach protocol-side config (active index / count) without inventing fields.
            var cfg = decoded.config ?? ScanConfigInfo()
            if let existing = scanConfig {
                cfg.activeConfigIndex = existing.activeConfigIndex
                cfg.configCount = existing.configCount
            }
            let stored = Spectrum(
                timestamp: decoded.timestamp,
                points: decoded.points,
                temperature: decoded.temperature,
                humidity: decoded.humidity,
                detectorTemperature: decoded.detectorTemperature,
                serialNumber: decoded.serialNumber ?? result.serialNumber ?? deviceInfo?.serialNumber,
                configurationName: decoded.configurationName,
                pga: decoded.pga,
                source: decoded.source,
                raw: decoded.raw,
                config: cfg
            )

            recentScans.append(stored)
            spectrum = stored
            scanConfig = cfg
            await refreshReferenceAnalyses()
            DebugLog.scan("complete \(stored.points.count) points")
            return true
        } catch {
            scanPhase = .failed
            scanProgressText = nil
            lastError = humanMessage(for: error)
            statusMessage = nil
            DebugLog.scan("failed: \(error)")
            // Recover to a scannable state without tearing down USB unless disconnected.
            if isDeviceGone(error) {
                connectionState = .disconnected
                deviceInfo = nil
                await device.disconnect()
            }
            scanPhase = .idle
            return false
        }
    }

    private func computeAverage() {
        do {
            let avg = try SpectrumMath.average(recentScans)
            if let delta = SpectrumMath.maxWavelengthDelta(recentScans) {
                DebugLog.scan("wavelength consistency max|Δwl|=\(delta) nm")
            }
            averageSpectrum = avg
            lastError = nil
        } catch let e as SpectrumAverageError {
            averageSpectrum = nil
            lastError = e.userMessage
            displayMode = .individual
            DebugLog.scan("average rejected: \(e)")
        } catch {
            averageSpectrum = nil
            lastError = "Cannot average spectra."
        }
    }

    func clearSpectrum() {
        spectrum = nil
        recentScans = []
        averageSpectrum = nil
        referenceAnalyses = []
        statusMessage = nil
        lastError = nil
        scanPhase = .idle
        scanProgressText = nil
    }

    // MARK: - Save

    func saveCSV() {
        let scans = recentScans
        if scans.count > 1 {
            saveSession()
            return
        }
        guard let spectrum = recentScans.first ?? spectrum else { return }
        switch SessionSaver.saveSingleCSVWithRaw(
            spectrum: spectrum,
            serial: serialForFilename,
            saveRaw: saveRawEnabled,
            analysis: hasDerivedSpectrum ? referenceAnalyses.first : nil,
            referenceMetadata: hasDerivedSpectrum ? referenceExportMetadata : nil
        ) {
        case .success(let url):
            statusMessage = "Saved \(url.lastPathComponent)"
            lastError = nil
            DebugLog.app("saved \(url.path)")
        case .failure(let err):
            // Save failure must not touch connection state.
            lastError = err.userMessage
            DebugLog.app("save failed: \(err)")
        }
    }

    func saveSession() {
        let scans = recentScans.isEmpty ? (spectrum.map { [$0] } ?? []) : recentScans
        guard !scans.isEmpty else { return }
        switch SessionSaver.saveSession(
            scans: scans,
            average: averageSpectrum,
            serial: serialForFilename,
            saveRaw: saveRawEnabled,
            referenceAnalyses: hasDerivedSpectrum ? referenceAnalyses : [],
            referenceMetadata: hasDerivedSpectrum ? referenceExportMetadata : nil,
            averageAnalysis: averageReferenceAnalysis
        ) {
        case .success(let url):
            statusMessage = "Saved session \(url.lastPathComponent)"
            lastError = nil
            DebugLog.app("saved session \(url.path)")
        case .failure(let err):
            lastError = err.userMessage
            DebugLog.app("session save failed: \(err)")
        }
    }

    // MARK: - Display helpers

    var firmwareString: String? {
        guard let v = deviceInfo?.versions.tivaSW else { return nil }
        return String(format: "%d.%d.%d", (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    var headerStatusText: String {
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        }
    }

    private func mergeScanConfig(_ base: ScanConfigInfo?, active: Int?, count: Int?) -> ScanConfigInfo {
        var c = base ?? ScanConfigInfo()
        if let active { c.activeConfigIndex = active }
        if let count { c.configCount = count }
        return c
    }

    private func isDeviceGone(_ error: Error) -> Bool {
        if let e = error as? NIRProtocolError {
            switch e {
            case .deviceNotFound, .deviceDisconnected, .deviceOpenFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func humanMessage(for error: Error) -> String {
        if let e = error as? NIRProtocolError {
            return e.userMessage
        }
        if let e = error as? SpectrumDecodeError {
            return e.userMessage
        }
        if let e = error as? SpectrumAverageError {
            return e.userMessage
        }
        if let e = error as? ReferenceAnalysisError {
            return e.userMessage
        }
        if let e = error as? ReferenceStoreError {
            return e.description
        }
        return "Unexpected error."
    }
}
