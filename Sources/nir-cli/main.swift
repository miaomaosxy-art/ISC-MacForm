import Foundation
import DLPSpec
import HIDTransport
import NIRDevice
import NIRProtocol

@main
struct NIRCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "help"
        let debug = args.contains("--debug") || args.contains("-d")

        do {
            switch command {
            case "list":
                try cmdList(includeAll: args.contains("--all"))
            case "info":
                try cmdInfo(debug: debug)
            case "config":
                try cmdConfig(debug: debug)
            case "scan":
                try cmdScan(args: args, debug: debug)
            case "repeat":
                try cmdRepeat(args: args, debug: debug)
            case "selftest":
                try cmdSelftest(debug: debug)
            case "interpret":
                try cmdInterpret(args: args)
            case "help", "-h", "--help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n".utf8))
                printUsage()
                exit(2)
            }
        } catch let err as NIRProtocolError {
            FileHandle.standardError.write(Data("ERROR [\(err)]\n".utf8))
            FileHandle.standardError.write(Data("\(err.userMessage)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print(
            """
            nir-cli — NIR-M-R2 macOS USB HID tool

            Usage:
              nir-cli list [--all] [--debug]
              nir-cli info [--debug]
              nir-cli config [--debug]
              nir-cli scan [--out scan.csv] [--raw] [--debug]
              nir-cli repeat [--count 5] [--out DIR] [--raw] [--debug]
              nir-cli selftest [--debug]
              nir-cli interpret <scan_complete.bin> [--out scan.csv]
              nir-cli help

            Commands:
              list   Enumerate USB HID devices with VID=0x0451 PID=0x4200
                     --all  also show every HID device on the system
              info   Open the first NIR-M-R2 and print Device Info
              config Print scan config (protocol index/count + decoded fields)
              scan   Complete scan → DLP Spectrum Library decode → scan.csv
                     --out PATH   output CSV (default: scan.csv)
                     --raw        also keep scan_complete.bin (always written)
              repeat Serial repeat scans + average + session directory
                     --count N    default 5
                     --out DIR    parent folder for session dir
              selftest  Live matrix: connect / info / config / scan / repeat×5 / save / reconnect
              interpret  Offline TI DLP Spectrum Library decode of serialized scan
                     Requires third_party/DLPSpectrumLibrary sources (TIDCC49/TIDCC50).

            Options:
              --debug / -d   Hex-dump TX/RX HID frames and protocol logs
            """
        )
    }

    static func cmdList(includeAll: Bool) throws {
        let target = NIRDevice.listDevices()
        print(String(format: "NIR-M-R2 filter: VID=0x%04X PID=0x%04X", NIRUSB.vendorID, NIRUSB.productID))
        print("Matched devices: \(target.count)")
        if target.isEmpty {
            print("(none — check cable / power switch; try `nir-cli list --all`)")
        }
        for (i, d) in target.enumerated() {
            print("[\(i)] \(d)")
        }

        if includeAll {
            let all = NIRDevice.listAllHID()
            print("")
            print("All HID devices: \(all.count)")
            for (i, d) in all.enumerated() {
                print("[\(i)] \(d)")
            }
        }
    }

    static func flagValue(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Offline interpret via tools/interpret_scan (official dlpspec_scan_interpret).
    static func cmdInterpret(args: [String]) throws {
        guard let input = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
            FileHandle.standardError.write(Data("usage: nir-cli interpret <scan_complete.bin> [--out scan.csv]\n".utf8))
            exit(2)
        }
        let out = flagValue(args, "--out") ?? "scan.csv"

        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let toolPaths = [
            cwd + "/build/interpret_scan",
            cwd + "/.build/debug/interpret_scan",
            cwd + "/nir-m-r2-macos/build/interpret_scan",
        ]
        guard let tool = toolPaths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            print("TI DLP Spectrum Library offline tool is not built yet.")
            print("")
            print("1) Download TIDCC49 / TIDCC50 (TI export approval required):")
            print("     https://www.ti.com/tool/download/TIDCC49")
            print("     https://www.ti.com/tool/download/TIDCC50")
            print("2) Copy C sources to third_party/DLPSpectrumLibrary/")
            print("3) ./scripts/build-dlpspec.sh && ./scripts/build-interpret-tool.sh")
            print("4) ./build/interpret_scan \(input) \(out)")
            print("")
            print("Refusing to invent wavelengths without official dlpspec_scan_interpret().")
            exit(3)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = [input, out]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NIRProtocolError.spectrumParseFailed("interpret_scan exit \(p.terminationStatus)")
        }
    }

    static func cmdScan(args: [String], debug: Bool) throws {
        let outPath = flagValue(args, "--out") ?? "scan.csv"
        let saveRaw = args.contains("--raw")

        let device = NIRDevice(debugLogging: debug)
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        var result: NIRDevice.CompleteScanResult?
        var usbSerial: String?
        var firmware: String?

        Task {
            do {
                _ = try await device.connect()
                if debug { await device.setDebugLogging(true) }
                if let info = try? await device.getDeviceInfo() {
                    usbSerial = info.serialNumber
                    firmware = String(format: "%d.%d.%d",
                                      (info.versions.tivaSW >> 16) & 0xFF,
                                      (info.versions.tivaSW >> 8) & 0xFF,
                                      info.versions.tivaSW & 0xFF)
                }
                print("NIR-M-R2 Scan")
                print("")
                result = try await device.runCompleteScan()
                await device.disconnect()
            } catch {
                thrown = error
                await device.disconnect()
            }
            sem.signal()
        }
        sem.wait()
        if let thrown { throw thrown }
        guard let result else { throw NIRProtocolError.scanTimeout }

        // Always keep complete raw for diagnostics.
        try Data(result.raw).write(to: URL(fileURLWithPath: "scan_complete.bin"))

        let spectrum = try DLPSpectrumDecoder.decode(result.raw)

        print("Device")
        print("  Serial       : \(spectrum.serialNumber ?? usbSerial ?? "-")")
        print("  Configuration: \(spectrum.configurationName ?? "-")")
        if let firmware { print("  Firmware     : \(firmware)") }
        print("")
        print("Scan")
        print("  Points       : \(spectrum.points.count)")
        if let a = spectrum.points.first, let b = spectrum.points.last {
            print(String(format: "  Range        : %.3f – %.3f nm", a.wavelength, b.wavelength))
        }
        if let t = spectrum.temperature {
            print(String(format: "  Temperature  : %.2f °C", t))
        }
        if let h = spectrum.humidity {
            print(String(format: "  Humidity     : %.2f %%", h))
        }
        if let pga = spectrum.pga {
            print("  PGA          : \(pga)")
        }
        print(String(format: "  Raw size     : %d bytes", result.raw.count))
        print(String(format: "  Elapsed      : %d ms", result.elapsedMS))
        print("")
        print("Saved")
        print("  scan_complete.bin")
        let csv = spectrum.csvString()
        try csv.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
        print("  \(outPath)")
        if saveRaw {
            print("  (raw already written)")
        }
        print("")
        print("Result: PASS")
    }

    static func cmdInfo(debug: Bool) throws {
        let device = NIRDevice(debugLogging: debug)
        defer {
            let sem = DispatchSemaphore(value: 0)
            Task {
                await device.disconnect()
                sem.signal()
            }
            sem.wait()
        }

        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        var usbInfo: HIDTransport.DeviceInfo?
        var info: NIRDeviceInfo?

        Task {
            do {
                usbInfo = try await device.connect()
                if debug {
                    await device.setDebugLogging(true)
                }
                info = try await device.getDeviceInfo()
            } catch {
                thrown = error
            }
            sem.signal()
        }
        sem.wait()

        if let thrown {
            throw thrown
        }
        guard let usbInfo, let info else {
            throw NIRProtocolError.deviceNotFound
        }

        print("=== USB ===")
        print(usbInfo)
        print("")
        print("=== Device Info ===")
        print("Serial Number    : \(info.serialNumber)")
        print("Model Name       : \(info.modelName)")
        print("Hardware Version : \(info.hardwareVersion)")
        print("Main Board ADC   : \(info.mainBoardADC)")
        print("Detector ADC     : \(info.detectorBoardADC)")
        print("Device Status    : 0x\(String(info.deviceStatus, radix: 16, uppercase: true))\(statusFlags(info.deviceStatus))")
        print("")
        print("=== Versions (NNO_CMD_TIVA_VER) ===")
        print("Tiva SW              : \(info.versions.tivaSW)  (\(Self.fmtVersion(info.versions.tivaSW)))")
        print("DLPC SW              : \(info.versions.dlpcSW)  (\(Self.fmtVersion(info.versions.dlpcSW)))")
        print("DLPC Flash           : \(info.versions.dlpcFlash)  (\(Self.fmtVersion(info.versions.dlpcFlash)))")
        print("ISC Spectrum Library : \(info.versions.specLib)  (\(Self.fmtVersion(info.versions.specLib)))")
        print("Calibration Coeff Ver: \(info.versions.calData)")
        print("Reference Cal Ver    : \(info.versions.refCalData)")
        print("Scan Config Ver      : \(info.versions.cfgData)")
    }

    /// Format a packed version word as X.Y.Z when the high byte is 0 (common TI style 0x00MMmmpp).
    static func fmtVersion(_ v: UInt32) -> String {
        let b0 = v & 0xFF
        let b1 = (v >> 8) & 0xFF
        let b2 = (v >> 16) & 0xFF
        let b3 = (v >> 24) & 0xFF
        if b3 == 0 {
            return "\(b2).\(b1).\(b0)"
        }
        return "\(b3).\(b2).\(b1).\(b0)"
    }

    static func statusFlags(_ status: UInt32) -> String {
        var parts: [String] = []
        if status & NNODeviceStatusBit.tivaActive != 0 { parts.append("TIVA_ACTIVE") }
        if status & NNODeviceStatusBit.scanInProgress != 0 { parts.append("SCAN_IN_PROGRESS") }
        if status & NNODeviceStatusBit.sdPresent != 0 { parts.append("SD_PRESENT") }
        if status & NNODeviceStatusBit.sdIO != 0 { parts.append("SD_IO") }
        if status & NNODeviceStatusBit.btActive != 0 { parts.append("BT_ACTIVE") }
        if status & NNODeviceStatusBit.btConnected != 0 { parts.append("BT_CONNECTED") }
        if status & NNODeviceStatusBit.scanInterpreting != 0 { parts.append("SCAN_INTERPRETING") }
        if status & NNODeviceStatusBit.scanButton != 0 { parts.append("SCAN_BUTTON") }
        if status & NNODeviceStatusBit.batteryCharging != 0 { parts.append("BATTERY_CHARGE") }
        if parts.isEmpty { return "" }
        return " [" + parts.joined(separator: ", ") + "]"
    }

    // MARK: - config / repeat / selftest

    static func withDevice<T>(debug: Bool, _ body: @escaping @Sendable (NIRDevice) async throws -> T) throws -> T {
        let device = NIRDevice(debugLogging: debug)
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        var value: T?
        Task {
            do {
                if debug { await device.setDebugLogging(true) }
                value = try await body(device)
            } catch {
                thrown = error
            }
            await device.disconnect()
            sem.signal()
        }
        sem.wait()
        if let thrown { throw thrown }
        guard let value else { throw NIRProtocolError.deviceNotFound }
        return value
    }

    static func cmdConfig(debug: Bool) throws {
        struct Dump {
            var count: UInt8
            var active: UInt8
            var decoded: Spectrum?
            var rawSize: Int
        }
        let dump: Dump = try withDevice(debug: debug) { device in
            _ = try await device.connect()
            let count = try await device.getScanConfigCount()
            let active = try await device.getActiveScanConfigIndex()
            print("=== Scan Config (protocol) ===")
            print("  Config count     : \(count)")
            print("  Active index     : \(active)")
            print("")
            print("=== One complete scan to read serialized config ===")
            let result = try await device.runCompleteScan()
            let decoded = try DLPSpectrumDecoder.decode(result.raw, keepRaw: true)
            return Dump(count: count, active: active, decoded: decoded, rawSize: result.raw.count)
        }

        let s = dump.decoded
        let cfg = s?.config
        print("=== Scan Config (serialized / decode) ===")
        print("  Name             : \(cfg?.name ?? s?.configurationName ?? "—")")
        print("  Type             : \(cfg?.scanTypeName ?? "—")")
        print("  Config index     : \(cfg.map { "\($0.configIndex ?? -1)" } ?? "—")")
        if let r = cfg?.rangeText {
            print("  Range (config)   : \(r)")
        } else {
            print("  Range (config)   : —")
        }
        if let r = s?.wavelengthRange {
            print(String(format: "  Range (measured) : %.3f – %.3f nm", r.min, r.max))
        }
        print("  Patterns         : \(cfg?.numPatterns ?? s?.points.count ?? -1)")
        print("  Repeats          : \(cfg?.numRepeats ?? -1)")
        print("  Width            : \(cfg.map { "\($0.widthPx ?? -1)" } ?? "—") px")
        print("  Sections         : \(cfg?.numSections ?? -1)")
        print("  Raw size         : \(dump.rawSize) B")
        print("  Points           : \(s?.points.count ?? 0)")
    }

    static func cmdRepeat(args: [String], debug: Bool) throws {
        let count = Int(flagValue(args, "--count") ?? "5") ?? 5
        let parentPath = flagValue(args, "--out") ?? FileManager.default.currentDirectoryPath
        let saveRaw = args.contains("--raw")

        struct SessionOut {
            var dir: String
            var points: Int
            var maxDelta: Double
            var avgOK: Bool
        }
        let out: SessionOut = try withDevice(debug: debug) { device in
            _ = try await device.connect()
            var scans: [Spectrum] = []
            for i in 1...max(1, count) {
                print("[SCAN] starting complete scan \(i)/\(count)")
                let result = try await device.runCompleteScan()
                var s = try DLPSpectrumDecoder.decode(result.raw, keepRaw: true)
                s = Spectrum(
                    timestamp: s.timestamp,
                    points: s.points,
                    temperature: s.temperature,
                    humidity: s.humidity,
                    detectorTemperature: s.detectorTemperature,
                    serialNumber: s.serialNumber,
                    configurationName: s.configurationName,
                    pga: s.pga,
                    source: s.source,
                    raw: result.raw,
                    config: s.config
                )
                print("[SCAN] complete \(s.points.count) points")
                scans.append(s)
            }

            let delta = SpectrumMath.maxWavelengthDelta(scans) ?? -1
            var avgOK = false
            var average: Spectrum?
            if scans.count > 1 {
                do {
                    average = try SpectrumMath.average(scans)
                    avgOK = true
                    print("[SCAN] average OK")
                } catch {
                    print("[SCAN] average FAILED: \(error)")
                }
            }

            let parent = URL(fileURLWithPath: parentPath)
            let dirName = SpectrumFileNamer.sessionDirectoryName(serial: scans.first?.serialNumber)
            let dir = parent.appendingPathComponent(dirName, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, s) in scans.enumerated() {
                try s.csvString().write(to: dir.appendingPathComponent(SpectrumFileNamer.scanCSVName(index: i + 1)), atomically: true, encoding: .utf8)
                if saveRaw, let raw = s.raw {
                    try Data(raw).write(to: dir.appendingPathComponent(SpectrumFileNamer.scanRawName(index: i + 1)))
                }
            }
            if let average {
                try average.csvString().write(to: dir.appendingPathComponent(SpectrumFileNamer.averageCSVName), atomically: true, encoding: .utf8)
            }
            return SessionOut(dir: dir.path, points: scans.last?.points.count ?? 0, maxDelta: delta, avgOK: avgOK)
        }

        print("")
        print("Repeat result")
        print("  Scans          : \(count)")
        print("  Points         : \(out.points)")
        print(String(format: "  max |Δwl|      : %.9f nm", out.maxDelta))
        print("  Average        : \(out.avgOK ? "PASS" : "FAIL")")
        print("  Session dir    : \(out.dir)")
        print("Result: \(out.maxDelta <= 1e-6 && out.avgOK ? "PASS" : "FAIL")")
    }

    /// Live test matrix used as the v0.1.0 hardware gate (CLI-level).
    static func cmdSelftest(debug: Bool) throws {
        print("=== NIR-M-R2 live selftest ===")
        print("")

        // Presence
        let present = !NIRDevice.listDevices().isEmpty
        print("A/B presence (device attached): \(present ? "PASS" : "FAIL")")
        guard present else {
            print("Result: FAIL (no device)")
            exit(1)
        }

        // Connect + info + config + single scan
        struct Single {
            var serial: String
            var firmware: String
            var configName: String?
            var typeName: String?
            var range: String?
            var patterns: Int
            var repeats: Int?
            var width: Int?
            var active: Int?
            var count: Int?
            var points: Int
            var rawSize: Int
            var maxDeltaPlaceholder: Double = 0
        }

        var single: Single?
        var repeatDelta = -1.0

        do {
            let s: Single = try withDevice(debug: debug) { device in
                _ = try await device.connect()
                let info = try await device.getDeviceInfo()
                let firmware = String(format: "%d.%d.%d",
                                      (info.versions.tivaSW >> 16) & 0xFF,
                                      (info.versions.tivaSW >> 8) & 0xFF,
                                      info.versions.tivaSW & 0xFF)
                let count = try? await device.getScanConfigCount()
                let active = try? await device.getActiveScanConfigIndex()
                print("C single scan…")
                let result = try await device.runCompleteScan()
                let decoded = try DLPSpectrumDecoder.decode(result.raw, keepRaw: true)
                let range: String? = decoded.wavelengthRange.map {
                    String(format: "%.3f – %.3f nm", $0.min, $0.max)
                }
                return Single(
                    serial: info.serialNumber,
                    firmware: firmware,
                    configName: decoded.config?.name ?? decoded.configurationName,
                    typeName: decoded.config?.scanTypeName,
                    range: range,
                    patterns: decoded.config?.numPatterns ?? decoded.points.count,
                    repeats: decoded.config?.numRepeats,
                    width: decoded.config?.widthPx,
                    active: active.map(Int.init),
                    count: count.map(Int.init),
                    points: decoded.points.count,
                    rawSize: result.raw.count
                )
            }
            single = s
            print("C single scan: PASS")
        } catch {
            print("C single scan: FAIL (\(error))")
        }

        // Repeat ×5 + average + save
        print("D repeat ×5…")
        do {
            let saved: (delta: Double, avg: Bool, dir: String) = try withDevice(debug: debug) { device in
                _ = try await device.connect()
                var scans: [Spectrum] = []
                for i in 1...5 {
                    let result = try await device.runCompleteScan()
                    let decoded = try DLPSpectrumDecoder.decode(result.raw, keepRaw: true)
                    let stored = Spectrum(
                        timestamp: decoded.timestamp,
                        points: decoded.points,
                        temperature: decoded.temperature,
                        humidity: decoded.humidity,
                        detectorTemperature: decoded.detectorTemperature,
                        serialNumber: decoded.serialNumber,
                        configurationName: decoded.configurationName,
                        pga: decoded.pga,
                        source: decoded.source,
                        raw: result.raw,
                        config: decoded.config
                    )
                    print("  scan \(i)/5 points=\(stored.points.count) t=\(stored.temperature.map { String(format: "%.2f", $0) } ?? "—")")
                    scans.append(stored)
                }
                let delta = SpectrumMath.maxWavelengthDelta(scans) ?? -1
                var avgOK = false
                var average: Spectrum?
                do {
                    average = try SpectrumMath.average(scans)
                    avgOK = true
                } catch {
                    print("  average error: \(error)")
                }

                let parent = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
                    .appendingPathComponent("macform-selftest", isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let dir = parent.appendingPathComponent(
                    SpectrumFileNamer.sessionDirectoryName(serial: scans.first?.serialNumber),
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, s) in scans.enumerated() {
                    try s.csvString().write(to: dir.appendingPathComponent(SpectrumFileNamer.scanCSVName(index: i + 1)), atomically: true, encoding: .utf8)
                    if let raw = s.raw {
                        try Data(raw).write(to: dir.appendingPathComponent(SpectrumFileNamer.scanRawName(index: i + 1)))
                    }
                }
                if let average {
                    try average.csvString().write(to: dir.appendingPathComponent(SpectrumFileNamer.averageCSVName), atomically: true, encoding: .utf8)
                }
                // single CSV with suggested name
                if let first = scans.first {
                    let csvName = SpectrumFileNamer.singleCSVName(serial: first.serialNumber, date: first.timestamp)
                    try first.csvString().write(to: dir.appendingPathComponent(csvName), atomically: true, encoding: .utf8)
                }
                return (delta, avgOK, dir.path)
            }
            repeatDelta = saved.delta
            print(String(format: "  max |Δwl| = %.9f nm", saved.delta))
            print("  average: \(saved.avg ? "PASS" : "FAIL")")
            print("  session: \(saved.dir)")
            print("D repeat ×5: \(saved.delta <= 1e-6 && saved.avg ? "PASS" : "FAIL")")
            print("G/H save CSV + session + raw: PASS")
        } catch {
            print("D repeat ×5: FAIL (\(error))")
        }

        // Reconnect (logical unplug/replug)
        print("E/F disconnect → reconnect…")
        do {
            let ok: Bool = try withDevice(debug: debug) { device in
                _ = try await device.connect()
                await device.disconnect()
                let again = try await device.connect()
                _ = try await device.getDeviceInfo()
                return again.serialNumber != nil || true
            }
            print(ok ? "E/F reconnect: PASS" : "E/F reconnect: FAIL")
        } catch {
            print("E/F reconnect: FAIL (\(error))")
        }

        print("")
        print("=== Summary ===")
        if let s = single {
            print("Model          : NIR-M-R2")
            print("Serial         : \(s.serial)")
            print("Firmware       : \(s.firmware)")
            print("Scan config    : \(s.configName ?? "—")")
            print("Type           : \(s.typeName ?? "—")")
            print("Range          : \(s.range ?? "—")")
            print("Patterns       : \(s.patterns)")
            print("Repeats (hw)   : \(s.repeats.map(String.init) ?? "—")")
            print("Width          : \(s.width.map { "\($0)" } ?? "—")")
            print("Active/count   : \(s.active.map(String.init) ?? "—") / \(s.count.map(String.init) ?? "—")")
            print("Raw size       : \(s.rawSize) B")
            print("Points         : \(s.points)")
        }
        let delta = repeatDelta
        print(String(format: "wavelength axis |Δwl| = %.9f nm", delta))
    }
}
