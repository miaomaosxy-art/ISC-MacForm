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
    private var pollTask: Task<Void, Never>?

    private var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isScanning: Bool { scanPhase.isBusy }

    var canScan: Bool {
        isConnected && !scanPhase.isBusy
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
            await refreshScanConfig()
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

    // MARK: - Scan state machine

    func startScan() async {
        await runScans(count: 1, isRepeat: false)
    }

    func startRepeatScan() async {
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
            saveRaw: saveRawEnabled
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
            saveRaw: saveRawEnabled
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
        return "Unexpected error."
    }
}

