import AppKit
import DLPSpec
import Foundation
import HIDTransport
import NIRDevice
import NIRProtocol
import UniformTypeIdentifiers

enum ConnectionState: Equatable {
    case disconnected
    case connected(serial: String)
}

@MainActor
final class SpectrometerController: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var deviceInfo: NIRDeviceInfo?
    @Published var spectrum: Spectrum?
    @Published var isScanning = false
    @Published var isConnecting = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let device = NIRDevice(debugLogging: false)
    private var pollTask: Task<Void, Never>?
    private var isConnected = false

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPresence()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        Task { await device.disconnect() }
    }

    private func pollPresence() async {
        let found = !NIRDevice.listDevices().isEmpty
        if found, !isConnected, !isScanning, !isConnecting {
            await connect()
        } else if !found, isConnected {
            if isScanning {
                errorMessage = "Device disconnected."
                isScanning = false
            }
            isConnected = false
            connectionState = .disconnected
            deviceInfo = nil
            statusMessage = "Spectrometer not found."
        }
    }

    func connect() async {
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        errorMessage = nil
        do {
            let usb = try await device.connect()
            isConnected = true
            connectionState = .connected(serial: usb.serialNumber ?? usb.product ?? "NIR-M-R2")
            if let info = try? await device.getDeviceInfo() {
                deviceInfo = info
                connectionState = .connected(serial: info.serialNumber)
            }
            statusMessage = nil
        } catch {
            connectionState = .disconnected
            isConnected = false
            errorMessage = humanMessage(for: error)
        }
        isConnecting = false
    }

    func disconnect() async {
        await device.disconnect()
        isConnected = false
        connectionState = .disconnected
    }

    func startScan() async {
        guard !isScanning else { return }
        guard isConnected else {
            errorMessage = "Spectrometer not found."
            return
        }
        isScanning = true
        errorMessage = nil
        statusMessage = "Scanning…"
        do {
            let result = try await device.runCompleteScan()
            let decoded = try DLPSpectrumDecoder.decode(result.raw)
            spectrum = decoded
            try Data(result.raw).write(to: URL(fileURLWithPath: "scan_complete.bin"))
            statusMessage = "Scan complete"
        } catch {
            errorMessage = humanMessage(for: error)
            statusMessage = nil
        }
        isScanning = false
    }

    func clearSpectrum() {
        spectrum = nil
        statusMessage = nil
        errorMessage = nil
    }

    func saveCSV() -> URL? {
        guard let spectrum else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "scan.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try spectrum.csvString().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved \(url.lastPathComponent)"
            return url
        } catch {
            errorMessage = "Could not save CSV."
            return nil
        }
    }

    var firmwareString: String? {
        guard let v = deviceInfo?.versions.tivaSW else { return nil }
        return String(format: "%d.%d.%d", (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    private func humanMessage(for error: Error) -> String {
        if let e = error as? NIRProtocolError {
            switch e {
            case .deviceNotFound: return "Spectrometer not found."
            case .deviceOpenFailed: return "Could not open spectrometer."
            case .usbWriteFailed: return "USB communication failed."
            case .usbReadTimeout: return "USB communication timed out."
            case .scanTimeout: return "Scan timed out."
            case .deviceDisconnected: return "Device disconnected."
            case .invalidScanData, .spectrumParseFailed: return "Scan failed."
            case .invalidPacket, .sequenceMismatch, .unexpectedCommand, .invalidPayloadLength:
                return "USB communication error."
            case .deviceBusy: return "Device busy. Try again."
            case .deviceError: return "Device error."
            }
        }
        if let e = error as? SpectrumDecodeError {
            return e.userMessage
        }
        return "Unexpected error."
    }
}
