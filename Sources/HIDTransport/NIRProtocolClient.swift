import Foundation
import NIRProtocol

/// NIR command/response exchange over HIDTransport.
/// Sequence validation and multi-packet reassembly live here, not in UI or device policy.
public final class NIRProtocolClient: @unchecked Sendable {
    private let transport: HIDTransport
    private var nextSequence: UInt8 = 0
    public var isDebugLoggingEnabled: Bool {
        get { transport.isDebugLoggingEnabled }
        set { transport.isDebugLoggingEnabled = newValue }
    }

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    // MARK: - Request / response

    /// Send one command and collect one matching response frame.
    public func sendCommand(
        group: UInt8,
        command: UInt8,
        payload: [UInt8] = [],
        flags: UInt8 = NIRFlag.readReply,
        timeoutMS: Int = NIRExchange.defaultTimeoutMS
    ) throws -> NIRFrame.Decoded {
        let seq = takeSequence()
        let hidBuf = NIRFrame.encodeHIDWrite(
            flags: flags,
            sequence: seq,
            command: command,
            group: group,
            payload: payload
        )
        try transport.write(hidBuf)

        // Device may return a short delay; try a few reads within timeout budget.
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            let remainingMS = max(50, Int(deadline.timeIntervalSinceNow * 1000))
            let raw: [UInt8]
            do {
                raw = try transport.read(timeoutMS: min(remainingMS, timeoutMS))
            } catch NIRProtocolError.usbReadTimeout {
                continue
            }
            let decoded = try decodeFlexible(raw)
            try validateResponse(decoded, expectedSeq: seq, command: command, group: group)
            return decoded
        }
        throw NIRProtocolError.usbReadTimeout
    }

    public func writeCommand(
        group: UInt8,
        command: UInt8,
        payload: [UInt8] = [],
        timeoutMS: Int = NIRExchange.defaultTimeoutMS
    ) throws -> NIRFrame.Decoded {
        try sendCommand(
            group: group,
            command: command,
            payload: payload,
            flags: NIRFlag.writeReply,
            timeoutMS: timeoutMS
        )
    }

    // MARK: - High-level typed helpers (Device Info)

    public func readVersions() throws -> NIRVersions {
        let resp = try sendCommand(group: NNOGroup.system.rawValue, command: NNOSystemCommand.tivaVersion)
        return try NIRVersions.parse(resp.payload)
    }

    public func readSerialNumber() throws -> String {
        let resp = try sendCommand(group: NNOGroup.system.rawValue, command: NNOSystemCommand.serialNumberRead)
        guard resp.payload.count >= NNOPayloadSize.serialNumber else {
            throw NIRProtocolError.invalidPayloadLength(
                expected: NNOPayloadSize.serialNumber,
                actual: resp.payload.count
            )
        }
        return NIRLE.asciiCString(resp.payload)
    }

    public func readDeviceStatus() throws -> UInt32 {
        let resp = try sendCommand(group: NNOGroup.status.rawValue, command: NNOStatusCommand.readDeviceStatus)
        guard resp.payload.count >= NNOPayloadSize.deviceStatus else {
            throw NIRProtocolError.invalidPayloadLength(
                expected: NNOPayloadSize.deviceStatus,
                actual: resp.payload.count
            )
        }
        return try NIRLE.u32(resp.payload)
    }

    /// Hardware version + detector/main board ADC (Table 1-1 NNO_CMD_GET_BOARD_LEVEL).
    /// First 8 bytes are versions as X.X.X.X pairs: main / DMD / detector / optical engine.
    public func readBoardLevel() throws -> (versions: [UInt8], mainADC: UInt32, detectorADC: UInt32) {
        let resp = try sendCommand(group: NNOGroup.sensor.rawValue, command: NNOSensorCommand.getBoardLevel)
        guard resp.payload.count >= NNOPayloadSize.boardLevel else {
            throw NIRProtocolError.invalidPayloadLength(
                expected: NNOPayloadSize.boardLevel,
                actual: resp.payload.count
            )
        }
        let verBytes = Array(resp.payload[0..<8])
        let mainADC = try NIRLE.u32(resp.payload, at: 8)
        let detectorADC = try NIRLE.u32(resp.payload, at: 12)
        return (verBytes, mainADC, detectorADC)
    }

    public func readModelName() throws -> String {
        // Prefer 0x03/0xFD (Table 1-1 "Read model name", 0 in / 16 out).
        // 0x02/0x3C in/out columns look swapped in the PDF.
        let resp = try sendCommand(group: NNOGroup.sensor.rawValue, command: NNOSensorCommand.readModelName)
        guard resp.payload.count >= NNOPayloadSize.modelName else {
            throw NIRProtocolError.invalidPayloadLength(
                expected: NNOPayloadSize.modelName,
                actual: resp.payload.count
            )
        }
        return NIRLE.asciiCString(resp.payload)
    }

    // MARK: - File read pair (scan data)

    public func readFileSize(fileType: NNOFileType) throws -> UInt32 {
        let resp = try sendCommand(
            group: NNOGroup.file.rawValue,
            command: NNOFileCommand.getReadSize,
            payload: [fileType.rawValue]
        )
        guard resp.payload.count >= NNOPayloadSize.fileReadSize else {
            throw NIRProtocolError.invalidPayloadLength(
                expected: NNOPayloadSize.fileReadSize,
                actual: resp.payload.count
            )
        }
        return try NIRLE.u32(resp.payload)
    }

    /// Read a "file" via NNO_CMD_FILE_GET_READSIZE + NNO_CMD_FILE_GET_DATA.
    ///
    /// USB continuation layout is not fully specified in the PDF. Strategy:
    /// issue GET_DATA once, then keep reading reports and concatenate data
    /// bytes after the 7-byte frame header until `expectedSize` is reached.
    /// Raw reports are kept when debug is on so real-device layout can be adjusted
    /// without inventing offsets.
    public func readFile(
        fileType: NNOFileType,
        timeoutMS: Int = NIRExchange.defaultTimeoutMS
    ) throws -> [UInt8] {
        let expected = Int(try readFileSize(fileType: fileType))
        transport.log("[NIR] Reading file type=0x\(String(fileType.rawValue, radix: 16, uppercase: true)) size=\(expected) bytes")

        guard expected > 0 else { return [] }

        let seq = takeSequence()
        let hidBuf = NIRFrame.encodeHIDWrite(
            flags: NIRFlag.readReply,
            sequence: seq,
            command: NNOFileCommand.getData,
            group: NNOGroup.file.rawValue,
            payload: []
        )
        try transport.write(hidBuf)

        var body = [UInt8]()
        body.reserveCapacity(expected)
        let deadline = Date().addingTimeInterval(Double(max(timeoutMS, expected / 2 + 2000)) / 1000.0)

        while body.count < expected && Date() < deadline {
            let raw: [UInt8]
            do {
                raw = try transport.read(timeoutMS: NIRExchange.defaultTimeoutMS)
            } catch NIRProtocolError.usbReadTimeout {
                continue
            }

            // Extract data after header when this looks like a framed report.
            let chunk = extractFileChunk(from: raw, expectedCommand: NNOFileCommand.getData)
            body.append(contentsOf: chunk)

            // Fallback: if framing detection produced nothing useful but raw looks like pure payload,
            // append the report without the leading report-id byte.
            if chunk.isEmpty, raw.count > 1 {
                // Keep going only if we still need bytes; do not invent — dump is available via debug.
                transport.log("[NIR] WARN: no framed chunk in report (\(raw.count) bytes); raw dump follows")
                transport.logHex(prefix: "RX", data: raw)
            }
        }

        guard body.count >= expected else {
            throw NIRProtocolError.invalidScanData(
                "file read incomplete: got \(body.count)/\(expected)"
            )
        }
        return Array(body.prefix(expected))
    }

    // MARK: - Internals

    private func takeSequence() -> UInt8 {
        defer { nextSequence = nextSequence &+ 1 }
        return nextSequence
    }

    private func decodeFlexible(_ raw: [UInt8]) throws -> NIRFrame.Decoded {
        try NIRFrame.decodeHIDRead(raw)
    }

    private func validateResponse(
        _ decoded: NIRFrame.Decoded,
        expectedSeq: UInt8,
        command: UInt8,
        group: UInt8
    ) throws {
        if decoded.isBusy {
            throw NIRProtocolError.deviceBusy
        }
        if decoded.isError {
            throw NIRProtocolError.deviceError(flags: decoded.flags)
        }
        // Compact USB responses do not echo command/group (command=0 sentinel).
        if decoded.sequence != expectedSeq && decoded.sequence != 0 && expectedSeq != 0 {
            throw NIRProtocolError.sequenceMismatch(expected: expectedSeq, got: decoded.sequence)
        }
        if decoded.command != 0, decoded.command != command {
            throw NIRProtocolError.unexpectedCommand(expected: command, got: decoded.command)
        }
        if decoded.group != 0, decoded.group != group {
            transport.log("[NIR] WARN: group echo 0x\(String(decoded.group, radix: 16)) != 0x\(String(group, radix: 16))")
        }
    }

    /// Pull payload bytes out of one FILE_GET_DATA continuation report.
    private func extractFileChunk(from raw: [UInt8], expectedCommand: UInt8) -> [UInt8] {
        // Case A: framed application report (with or without report ID).
        var frameBytes = raw
        if frameBytes.first == 0x00, frameBytes.count >= NIRExchange.headerSize + NIRExchange.commandGroupSize + 1 {
            // Likely report ID prefix when total is 65 or when [1] is not protocol ID 0 with plausible length.
            if frameBytes.count == NIRExchange.hidWriteSize {
                frameBytes = Array(frameBytes.dropFirst())
            }
        }
        if frameBytes.count >= NIRExchange.headerSize + NIRExchange.commandGroupSize,
           frameBytes[0] == NIRExchange.protocolID {
            if let decoded = try? NIRFrame.decode(frameBytes),
               decoded.command == expectedCommand || decoded.command == NNOFileCommand.getReadSize {
                return decoded.payload
            }
            // Header present but decode failed: return data after 7-byte header.
            let length = Int(frameBytes[3]) | (Int(frameBytes[4]) << 8)
            if length >= 2, frameBytes.count > 7 {
                return Array(frameBytes[7...])
            }
        }
        // Case B: pure payload continuation (no frame header) — use whole report minus report ID.
        if raw.count > 0, raw[0] != NIRExchange.protocolID || raw.count < 8 {
            if raw.first == 0x00, raw.count == NIRExchange.hidWriteSize {
                return Array(raw.dropFirst())
            }
            return raw
        }
        return []
    }
}
