import Charts
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = SpectrometerController()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            deviceSection
            Divider()
            scanSection
            Divider()
            spectrumSection
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private var header: some View {
        HStack {
            Text("NIR-M-R2")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        if controller.isScanning { return .orange }
        switch controller.connectionState {
        case .connected: return .green
        case .disconnected: return .red
        }
    }

    private var statusText: String {
        if controller.isScanning { return "Scanning" }
        switch controller.connectionState {
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Serial").foregroundStyle(.secondary)
                    Text(controller.deviceInfo?.serialNumber ?? "—")
                }
                GridRow {
                    Text("Firmware").foregroundStyle(.secondary)
                    Text(controller.firmwareString ?? "—")
                }
                GridRow {
                    Text("Config").foregroundStyle(.secondary)
                    Text(controller.spectrum?.configurationName ?? "—")
                }
            }
            .font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var scanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan")
                .font(.headline)
            HStack {
                Button {
                    Task { await controller.startScan() }
                } label: {
                    if controller.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Text("Start Scan")
                    }
                }
                .disabled(controller.isScanning || {
                    if case .connected = controller.connectionState { return false }
                    return true
                }())
                .keyboardShortcut(.defaultAction)

                Spacer()
            }

            HStack(spacing: 24) {
                labeled("Temperature", value: tempString)
                labeled("Humidity", value: humidityString)
                labeled("PGA", value: pgaString)
            }
            .font(.body.monospacedDigit())

            if let message = controller.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func labeled(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var tempString: String {
        guard let t = controller.spectrum?.temperature else { return "—" }
        return String(format: "%.2f °C", t)
    }

    private var humidityString: String {
        guard let h = controller.spectrum?.humidity else { return "—" }
        return String(format: "%.2f %%", h)
    }

    private var pgaString: String {
        guard let p = controller.spectrum?.pga else { return "—" }
        return "\(p)"
    }

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spectrum")
                .font(.headline)
            if let spectrum = controller.spectrum, !spectrum.points.isEmpty {
                Chart(spectrum.points, id: \.wavelength) { p in
                    LineMark(
                        x: .value("Wavelength (nm)", p.wavelength),
                        y: .value("Intensity", p.intensity)
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.linear)
                }
                .chartXAxisLabel("Wavelength (nm)")
                .chartYAxisLabel("Intensity")
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 220)
                .padding(.horizontal, 4)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    Text("No spectrum")
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Text(pointCountText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") {
                controller.clearSpectrum()
            }
            Button("Save CSV") {
                _ = controller.saveCSV()
            }
            .disabled(controller.spectrum == nil)
        }
        .padding(16)
    }

    private var pointCountText: String {
        guard let n = controller.spectrum?.points.count else { return "—" }
        return "\(n) points"
    }
}
