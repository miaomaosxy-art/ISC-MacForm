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
              nir-cli help

            Commands:
              list   Enumerate USB HID devices with VID=0x0451 PID=0x4200
                     --all  also show every HID device on the system
              info   Open the first NIR-M-R2 and print Device Info
                     (Serial, Model, Firmware/HW versions, Device Status)

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
