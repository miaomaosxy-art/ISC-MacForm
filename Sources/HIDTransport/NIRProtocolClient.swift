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

    /// Read a "file" via NNO_CMD_FILE_GET_READSIZE + repeated NNO_CMD_FILE_GET_DATA.
    ///
    /// UART §3.3.7: "Read the file size, and then **repeatedly read the file data**
    /// until the data size is the same."
    /// Live USB: each GET_DATA returns one logical chunk (length field ≈ 512),
    /// itself fragmented across 64-byte reports. Send GET_DATA again for the next chunk.
    public func readFile(
        fileType: NNOFileType,
        timeoutMS: Int = NIRExchange.defaultTimeoutMS
    ) throws -> [UInt8] {
        let expected = Int(try readFileSize(fileType: fileType))
        transport.log("[FILE] expected \(expected) bytes type=0x\(String(fileType.rawValue, radix: 16, uppercase: true))")
        DebugLog.file("expected \(expected) bytes type=0x\(String(fileType.rawValue, radix: 16, uppercase: true))")

        guard expected > 0 else {
            DebugLog.file("received 0 bytes (empty file)")
            return []
        }

        var body = [UInt8]()
        body.reserveCapacity(expected)
        let budgetMS = max(timeoutMS, expected / 4 + 5000)
        let deadline = Date().addingTimeInterval(Double(budgetMS) / 1000.0)

        while body.count < expected && Date() < deadline {
            let chunk = try readOneDataChunk(deadline: deadline)
            if chunk.isEmpty {
                transport.log("[FILE] WARN: empty GET_DATA chunk at \(body.count)/\(expected)")
                DebugLog.file("WARN empty GET_DATA chunk at \(body.count)/\(expected)")
                continue
            }
            body.append(contentsOf: chunk)
        }

        guard body.count >= expected else {
            DebugLog.file("truncated: got \(body.count)/\(expected)")
            throw NIRProtocolError.fileTruncated(expected: expected, actual: body.count)
        }
        DebugLog.file("received \(body.count) bytes")
        return Array(body.prefix(expected))
    }

    /// One NNO_CMD_FILE_GET_DATA transaction → one logical data chunk.
    private func readOneDataChunk(deadline: Date) throws -> [UInt8] {
        let seq = takeSequence()
        let hidBuf = NIRFrame.encodeHIDWrite(
            flags: NIRFlag.readReply,
            sequence: seq,
            command: NNOFileCommand.getData,
            group: NNOGroup.file.rawValue,
            payload: []
        )
        try transport.write(hidBuf)

        // First report carries compact header: flags, seq, length(total chunk), data…
        guard Date() < deadline else { return [] }
        let first = try transport.read(timeoutMS: NIRExchange.defaultTimeoutMS)
        if isDebugLoggingEnabled {
            transport.logHex(prefix: "RX-chunk0", data: first)
        }

        guard first.count >= 4 else {
            return extractFileChunk(from: first, remaining: 4096)
        }

        let chunkLen = Int(first[2]) | (Int(first[3]) << 8)
        // Data after 4-byte compact header in the first report.
        var body = [UInt8]()
        if chunkLen > 0 {
            let firstData = Array(first.dropFirst(4))
            let n = min(chunkLen, firstData.count)
            body.append(contentsOf: firstData.prefix(n))
        } else if first.count > 4 {
            // Header claimed 0 — treat rest as raw (should not happen).
            body.append(contentsOf: first.dropFirst(4))
        }

        // Continuation reports until the declared chunk length is reached.
        while body.count < chunkLen && Date() < deadline {
            let raw: [UInt8]
            do {
                raw = try transport.read(timeoutMS: NIRExchange.defaultTimeoutMS)
            } catch NIRProtocolError.usbReadTimeout {
                break
            }
            if isDebugLoggingEnabled {
                transport.logHex(prefix: "RX-cont", data: raw)
            }
            let need = chunkLen - body.count
            let piece = extractFileChunk(from: raw, remaining: need)
            if piece.isEmpty {
                // Last resort: whole report as raw body.
                body.append(contentsOf: raw.prefix(need))
            } else {
                body.append(contentsOf: piece.prefix(need))
            }
        }

        if isDebugLoggingEnabled {
            transport.log("[NIR] chunk complete: \(body.count)/\(chunkLen) bytes")
        }
        return body
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
    ///
    /// Continuations after the first report of a chunk are typically **raw data**
    /// (the chunk length is declared once in the first report). Prefer raw body;
    /// only strip a compact header when it clearly yields a small framed payload
    /// and `remaining` is large enough to be a multi-report chunk.
    private func extractFileChunk(from raw: [UInt8], remaining: Int) -> [UInt8] {
        guard !raw.isEmpty else { return [] }

        // If this looks like a *new* compact response (flags plausible, length == remaining
        // or length ≤ 60), take its data region. Otherwise treat as raw continuation.
        if remaining > 64, let decoded = try? NIRFrame.decodeHIDRead(raw),
           decoded.length == remaining || (decoded.length > 0 && decoded.length <= 60 && decoded.payload.count == decoded.length) {
            return decoded.payload
        }

        // Full Table 2-1 frame: data after 7-byte header (rare on this device).
        if raw.count >= 7, raw[0] == NIRExchange.protocolID,
           let decoded = try? NIRFrame.decode(Array(raw.prefix(NIRExchange.hidPacketSize))),
           decoded.length >= 2, decoded.command != 0 {
            return decoded.payload
        }

        // Raw continuation body (the common case after the chunk's first report).
        if raw.count == 65, raw[0] == 0x00 {
            return Array(raw.dropFirst())
        }
        return raw
    }
}
