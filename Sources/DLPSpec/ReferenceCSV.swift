import Foundation
import NIRDevice

public struct ReferenceExportMetadata {
    public let source: String
    public let referenceTimestamp: Date?
    public let referenceConfig: String?
    public let referencePGA: Int?

    public init(source: String, referenceTimestamp: Date?, referenceConfig: String?, referencePGA: Int?) {
        self.source = source
        self.referenceTimestamp = referenceTimestamp
        self.referenceConfig = referenceConfig
        self.referencePGA = referencePGA
    }
}

/// Adds derived columns without changing the existing intensity-only Spectrum.csvString format.
public enum ReferenceCSV {
    public static func string(sample: Spectrum, analysis: ReferenceAnalysis,
                              metadata: ReferenceExportMetadata) throws -> String {
        guard sample.points.count == analysis.wavelengths.count else {
            throw ReferenceAnalysisError.sampleMismatch
        }
        for index in sample.points.indices {
            guard abs(sample.points[index].wavelength - analysis.wavelengths[index]) <= 0.01,
                  sample.points[index].intensity == analysis.sampleIntensity[index] else {
                throw ReferenceAnalysisError.sampleMismatch
            }
        }
        let dateFormatter = ISO8601DateFormatter()
        var lines: [String] = []
        if let serial = sample.serialNumber { lines.append("# serial=\(serial)") }
        if let config = sample.configurationName { lines.append("# scan_config=\(config)") }
        lines.append("# reference_source=\(metadata.source)")
        if let config = metadata.referenceConfig { lines.append("# reference_config=\(config)") }
        lines.append("# sample_timestamp=\(dateFormatter.string(from: sample.timestamp))")
        if let date = metadata.referenceTimestamp {
            lines.append("# reference_timestamp=\(dateFormatter.string(from: date))")
        }
        if let pga = sample.pga { lines.append("# sample_pga=\(pga)") }
        if let pga = metadata.referencePGA { lines.append("# reference_pga=\(pga)") }
        if let temperature = sample.temperature {
            lines.append(String(format: "# temperature_c=%.2f", temperature))
        }
        if let humidity = sample.humidity {
            lines.append(String(format: "# humidity_percent=%.2f", humidity))
        }
        lines.append("wavelength_nm,sample_intensity,reference_intensity,reflectance,absorbance_au")
        for index in sample.points.indices {
            let reflectance = analysis.reflectance[index].map { String(format: "%.12g", $0) } ?? ""
            let absorbance = analysis.absorbance[index].map { String(format: "%.12g", $0) } ?? ""
            lines.append(String(format: "%.3f,%d,%d,%@,%@", analysis.wavelengths[index],
                                analysis.sampleIntensity[index], analysis.referenceIntensity[index],
                                reflectance, absorbance))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
