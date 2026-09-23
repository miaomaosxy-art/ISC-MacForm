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
            case "scan":
                try cmdScan(args: args, debug: debug)
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
              nir-cli scan [--out scan.csv] [--raw] [--debug]
              nir-cli interpret <scan_complete.bin> [--out scan.csv]
              nir-cli help

            Commands:
              list   Enumerate USB HID devices with VID=0x0451 PID=0x4200
                     --all  also show every HID device on the system
              info   Open the first NIR-M-R2 and print Device Info
              scan   Complete scan → DLP Spectrum Library decode → scan.csv
                     --out PATH   output CSV (default: scan.csv)
                     --raw        also keep scan_complete.bin (always written)
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
}
