import CDLPSpec
import Foundation
import NIRDevice
import NIRProtocol

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

    public static func decode(_ raw: [UInt8], keepRaw: Bool = false) throws -> Spectrum {
        guard !raw.isEmpty else {
            throw SpectrumDecodeError.invalidSpectrum("empty raw scan buffer")
        }
        guard nir_dlpspec_available() != 0 else {
            throw SpectrumDecodeError.libraryUnavailable(
                "Build with third_party/DLPSpectrumLibrary (see third_party/THIRD_PARTY.md)"
            )
        }

        DebugLog.dlp("decode \(raw.count) B via dlpspec \(version)")

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
            DebugLog.dlp("decode FAIL rc=\(out.return_code): \(msg)")
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
        let cfgName = withUnsafePointer(to: out.cfg_config_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 40) { String(cString: $0) }
        }

        let typeCode = out.cfg_scan_type >= 0 ? Int(out.cfg_scan_type) : nil
        let config = ScanConfigInfo(
            name: {
                if !scanName.isEmpty { return scanName }
                if !cfgName.isEmpty { return cfgName }
                return nil
            }(),
            scanTypeCode: typeCode,
            configIndex: out.cfg_scan_config_index != 0 ? Int(out.cfg_scan_config_index) : nil,
            wavelengthStartNM: out.cfg_wavelength_start_nm != 0 ? Int(out.cfg_wavelength_start_nm) : nil,
            wavelengthEndNM: out.cfg_wavelength_end_nm != 0 ? Int(out.cfg_wavelength_end_nm) : nil,
            widthPx: out.cfg_width_px != 0xFF ? Int(out.cfg_width_px) : nil,
            numPatterns: out.cfg_num_patterns != 0 ? Int(out.cfg_num_patterns) : nil,
            numRepeats: out.cfg_num_repeats != 0 ? Int(out.cfg_num_repeats) : nil,
            numSections: out.cfg_num_sections != 0 ? Int(out.cfg_num_sections) : nil
        )

        var scanDate = DateComponents()
        scanDate.year = 2000 + Int(out.year)
        scanDate.month = Int(out.month) + 1
        scanDate.day = Int(out.day)
        scanDate.hour = Int(out.hour)
        scanDate.minute = Int(out.minute)
        scanDate.second = Int(out.second)
        let recordedDate = out.month < 12 && out.day >= 1 && out.day <= 31 &&
            out.hour < 24 && out.minute < 60 && out.second < 61
            ? Calendar.current.date(from: scanDate) : nil
        let spectrum = Spectrum(
            timestamp: recordedDate ?? Date(),
            points: zip(wavelengths, intensities).map { SpectrumPoint(wavelength: $0, intensity: Int($1)) },
            temperature: out.temperature,
            humidity: out.humidity,
            detectorTemperature: out.detector_temperature,
            serialNumber: serial.isEmpty ? nil : serial,
            configurationName: scanName.isEmpty ? (cfgName.isEmpty ? nil : cfgName) : scanName,
            pga: Int(out.pga),
            source: .dlpspec,
            raw: keepRaw ? raw : nil,
            config: config
        )
        try spectrum.validateForNIR()
        DebugLog.dlp("decode PASS, \(n) points")
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
        if let config {
            if let type = config.scanTypeName { lines.append("# scan_type=\(type)") }
            if let idx = config.configIndex { lines.append("# config_index=\(idx)") }
            if let w = config.widthPx { lines.append("# width_px=\(w)") }
            if let r = config.numRepeats { lines.append("# num_repeats=\(r)") }
            if let p = config.numPatterns { lines.append("# num_patterns=\(p)") }
        }
        lines.append("wavelength_nm,intensity")
        for p in points {
            lines.append(String(format: "%.3f,%d", p.wavelength, p.intensity))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
