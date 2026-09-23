import Foundation

/// Unified debug logging. Quiet by default; enable from the app Debug Logging toggle.
/// Tags match the driver-reference diagnostic stream: [USB] [PROTO] [SCAN] [FILE] [DLP] [APP]
public enum DebugLog: @unchecked Sendable {
    public static var isEnabled: Bool = false

    private static let lock = NSLock()
    private static var handler: (@Sendable (String) -> Void)?

    /// Optional sink (e.g. GUI log pane). Default is stdout.
    public static func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public static func setEnabled(_ enabled: Bool) {
        lock.lock()
        isEnabled = enabled
        lock.unlock()
    }

    public static func log(_ tag: String, _ message: String) {
        lock.lock()
        let enabled = isEnabled
        let sink = handler
        lock.unlock()
        guard enabled else { return }
        let line = "[\(tag)] \(message)"
        if let sink {
            sink(line)
        } else {
            print(line)
        }
    }

    public static func usb(_ message: String) { log("USB", message) }
    public static func proto(_ message: String) { log("PROTO", message) }
    public static func scan(_ message: String) { log("SCAN", message) }
    public static func file(_ message: String) { log("FILE", message) }
    public static func dlp(_ message: String) { log("DLP", message) }
    public static func app(_ message: String) { log("APP", message) }

    public static func hex(_ tag: String, prefix: String, data: [UInt8]) {
        lock.lock()
        let enabled = isEnabled
        lock.unlock()
        guard enabled else { return }
        let hex = data.enumerated().map { i, b in
            String(format: "%02x%@", b, (i % 16 == 15 || i == data.count - 1) ? "\n" : " ")
        }.joined()
        log(tag, "\(prefix) (\(data.count) B)\n\(hex)")
    }
}
