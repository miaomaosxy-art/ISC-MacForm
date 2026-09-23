import Foundation
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
              nir-cli help

            Commands:
              list   Enumerate USB HID devices with VID=0x0451 PID=0x4200
                     --all  also show every HID device on the system
              info   Open the first NIR-M-R2 and print Device Info
              scan   Run a Simplex scan (PERFORM_SCAN 0x5A) and save wavelength/intensity CSV
                     --out PATH   output CSV (default: scan.csv)
                     --raw        also save scan_wavelength.bin / scan_intensity.bin

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

    static func cmdScan(args: [String], debug: Bool) throws {
        let outPath = flagValue(args, "--out") ?? "scan.csv"
        let saveRaw = args.contains("--raw")

        let device = NIRDevice(debugLogging: debug)
        let sem = DispatchSemaphore(value: 0)
        var thrown: Error?
        var artifacts: NIRDevice.ScanArtifacts?

        Task {
            do {
                _ = try await device.connect()
                if debug { await device.setDebugLogging(true) }
                print("[NIR] Starting Simplex scan (PERFORM_SCAN flag=0x5A)…")
                artifacts = try await device.runSimplexScan()
                await device.disconnect()
            } catch {
                thrown = error
                await device.disconnect()
            }
            sem.signal()
        }
        sem.wait()
        if let thrown { throw thrown }
        guard let artifacts else { throw NIRProtocolError.scanTimeout }

        print("Mode                : \(artifacts.mode)")
        print("Estimated scan time : \(artifacts.estimatedScanTimeMS) ms")
        print("Elapsed             : \(artifacts.elapsedMS) ms")
        print("Wavelength raw      : \(artifacts.wavelengthRaw.count) bytes")
        print("Intensity raw       : \(artifacts.intensityRaw.count) bytes")
        print("Complete scan raw   : \(artifacts.completeScanRaw.count) bytes")
        print("Interpret raw       : \(artifacts.interpretRaw.count) bytes")

        if saveRaw || artifacts.spectrum == nil {
            if !artifacts.wavelengthRaw.isEmpty {
                try Data(artifacts.wavelengthRaw).write(to: URL(fileURLWithPath: "scan_wavelength.bin"))
            }
            if !artifacts.intensityRaw.isEmpty {
                try Data(artifacts.intensityRaw).write(to: URL(fileURLWithPath: "scan_intensity.bin"))
            }
            if !artifacts.completeScanRaw.isEmpty {
                try Data(artifacts.completeScanRaw).write(to: URL(fileURLWithPath: "scan_complete.bin"))
            }
            if !artifacts.interpretRaw.isEmpty {
                try Data(artifacts.interpretRaw).write(to: URL(fileURLWithPath: "scan_interpret.bin"))
            }
            print("Saved raw           : scan_*.bin")
        }

        guard let spectrum = artifacts.spectrum else {
            print("")
            print("NOTE: No host-side dlpspec / Simplex wavelength array on this firmware.")
            print("      Active config is Hadamard (see scan_complete.bin \"Hadamard 1\").")
            print("      scan_complete.bin  = NNO_FILE_SCAN_DATA (serialized, needs dlpspec_scan_interpret)")
            print("      scan_interpret.bin = NNO_FILE_INTERPRET_DATA (device-side interpret, layout TBD)")
            print("      Refusing to invent wavelength_nm. Use raw files or supply dlpspec.")
            throw NIRProtocolError.spectrumParseFailed(
                "raw saved (complete=\(artifacts.completeScanRaw.count)B interpret=\(artifacts.interpretRaw.count)B). Hadamard scan needs dlpspec for wavelengths."
            )
        }

        let first = spectrum.points.first
        let last = spectrum.points.last
        print("Points              : \(spectrum.points.count)")
        if let first, let last {
            print(String(format: "Wavelength range    : %.3f – %.3f nm", first.wavelength, last.wavelength))
        }
        print(String(format: "Intensity range     : %d – %d",
                     spectrum.points.map(\.intensity).min() ?? 0,
                     spectrum.points.map(\.intensity).max() ?? 0))

        var meta: [String: String] = [
            "device": "NIR-M-R2",
            "source": "simplex",
            "estimated_scan_ms": "\(artifacts.estimatedScanTimeMS)",
            "elapsed_ms": "\(artifacts.elapsedMS)",
        ]
        if let sn = artifacts.serialNumber { meta["serial"] = sn }

        let csv = NIRDevice.csvString(from: spectrum, metadata: meta)
        try csv.write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
        print("Saved CSV           : \(outPath)")

        // Preview first/last few rows
        print("")
        print("wavelength_nm,intensity")
        let preview = spectrum.points.prefix(3) + spectrum.points.suffix(3)
        for p in preview {
            print(String(format: "%.3f,%d", p.wavelength, p.intensity))
        }
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
