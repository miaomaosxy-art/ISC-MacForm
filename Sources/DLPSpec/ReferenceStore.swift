import Foundation
import NIRDevice

public struct LocalReference: Codable, Equatable {
    public let formatVersion: Int
    public let serialNumber: String
    public let capturedAt: Date
    public let rawScan: Data
    public let config: ScanConfigInfo?
    public let pga: Int?
    public let temperature: Double?
    public let humidity: Double?

    public init(serialNumber: String, capturedAt: Date = Date(), rawScan: Data,
                config: ScanConfigInfo? = nil, pga: Int? = nil,
                temperature: Double? = nil, humidity: Double? = nil) {
        self.formatVersion = 1
        self.serialNumber = serialNumber
        self.capturedAt = capturedAt
        self.rawScan = rawScan
        self.config = config
        self.pga = pga
        self.temperature = temperature
        self.humidity = humidity
    }
}

public enum ReferenceStoreError: Error, Equatable, CustomStringConvertible {
    case invalidSerial
    case corruptFile
    case deviceMismatch

    public var description: String {
        switch self {
        case .invalidSerial: return "Device serial number is unavailable."
        case .corruptFile: return "Saved reference data is corrupt."
        case .deviceMismatch: return "Saved reference belongs to another device."
        }
    }
}

/// One latest local white scan per physical device. Never writes to the device.
public struct ReferenceStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("ISC-MacForm/References", isDirectory: true)
        }
    }

    public func save(_ reference: LocalReference) throws {
        let url = try fileURL(for: reference.serialNumber)
        guard !reference.rawScan.isEmpty else { throw ReferenceStoreError.corruptFile }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(reference).write(to: url, options: .atomic)
    }

    public func load(serialNumber: String) throws -> LocalReference? {
        let url = try fileURL(for: serialNumber)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record: LocalReference
        do {
            record = try PropertyListDecoder().decode(LocalReference.self, from: Data(contentsOf: url))
        } catch {
            throw ReferenceStoreError.corruptFile
        }
        guard record.formatVersion == 1, !record.rawScan.isEmpty else {
            throw ReferenceStoreError.corruptFile
        }
        guard record.serialNumber == serialNumber else { throw ReferenceStoreError.deviceMismatch }
        return record
    }

    private func fileURL(for serialNumber: String) throws -> URL {
        let cleaned = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw ReferenceStoreError.invalidSerial
        }
        return directory.appendingPathComponent("\(cleaned).ref.plist")
    }
}
