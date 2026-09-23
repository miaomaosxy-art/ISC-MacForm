import Foundation

public enum SpectrumAverageError: Error, Equatable, CustomStringConvertible {
    case empty
    case countMismatch([Int])
    case wavelengthMismatch(index: Int, a: Double, b: Double)

    public var description: String {
        switch self {
        case .empty:
            return "No spectra to average."
        case .countMismatch(let counts):
            return "Point count mismatch: \(counts)"
        case .wavelengthMismatch(let i, let a, let b):
            return "Wavelength axis mismatch at [\(i)]: \(a) vs \(b)"
        }
    }

    public var userMessage: String {
        switch self {
        case .empty:
            return "No spectra to average."
        case .countMismatch:
            return "Cannot average: point counts differ."
        case .wavelengthMismatch:
            return "Cannot average: wavelength axes differ."
        }
    }
}

public enum SpectrumMath {
    /// Average intensity only. Requires identical point count and wavelength axis.
    /// Does not resample or interpolate wavelengths.
    public static func average(_ scans: [Spectrum], tolerance_nm: Double = 1e-6) throws -> Spectrum {
        guard let first = scans.first else { throw SpectrumAverageError.empty }
        guard scans.count > 1 else { return first }

        let n = first.points.count
        var sums = [Double](repeating: 0, count: n)
        for scan in scans {
            guard scan.points.count == n else {
                throw SpectrumAverageError.countMismatch(scans.map(\.points.count))
            }
            for i in 0..<n {
                if abs(scan.points[i].wavelength - first.points[i].wavelength) > tolerance_nm {
                    throw SpectrumAverageError.wavelengthMismatch(
                        index: i,
                        a: first.points[i].wavelength,
                        b: scan.points[i].wavelength
                    )
                }
                sums[i] += Double(scan.points[i].intensity)
            }
        }

        let count = Double(scans.count)
        let points = (0..<n).map { i in
            SpectrumPoint(wavelength: first.points[i].wavelength, intensity: Int((sums[i] / count).rounded()))
        }

        // Keep first-scan metadata for identity; mark source as dlpspec average via configuration suffix.
        return Spectrum(
            timestamp: first.timestamp,
            points: points,
            temperature: scans.compactMap(\.temperature).reduce(0, +) / Double(max(scans.compactMap(\.temperature).count, 1)),
            humidity: scans.compactMap(\.humidity).reduce(0, +) / Double(max(scans.compactMap(\.humidity).count, 1)),
            detectorTemperature: first.detectorTemperature,
            serialNumber: first.serialNumber,
            configurationName: first.configurationName.map { "\($0) (avg \(scans.count))" },
            pga: first.pga,
            source: first.source,
            raw: nil,
            config: first.config
        )
    }

    /// Wavelength-axis consistency across scans (max |Δ| in nm).
    public static func maxWavelengthDelta(_ scans: [Spectrum]) -> Double? {
        guard let first = scans.first, scans.count > 1 else { return 0 }
        var maxDelta = 0.0
        for scan in scans.dropFirst() {
            guard scan.points.count == first.points.count else { return nil }
            for i in 0..<first.points.count {
                maxDelta = max(maxDelta, abs(scan.points[i].wavelength - first.points[i].wavelength))
            }
        }
        return maxDelta
    }
}

public enum SpectrumFileNamer {
    public static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    /// e.g. C36R011_20260923_143012.csv
    public static func singleCSVName(serial: String?, date: Date = Date()) -> String {
        let ts = timestampFormatter.string(from: date)
        let s = sanitizedSerial(serial)
        return "\(s)_\(ts).csv"
    }

    /// e.g. NIR_C36R011_20260923_143012
    public static func sessionDirectoryName(serial: String?, date: Date = Date()) -> String {
        let ts = timestampFormatter.string(from: date)
        let s = sanitizedSerial(serial)
        return "NIR_\(s)_\(ts)"
    }

    public static func scanCSVName(index: Int) -> String {
        String(format: "scan_%03d.csv", index)
    }

    public static func scanRawName(index: Int) -> String {
        String(format: "scan_%03d.bin", index)
    }

    public static let averageCSVName = "average.csv"

    private static func sanitizedSerial(_ serial: String?) -> String {
        let s = (serial ?? "UNKNOWN").trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "UNKNOWN" : filtered
    }
}
