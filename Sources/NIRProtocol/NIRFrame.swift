import Foundation

/// Encode / decode the ISC NIRScan USB HID application frame
/// (Command Description Table 2-1). No ESP-IDF dependency.
public enum NIRFrame {
    /// Encode a command frame into `out` (application frame, 64 bytes max).
    /// Returns encoded application length (padded to 64 when `padToHID` is true).
    public static func encode(
        into out: inout [UInt8],
        flags: UInt8,
        sequence: UInt8,
        command: UInt8,
        group: UInt8,
        payload: [UInt8] = []
    ) -> Int {
        let length = NIRExchange.commandGroupSize + payload.count // cmd + group + data
        precondition(length <= 0xFFFF)
        precondition(NIRExchange.headerSize + length <= NIRExchange.hidPacketSize || true)

        var frame = [UInt8](repeating: 0, count: NIRExchange.hidPacketSize)
        frame[0] = NIRExchange.protocolID
        frame[1] = flags
        frame[2] = sequence
        frame[3] = UInt8(length & 0xFF)
        frame[4] = UInt8((length >> 8) & 0xFF)
        frame[5] = command
        frame[6] = group
        if !payload.isEmpty {
            for (i, b) in payload.enumerated() {
                let idx = 7 + i
                if idx < frame.count {
                    frame[idx] = b
                }
            }
        }
        out = frame
        return NIRExchange.hidPacketSize
    }

    /// Build hidapi write buffer.
    ///
    /// NIR-M-R2 HID report descriptor: **no Report ID**, max report 64 bytes
    /// (IOHID ReportDescriptor + live hid_write probe).
    /// Probe: `hid_write(65)` succeeds but device never replies; `hid_write(64)`
    /// with the raw application frame works. Send the 64-byte frame as-is.
    public static func encodeHIDWrite(
        flags: UInt8,
        sequence: UInt8,
        command: UInt8,
        group: UInt8,
        payload: [UInt8] = []
    ) -> [UInt8] {
        var frame: [UInt8] = []
        _ = encode(
            into: &frame,
            flags: flags,
            sequence: sequence,
            command: command,
            group: group,
            payload: payload
        )
        return frame
    }

    public struct Decoded: Equatable {
        public var protocolID: UInt8
        public var flags: UInt8
        public var sequence: UInt8
        public var length: Int
        public var command: UInt8
        public var group: UInt8
        /// Data after command+group (length - 2).
        public var payload: [UInt8]

        public var isSuccess: Bool { (flags & NIRFlag.errorMask) == NIRFlag.errorSuccess }
        public var isBusy: Bool { (flags & NIRFlag.errorMask) == NIRFlag.errorBusy }
        public var isError: Bool { (flags & NIRFlag.errorMask) == NIRFlag.errorError }
    }

    /// Decode an application frame (64 bytes starting with protocol ID 0).
    public static func decode(_ frame: [UInt8]) throws -> Decoded {
        guard frame.count >= NIRExchange.headerSize + NIRExchange.commandGroupSize else {
            throw NIRProtocolError.invalidPacket("frame too short (\(frame.count))")
        }
        guard frame[0] == NIRExchange.protocolID else {
            throw NIRProtocolError.invalidPacket(
                String(format: "protocol ID 0x%02X (expected 0x00)", frame[0])
            )
        }
        let flags = frame[1]
        let seq = frame[2]
        let length = Int(frame[3]) | (Int(frame[4]) << 8)
        guard length >= NIRExchange.commandGroupSize else {
            throw NIRProtocolError.invalidPacket("length \(length) < 2")
        }
        let command = frame[5]
        let group = frame[6]
        let payloadLen = length - NIRExchange.commandGroupSize
        var payload: [UInt8] = []
        if payloadLen > 0 {
            guard frame.count >= 7 + payloadLen else {
                throw NIRProtocolError.invalidPacket(
                    "frame \(frame.count) cannot hold payload \(payloadLen)"
                )
            }
            payload = Array(frame[7..<(7 + payloadLen)])
        }
        return Decoded(
            protocolID: frame[0],
            flags: flags,
            sequence: seq,
            length: length,
            command: command,
            group: group,
            payload: payload
        )
    }

    /// Decode from a hidapi read buffer.
    ///
    /// Live NIR-M-R2 responses (64-byte unnumbered Input report) use a compact layout:
    ///   [0] Flags
    ///   [1] Sequence
    ///   [2] Length LSB  (payload data byte count only)
    ///   [3] Length MSB
    ///   [4...] Data
    /// No protocol-ID prefix and no Command/Group echo.
    /// Verified: SERIAL len=9 data="C36R011\\0"; TIVA_VER len=28 data=7×uint32.
    /// Falls back to the full Table 2-1 frame if compact decode fails.
    public static func decodeHIDRead(_ buffer: [UInt8]) throws -> Decoded {
        if buffer.isEmpty {
            throw NIRProtocolError.invalidPacket("empty read")
        }
        var raw = buffer
        // Optional leading 0x00 Report ID (some stacks still prefix).
        if raw.count >= 8, raw[0] == 0x00, raw[1] != 0x00 {
            if let d = try? decodeCompact(Array(raw.dropFirst())) {
                return d
            }
        }
        if let d = try? decodeCompact(raw) {
            return d
        }
        return try decode(Array(raw.prefix(NIRExchange.hidPacketSize)))
    }

    /// Decode the live compact response: flags, seq, len16(data), data.
    public static func decodeCompact(_ frame: [UInt8]) throws -> Decoded {
        guard frame.count >= 4 else {
            throw NIRProtocolError.invalidPacket("compact frame too short")
        }
        let flags = frame[0]
        let seq = frame[1]
        let dataLen = Int(frame[2]) | (Int(frame[3]) << 8)
        // Plausible flags: R/W and/or Reply/Ready bits; error nibble 0..2.
        let err = flags & 0x30
        guard err == 0x00 || err == 0x10 || err == 0x20 else {
            throw NIRProtocolError.invalidPacket(String(format: "compact flags 0x%02X not plausible", flags))
        }
        guard dataLen <= 240 else {
            throw NIRProtocolError.invalidPacket("compact length \(dataLen) too large")
        }
        var payload: [UInt8] = []
        if dataLen > 0 {
            let avail = max(0, frame.count - 4)
            let n = min(dataLen, avail)
            payload = Array(frame[4..<(4 + n)])
        }
        return Decoded(
            protocolID: 0x00,
            flags: flags,
            sequence: seq,
            length: dataLen,
            command: 0x00,
            group: 0x00,
            payload: payload
        )
    }
}

/// Little-endian helpers for protocol payloads.
public enum NIRLE {
    public static func u32(_ bytes: [UInt8], at offset: Int = 0) throws -> UInt32 {
        guard bytes.count >= offset + 4 else {
            throw NIRProtocolError.invalidPayloadLength(expected: offset + 4, actual: bytes.count)
        }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    public static func u16(_ bytes: [UInt8], at offset: Int = 0) throws -> UInt16 {
        guard bytes.count >= offset + 2 else {
            throw NIRProtocolError.invalidPayloadLength(expected: offset + 2, actual: bytes.count)
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public static func asciiCString(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }
}
