import Charts
import NIRDevice
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = SpectrometerController()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            deviceSection
            Divider()
            environmentSection
            Divider()
            spectrumSection
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("NIR-M-R2")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(controller.isScanning ? "Scanning" : controller.headerStatusText)
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
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    // MARK: - Device + configuration

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                    Text("Model").foregroundStyle(.secondary)
                    Text(controller.deviceInfo?.modelName ?? "—")
                }
            }
            .font(.body.monospacedDigit())

            Text("Configuration")
                .font(.headline)
                .padding(.top, 4)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    Text(controller.scanConfig?.name ?? controller.spectrum?.configurationName ?? "—")
                }
                GridRow {
                    Text("Type").foregroundStyle(.secondary)
                    Text(controller.scanConfig?.scanTypeName ?? "—")
                }
                GridRow {
                    Text("Range").foregroundStyle(.secondary)
                    Text(scanRangeText)
                }
                GridRow {
                    Text("Patterns").foregroundStyle(.secondary)
                    Text(patternText)
                }
                GridRow {
                    Text("Repeats").foregroundStyle(.secondary)
                    Text(repeatConfigText)
                }
                GridRow {
                    Text("Width").foregroundStyle(.secondary)
                    Text(widthText)
                }
                GridRow {
                    Text("Active").foregroundStyle(.secondary)
                    Text(activeIndexText)
                }
            }
            .font(.body.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var scanRangeText: String {
        if let t = controller.scanConfig?.rangeText { return t }
        if let r = controller.spectrum?.wavelengthRange {
            return String(format: "%.3f – %.3f nm", r.min, r.max)
        }
        return "—"
    }

    private var patternText: String {
        if let n = controller.scanConfig?.numPatterns { return "\(n)" }
        if let n = controller.spectrum?.points.count { return "\(n)" }
        return "—"
    }

    private var repeatConfigText: String {
        guard let n = controller.scanConfig?.numRepeats else { return "—" }
        return "\(n)"
    }

    private var widthText: String {
        guard let w = controller.scanConfig?.widthPx else { return "—" }
        return "\(w) px"
    }

    private var activeIndexText: String {
        var parts: [String] = []
        if let i = controller.scanConfig?.activeConfigIndex { parts.append("#\(i)") }
        if let c = controller.scanConfig?.configCount { parts.append("of \(c)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    // MARK: - Environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environment")
                .font(.headline)
            HStack(spacing: 24) {
                labeled("Temperature", value: tempString)
                labeled("Humidity", value: humidityString)
                labeled("PGA", value: pgaString)
                Spacer()
            }
            .font(.body.monospacedDigit())

            HStack(spacing: 16) {
                Toggle("Debug Logging", isOn: $controller.debugLoggingEnabled)
                    .toggleStyle(.checkbox)
                Toggle("Save Raw Scan Data", isOn: $controller.saveRawEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .font(.caption)

            if let progress = controller.scanProgressText {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.callout.monospacedDigit())
                }
            }
            if let message = controller.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
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

    // MARK: - Spectrum chart

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Spectrum")
                    .font(.headline)
                Spacer()
                if controller.recentScans.count > 1 {
                    Picker("Display", selection: $controller.displayMode) {
                        ForEach(SpectrumDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }
            }

            let series = controller.displayedSeries
            if series.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    Text(controller.connectionState == .disconnected
                         ? "No spectrometer connected"
                         : "No spectrum")
                        .foregroundStyle(.tertiary)
                }
                .frame(height: 240)
            } else {
                Chart {
                    ForEach(Array(series.enumerated()), id: \.offset) { idx, scan in
                        ForEach(scan.points, id: \.wavelength) { p in
                            LineMark(
                                x: .value("Wavelength (nm)", p.wavelength),
                                y: .value("Intensity", p.intensity)
                            )
                            .foregroundStyle(by: .value("Scan", seriesLabel(idx: idx, count: series.count)))
                            .interpolationMethod(.linear)
                        }
                    }
                }
                .chartForegroundStyleScale(range: chartColors(count: series.count))
                .chartXAxisLabel("Wavelength (nm)")
                .chartYAxisLabel("Intensity")
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXScale(domain: xDomain(series))
                .chartLegend(series.count > 1 ? .visible : .hidden)
                .frame(height: 240)
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func seriesLabel(idx: Int, count: Int) -> String {
        if count == 1, controller.displayMode == .average {
            return "Average"
        }
        return String(format: "Scan %03d", idx + 1)
    }

    private func chartColors(count: Int) -> [Color] {
        if count == 1 { return [.accentColor] }
        var colors: [Color] = [.blue, .green, .orange, .purple, .pink, .red, .teal, .indigo]
        if count > colors.count {
            colors = (0..<count).map { i in
                Color(hue: Double(i) / Double(count), saturation: 0.7, brightness: 0.75)
            }
        }
        return Array(colors.prefix(max(count, 1)))
    }

    /// Axis domain from actual spectrum wavelengths — never hard-code 900–1700.
    private func xDomain(_ series: [Spectrum]) -> ClosedRange<Double> {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for s in series {
            for p in s.points {
                lo = min(lo, p.wavelength)
                hi = max(hi, p.wavelength)
            }
        }
        if lo > hi { return 900...1700 }
        return lo...hi
    }

    // MARK: - Footer actions

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Repeat Count:")
                    .foregroundStyle(.secondary)
                Picker("Repeat Count", selection: $controller.repeatCount) {
                    ForEach([1, 3, 5, 10], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .disabled(controller.isScanning)

                Spacer()
                Text(controller.pointCountText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Scan") {
                    Task { await controller.startScan() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canScan)

                Button("Repeat Scan") {
                    Task { await controller.startRepeatScan() }
                }
                .disabled(!controller.canScan)

                Button("Save CSV") {
                    controller.saveCSV()
                }
                .disabled(!controller.canSave || controller.isScanning)

                Button("Save Session") {
                    controller.saveSession()
                }
                .disabled(controller.recentScans.count < 2 || controller.isScanning)

                Spacer()

                Button("Clear") {
                    controller.clearSpectrum()
                }
                .disabled(controller.isScanning || (!controller.canSave && controller.lastError == nil))
            }
        }
        .padding(16)
    }
}
