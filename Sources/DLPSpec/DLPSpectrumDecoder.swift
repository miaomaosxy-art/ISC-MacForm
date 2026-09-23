import CDLPSpec
import Foundation
import NIRDevice

public enum SpectrumDecodeError: Error, Equatable, CustomStringConvertible {
    case libraryUnavailable(String)
    case interpretFailed(returnCode: Int32, message: String)
    case invalidSpectrum(String)

    public var description: String {
        switch self {
        case .libraryUnavailable(let m):
            return "SpectrumDecodeError.libraryUnavailable: \(m)"
        case .interpretFailed(let rc, let m):
            return "SpectrumDecodeError.interpretFailed rc=\(rc): \(m)"
        case .invalidSpectrum(let m):
            return "SpectrumDecodeError.invalidSpectrum: \(m)"
        }
    }

    public var userMessage: String {
        switch self {
        case .libraryUnavailable:
            return "Spectrum decoder unavailable."
        case .interpretFailed:
            return "Spectrum data could not be decoded."
        case .invalidSpectrum:
            return "Spectrum data failed validation."
        }
    }
}

/// Decodes complete serialized scan data via official `dlpspec_scan_interpret`.
/// TI `scanResults` stays inside the C bridge — Swift only sees `Spectrum`.
public enum DLPSpectrumDecoder {
    public static var isAvailable: Bool {
        nir_dlpspec_available() != 0
    }

    public static var version: String {
        String(cString: nir_dlpspec_version_string())
    }

    public static func decode(_ raw: [UInt8]) throws -> Spectrum {
        guard !raw.isEmpty else {
            throw SpectrumDecodeError.invalidSpectrum("empty raw scan buffer")
        }
        guard nir_dlpspec_available() != 0 else {
            throw SpectrumDecodeError.libraryUnavailable(
                "Build with third_party/DLPSpectrumLibrary (see third_party/THIRD_PARTY.md)"
            )
        }

        var out = NIRDecodedSpectrum()
        let rc = raw.withUnsafeBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return nir_decode_scan(base, buf.count, &out)
        }
        defer { nir_free_decoded_scan(&out) }

        guard rc == 0 else {
            let msg = withUnsafePointer(to: out.message) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            throw SpectrumDecodeError.interpretFailed(returnCode: out.return_code, message: msg)
        }

        let n = Int(out.count)
        guard let wlPtr = out.wavelength, let inPtr = out.intensity else {
            throw SpectrumDecodeError.invalidSpectrum("null wavelength/intensity arrays")
        }
        let wavelengths = Array(UnsafeBufferPointer(start: wlPtr, count: n))
        let intensities = Array(UnsafeBufferPointer(start: inPtr, count: n))

        let scanName = withUnsafePointer(to: out.scan_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 20) { String(cString: $0) }
        }
        let serial = withUnsafePointer(to: out.serial_number) {
            $0.withMemoryRebound(to: CChar.self, capacity: 8) { String(cString: $0) }
        }

        let spectrum = Spectrum(
            timestamp: Date(),
            points: zip(wavelengths, intensities).map { SpectrumPoint(wavelength: $0, intensity: Int($1)) },
            temperature: out.temperature,
            humidity: out.humidity,
            detectorTemperature: out.detector_temperature,
            serialNumber: serial.isEmpty ? nil : serial,
            configurationName: scanName.isEmpty ? nil : scanName,
            pga: Int(out.pga),
            source: .dlpspec
        )
        try spectrum.validateForNIR()
        return spectrum
    }
}

extension Spectrum {
    /// Sanity checks after a successful `dlpspec_scan_interpret`.
    /// Do not hard-code 228 points — configs vary. NIR-M-R2 STD is ~900–1700 nm.
    public func validateForNIR(
        minWavelength: Double = 700,
        maxWavelength: Double = 2500
    ) throws {
        let n = points.count
        guard n > 0 else {
            throw SpectrumDecodeError.invalidSpectrum("points == 0")
        }
        guard n <= 864 else {
            throw SpectrumDecodeError.invalidSpectrum("points \(n) > 864")
        }
        var prev: Double = -Double.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            guard p.wavelength.isFinite, p.wavelength.magnitude < 1e6 else {
                throw SpectrumDecodeError.invalidSpectrum("wavelength[\(i)] not finite")
            }
            guard p.wavelength >= minWavelength, p.wavelength <= maxWavelength else {
                throw SpectrumDecodeError.invalidSpectrum(
                    "wavelength[\(i)]=\(p.wavelength) outside \(minWavelength)–\(maxWavelength) nm"
                )
            }
            if i > 0, p.wavelength <= prev {
                // Allow tiny non-monotonic blips only if overall trend is increasing.
                if p.wavelength < prev - 1.0 {
                    throw SpectrumDecodeError.invalidSpectrum(
                        "wavelength not increasing at \(i): \(prev) -> \(p.wavelength)"
                    )
                }
            }
            prev = p.wavelength
        }
        // Overall range must span a plausible NIR band (not a single point / flat garbage).
        let lo = points.first!.wavelength
        let hi = points.last!.wavelength
        if hi - lo < 50 {
            throw SpectrumDecodeError.invalidSpectrum("wavelength span too small: \(hi - lo) nm")
        }
    }

    public func csvString() -> String {
        var lines: [String] = []
        if let serialNumber { lines.append("# serial=\(serialNumber)") }
        if let configurationName { lines.append("# config=\(configurationName)") }
        if let temperature { lines.append("# temperature_c=\(String(format: "%.2f", temperature))") }
        if let detectorTemperature { lines.append("# detector_temperature_c=\(String(format: "%.2f", detectorTemperature))") }
        if let humidity { lines.append("# humidity_percent=\(String(format: "%.2f", humidity))") }
        if let pga { lines.append("# pga=\(pga)") }
        lines.append("# points=\(points.count)")
        lines.append("# timestamp=\(ISO8601DateFormatter().string(from: timestamp))")
        lines.append("wavelength_nm,intensity")
        for p in points {
            lines.append(String(format: "%.3f,%d", p.wavelength, p.intensity))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
