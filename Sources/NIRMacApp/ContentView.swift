import Charts
import DLPSpec
import NIRDevice
import SwiftUI

struct ContentView: View {
    @StateObject private var controller = SpectrometerController()
    @State private var showWhiteReferencePrompt = false
    @Environment(\.colorScheme) private var colorScheme

    private var theme: Theme { Theme(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border).frame(height: 1)
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        spectrumCard
                        metrics
                        messageBanner
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(spacing: 16) {
                        acquisitionCard
                        referenceCard
                        instrumentCard
                        configurationCard
                        dataCard
                    }
                    .frame(width: 286)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.canvas)
        .frame(minWidth: 860, minHeight: 620)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .onChange(of: controller.referenceSource) { _ in
            Task { await controller.prepareReferenceSource() }
        }
        .alert("Reference Scan", isPresented: $showWhiteReferencePrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Scan white reference") {
                Task { await controller.scanNewReference() }
            }
        } message: {
            Text("Please place the reference sample and start the reference scan.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 44, height: 44)
                .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("SPECTRA")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(1.5)
                Text("NIR-M-R2 acquisition workspace")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(controller.isScanning ? "Scanning" : controller.headerStatusText)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(statusColor.opacity(0.12), in: Capsule())
            .accessibilityLabel("Device status: \(controller.isScanning ? "Scanning" : controller.headerStatusText)")
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
    }

    private var statusColor: Color {
        if controller.isScanning { return theme.warning }
        switch controller.connectionState {
        case .connected: return theme.success
        case .connecting, .reconnecting: return theme.warning
        case .disconnected: return theme.muted
        }
    }

    private var spectrumCard: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Spectrum").font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text("Wavelength spectrum from the latest acquisition")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                HStack(spacing: 12) {
                    Picker("Spectrum view", selection: $controller.quantity) {
                        ForEach(SpectrumQuantity.allCases) { quantity in
                            Text(quantity.rawValue).tag(quantity)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 320)
                    if controller.recentScans.count > 1 &&
                        (controller.quantity == .intensity || controller.canAverageDerived) {
                        Picker("Display", selection: $controller.displayMode) {
                            Text("Individual").tag(SpectrumDisplayMode.individual)
                            Text("Average").tag(SpectrumDisplayMode.average)
                        }
                        .pickerStyle(.menu).frame(width: 110)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 18)
                separator.padding(.vertical, 18)
                if controller.displayedPlotSeries.allSatisfy({ $0.points.isEmpty }) { emptySpectrum } else { chart }
                separator.padding(.top, 18).padding(.bottom, 15)
                HStack(spacing: 12) {
                    chartStat("WAVELENGTH", scanRangeText)
                    Spacer(minLength: 0)
                    chartStat("DATA POINTS", controller.spectrum.map { "\($0.points.count)" } ?? "—")
                    Spacer(minLength: 0)
                    chartStat("SCANS", "\(controller.recentScans.count)")
                }
            }
            .padding(22)
        }
    }

    private var emptySpectrum: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(theme.plot)
            VStack(spacing: 12) {
                Image(systemName: controller.referenceError != nil && controller.quantity != .intensity
                      ? "exclamationmark.triangle" : controller.connectionState == .disconnected
                      ? "cable.connector.slash" : "waveform.path")
                    .font(.system(size: 39, weight: .ultraLight))
                    .foregroundStyle(theme.accent)
                    .frame(width: 82, height: 82)
                    .background(theme.accent.opacity(0.10), in: Circle())
                Text(controller.referenceError != nil && controller.quantity != .intensity
                     ? "Reference unavailable" : controller.connectionState == .disconnected
                     ? "Waiting for spectrometer" : "Ready to capture")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text(controller.referenceError != nil && controller.quantity != .intensity
                     ? (controller.referenceError ?? "Reference unavailable") : controller.connectionState == .disconnected
                     ? "Connect your NIR-M-R2 to begin measuring."
                     : "Select Scan to collect your first spectrum.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .frame(height: 330)
    }

    private var chart: some View {
        let series = controller.displayedPlotSeries
        return Chart {
            ForEach(series) { scan in
                ForEach(scan.points) { point in
                    LineMark(x: .value("Wavelength (nm)", point.wavelength),
                             y: .value(controller.quantity.axisTitle, point.value))
                        .foregroundStyle(by: .value("Scan", scan.label))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: series.count == 1 ? 2.5 : 1.7))
                }
            }
        }
        .chartForegroundStyleScale(range: chartColors(series.count))
        .chartXAxisLabel("Wavelength (nm)")
        .chartYAxisLabel(controller.quantity.axisTitle)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXScale(domain: xDomain(series))
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .frame(height: 330).padding(.horizontal, 4)
    }

    private func chartStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metric("Temperature", tempString, "thermometer.medium")
            metric("Humidity", humidityString, "humidity")
            metric("Gain (PGA)", pgaString, "slider.horizontal.3")
        }
    }

    private func metric(_ label: String, _ value: String, _ symbol: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 15) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(value).font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }
    }

    @ViewBuilder private var messageBanner: some View {
        if controller.isScanning || bannerMessage != nil {
            HStack(spacing: 11) {
                if controller.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: bannerIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(bannerIsError ? theme.warning : theme.success)
                }
                Text(controller.scanProgressText ?? bannerMessage ?? "Working…")
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border))
        }
    }

    private var bannerIsError: Bool {
        controller.lastError != nil || controller.referenceError != nil ||
        (controller.quantity == .absorbance && controller.invalidAbsorbanceCount > 0) ||
        (controller.quantity == .reflectance && controller.invalidReflectanceCount > 0)
    }

    private var bannerMessage: String? {
        if let error = controller.lastError { return error }
        if controller.quantity != .intensity, let error = controller.referenceError { return error }
        if controller.quantity == .absorbance && controller.invalidAbsorbanceCount > 0 {
            return "\(controller.invalidAbsorbanceCount) points have nonpositive sample/reference ratios and are omitted."
        }
        if controller.quantity == .reflectance && controller.invalidReflectanceCount > 0 {
            return "\(controller.invalidReflectanceCount) points have nonpositive sample/reference intensities and are omitted."
        }
        return controller.statusMessage
    }

    private var instrumentCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Instrument", "cable.connector")
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(controller.headerStatusText).font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(12).background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                detail("Model", controller.deviceInfo?.modelName ?? "NIR-M-R2")
                detail("Serial", controller.deviceInfo?.serialNumber ?? "—")
                detail("Firmware", controller.firmwareString ?? "—")
            }
            .padding(18)
        }
    }

    private var referenceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 15) {
                sectionHeader("Reference source", "square.on.square")
                Picker("Reference source", selection: $controller.referenceSource) {
                    ForEach(ReferenceSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(controller.isScanning)
                Text(controller.referenceStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = controller.referenceError {
                    Text(error).font(.caption).foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reference = controller.referenceDetails {
                    detail("Time", reference.timestamp?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    detail("Config", reference.configName ?? "—")
                    detail("PGA", reference.pga.map(String.init) ?? "—")
                }
            }
            .padding(18)
        }
    }

    private var acquisitionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 17) {
                sectionHeader("Acquisition", "waveform.path")
                VStack(alignment: .leading, spacing: 4) {
                    Text("ACTIVE METHOD").font(.system(size: 10, weight: .semibold))
                        .tracking(1).foregroundStyle(.secondary)
                    Text(controller.scanConfig?.name ?? controller.spectrum?.configurationName ?? "No configuration loaded")
                        .font(.callout.weight(.medium)).lineLimit(2)
                    if let type = controller.scanConfig?.scanTypeName {
                        Text(type).font(.caption).foregroundStyle(.secondary)
                    }
                }
                separator
                HStack {
                    Text("Repeat count").font(.callout)
                    Spacer()
                    Picker("Repeat count", selection: $controller.repeatCount) {
                        ForEach([1, 3, 5, 10], id: \.self) { count in
                            Text("\(count) scans").tag(count)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 100)
                    .disabled(controller.isScanning)
                }
                Button {
                    if controller.referenceSource == .new {
                        showWhiteReferencePrompt = true
                    } else {
                        Task { await controller.startScan() }
                    }
                } label: {
                    Label(controller.referenceSource == .new ? "Reference Scan" : "Scan",
                          systemImage: controller.referenceSource == .new ? "scope" : "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(controller.referenceSource == .new ? !controller.canScan : !controller.canSampleScan)
                Button {
                    Task { await controller.startRepeatScan() }
                } label: {
                    Label("Repeat scan", systemImage: "repeat").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large).disabled(!controller.canSampleScan)
            }
            .padding(18)
        }
    }

    private var configurationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 15) {
                sectionHeader("Scan configuration", "square.stack.3d.up")
                detail("Range", scanRangeText)
                detail("Patterns", patternText)
                detail("Repeats", repeatConfigText)
                detail("Width", widthText)
                detail("Active", activeIndexText)
            }
            .padding(18)
        }
    }

    private var dataCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Data & options", "square.and.arrow.down")
                HStack(spacing: 8) {
                    Button { controller.saveCSV() } label: {
                        Label(controller.hasDerivedSpectrum ? "Save CSV" : "Intensity CSV",
                              systemImage: "tablecells").frame(maxWidth: .infinity)
                    }
                    .disabled(!controller.canSave || controller.isScanning)
                    Button { controller.saveSession() } label: {
                        Label("Session", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .disabled(controller.recentScans.count < 2 || controller.isScanning)
                }
                .buttonStyle(.bordered)
                Toggle("Save raw scan data", isOn: $controller.saveRawEnabled)
                Toggle("Debug logging", isOn: $controller.debugLoggingEnabled)
                Button("Clear spectrum", role: .destructive) { controller.clearSpectrum() }
                    .buttonStyle(.plain).font(.caption)
                    .disabled(controller.isScanning || (!controller.canSave && controller.lastError == nil))
            }
            .font(.callout).padding(18)
        }
    }

    private func sectionHeader(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(theme.accent)
            Text(title).foregroundStyle(.primary)
        }
        .font(.system(.headline, design: .rounded))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(.callout, design: .monospaced))
                .multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }
        .font(.callout)
    }

    private var separator: some View { Rectangle().fill(theme.border).frame(height: 1) }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.border))
    }

    private var scanRangeText: String {
        if let text = controller.scanConfig?.rangeText { return text }
        if let range = controller.spectrum?.wavelengthRange {
            return String(format: "%.1f–%.1f nm", range.min, range.max)
        }
        return "—"
    }
    private var patternText: String {
        if let count = controller.scanConfig?.numPatterns { return "\(count)" }
        if let count = controller.spectrum?.points.count { return "\(count)" }
        return "—"
    }
    private var repeatConfigText: String {
        guard let count = controller.scanConfig?.numRepeats else { return "—" }
        return "\(count)"
    }
    private var widthText: String {
        guard let width = controller.scanConfig?.widthPx else { return "—" }
        return "\(width) px"
    }
    private var activeIndexText: String {
        var parts: [String] = []
        if let index = controller.scanConfig?.activeConfigIndex { parts.append("#\(index)") }
        if let count = controller.scanConfig?.configCount { parts.append("of \(count)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }
    private var tempString: String {
        guard let value = controller.spectrum?.temperature else { return "—" }
        return String(format: "%.2f °C", value)
    }
    private var humidityString: String {
        guard let value = controller.spectrum?.humidity else { return "—" }
        return String(format: "%.2f %%", value)
    }
    private var pgaString: String {
        guard let value = controller.spectrum?.pga else { return "—" }
        return "\(value)"
    }
    private func chartColors(_ count: Int) -> [Color] {
        if count == 1 { return [theme.accent] }
        let colors: [Color] = [theme.accent, .blue, .orange, .purple, .pink, .green, .indigo]
        if count <= colors.count { return Array(colors.prefix(count)) }
        return (0..<count).map { Color(hue: Double($0) / Double(count), saturation: 0.72, brightness: 0.82) }
    }
    private func xDomain(_ series: [SpectrumPlotSeries]) -> ClosedRange<Double> {
        let wavelengths = series.flatMap { $0.points.map(\.wavelength) }
        guard let minimum = wavelengths.min(), let maximum = wavelengths.max() else { return 0...1 }
        return minimum == maximum ? (minimum - 1)...(maximum + 1) : minimum...maximum
    }
}

private struct Theme {
    let dark: Bool
    var canvas: Color { dark ? Color(red: 0.055, green: 0.075, blue: 0.10) : Color(red: 0.945, green: 0.96, blue: 0.97) }
    var card: Color { dark ? Color(red: 0.095, green: 0.125, blue: 0.16) : .white }
    var plot: Color { dark ? Color(red: 0.075, green: 0.105, blue: 0.14) : Color(red: 0.965, green: 0.975, blue: 0.98) }
    var border: Color { dark ? .white.opacity(0.09) : .black.opacity(0.07) }
    var accent: Color { Color(red: 0.10, green: 0.65, blue: 0.62) }
    var success: Color { Color(red: 0.19, green: 0.69, blue: 0.44) }
    var warning: Color { Color(red: 0.92, green: 0.57, blue: 0.22) }
    var muted: Color { dark ? .gray : Color(red: 0.44, green: 0.49, blue: 0.54) }
}
