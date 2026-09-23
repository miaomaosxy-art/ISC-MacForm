import Chidapi
import Foundation
import NIRProtocol

/// USB HID transport (hidapi). This layer only enumerates / opens / reads / writes
/// raw reports — no NIR command framing here.
public final class HIDTransport: @unchecked Sendable {
    public struct DeviceInfo: Equatable, CustomStringConvertible {
        public var path: String
        public var vendorID: UInt16
        public var productID: UInt16
        public var serialNumber: String?
        public var manufacturer: String?
        public var product: String?
        public var releaseNumber: UInt16
        public var usagePage: UInt16
        public var usage: UInt16
        public var interfaceNumber: Int32

        public var description: String {
            let sn = serialNumber ?? "-"
            let mfg = manufacturer ?? "-"
            let prod = product ?? "-"
            return String(
                format: "VID=0x%04X PID=0x%04X serial=%@ mfg=%@ product=%@ path=%@",
                vendorID, productID, sn, mfg, prod, path
            )
        }
    }

    private var handle: OpaquePointer?
    private static var hidAPIReady = false
    private static let hidAPILock = NSLock()

    public private(set) var openedPath: String?
    public var isDebugLoggingEnabled: Bool

    public init(debugLogging: Bool = false) {
        self.isDebugLoggingEnabled = debugLogging
    }

    deinit {
        close()
    }

    // MARK: - hidapi lifecycle

    private static func ensureHIDAPI() {
        hidAPILock.lock()
        defer { hidAPILock.unlock() }
        if !hidAPIReady {
            hid_init()
            hidAPIReady = true
        }
    }

    public static func shutdownHIDAPI() {
        hidAPILock.lock()
        defer { hidAPILock.unlock() }
        if hidAPIReady {
            hid_exit()
            hidAPIReady = false
        }
    }

    // MARK: - Enumerate

    /// Enumerate HID devices. If vendorID/productID are nil, list all HID devices.
    public static func enumerate(
        vendorID: UInt16? = NIRUSB.vendorID,
        productID: UInt16? = NIRUSB.productID
    ) -> [DeviceInfo] {
        ensureHIDAPI()
        let vid = vendorID ?? 0
        let pid = productID ?? 0
        var results: [DeviceInfo] = []
        guard let list = hid_enumerate(vid, pid) else {
            return []
        }
        defer { hid_free_enumeration(list) }

        var current: UnsafeMutablePointer<hid_device_info>? = list
        while let info = current {
            let path = info.pointee.path.map { String(cString: $0) } ?? ""
            let serial = info.pointee.serial_number.map { wideToSwift($0) }
            let manufacturer = info.pointee.manufacturer_string.map { wideToSwift($0) }
            let product = info.pointee.product_string.map { wideToSwift($0) }
            results.append(
                DeviceInfo(
                    path: path,
                    vendorID: info.pointee.vendor_id,
                    productID: info.pointee.product_id,
                    serialNumber: serial,
                    manufacturer: manufacturer,
                    product: product,
                    releaseNumber: info.pointee.release_number,
                    usagePage: info.pointee.usage_page,
                    usage: info.pointee.usage,
                    interfaceNumber: info.pointee.interface_number
                )
            )
            current = info.pointee.next
        }
        return results
    }

    /// Convenience: only NIR-M-R2 expected identity (actual values still printed by caller).
    public static func enumerateNIRR2() -> [DeviceInfo] {
        enumerate(vendorID: NIRUSB.vendorID, productID: NIRUSB.productID)
    }

    // MARK: - Open / close

    public func open(path: String) throws {
        close()
        Self.ensureHIDAPI()
        guard let h = hid_open_path(path) else {
            let err = hid_error(nil).map { wideToSwift($0) } ?? "hid_open_path returned nil"
            throw NIRProtocolError.deviceOpenFailed(err)
        }
        handle = h
        openedPath = path
        hid_set_nonblocking(h, 0)
        log("[USB] Device opened path=\(path)")
    }

    public func openFirstMatching() throws -> DeviceInfo {
        let devices = Self.enumerateNIRR2()
        guard let first = devices.first else {
            throw NIRProtocolError.deviceNotFound
        }
        try open(path: first.path)
        return first
    }

    public func close() {
        if let h = handle {
            hid_close(h)
            log("[USB] Device closed")
        }
        handle = nil
        openedPath = nil
    }

    public var isOpen: Bool { handle != nil }

    // MARK: - Raw IO

    public func write(_ data: [UInt8]) throws {
        guard let h = handle else {
            throw NIRProtocolError.deviceOpenFailed("not open")
        }
        let buf = data
        let written = buf.withUnsafeBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Int(hid_write(h, base, ptr.count))
        }
        if written < 0 {
            let err = hid_error(h).map { wideToSwift($0) } ?? "hid_write failed"
            throw NIRProtocolError.usbWriteFailed(err)
        }
        if isDebugLoggingEnabled {
            logHex(prefix: "TX", data: data)
        }
    }

    /// Read one HID report. Returns raw bytes as returned by hidapi.
    public func read(timeoutMS: Int = NIRExchange.defaultTimeoutMS) throws -> [UInt8] {
        guard let h = handle else {
            throw NIRProtocolError.deviceOpenFailed("not open")
        }
        // NIR-M-R2: unnumbered 64-byte Input report (no Report ID).
        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Int(hid_read_timeout(h, base, ptr.count, Int32(timeoutMS)))
        }
        if n == 0 {
            throw NIRProtocolError.usbReadTimeout
        }
        if n < 0 {
            let err = hid_error(h).map { wideToSwift($0) } ?? "hid_read failed"
            throw NIRProtocolError.usbWriteFailed(err)
        }
        let data = Array(buf.prefix(n))
        if isDebugLoggingEnabled {
            logHex(prefix: "RX", data: data)
        }
        return data
    }

    /// Read multiple raw reports (for large FILE_GET_DATA bodies).
    public func readReports(count: Int, timeoutMS: Int = NIRExchange.defaultTimeoutMS) throws -> [[UInt8]] {
        var reports: [[UInt8]] = []
        reports.reserveCapacity(count)
        for _ in 0..<count {
            reports.append(try read(timeoutMS: timeoutMS))
        }
        return reports
    }

    // MARK: - Logging

    public func log(_ message: String) {
        if isDebugLoggingEnabled || DebugLog.isEnabled {
            DebugLog.usb(message)
            if !DebugLog.isEnabled { print(message) }
        }
    }

    public func logHex(prefix: String, data: [UInt8]) {
        guard isDebugLoggingEnabled || DebugLog.isEnabled else { return }
        DebugLog.hex("USB", prefix: prefix, data: data)
        if !DebugLog.isEnabled {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("\(prefix):\n\(hex)")
        }
    }
}

// MARK: - wchar_t helpers (hidapi strings are wchar_t*)

private func wideToSwift(_ wide: UnsafePointer<wchar_t>) -> String {
    var units: [UInt16] = []
    var p = wide
    while p.pointee != 0 {
        // On Darwin wchar_t is 32-bit; BMP only is enough for USB strings.
        let v = UInt32(p.pointee)
        if v > 0xFFFF {
            // Encode as UTF-16 surrogate pair.
            let adj = v - 0x10000
            units.append(UInt16(0xD800 + (adj >> 10)))
            units.append(UInt16(0xDC00 + (adj & 0x3FF)))
        } else {
            units.append(UInt16(v))
        }
        p = p.advanced(by: 1)
    }
    return String(utf16CodeUnits: units, count: units.count)
}
