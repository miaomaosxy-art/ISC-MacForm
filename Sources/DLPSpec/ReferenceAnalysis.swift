import CDLPSpec
import Foundation
import NIRDevice

public enum SpectrumQuantity: String, CaseIterable, Identifiable {
    case intensity = "Intensity"
    case reflectance = "Reflectance"
    case absorbance = "Absorbance"

    public var id: String { rawValue }
    public var axisTitle: String {
        switch self {
        case .intensity: return "Intensity (counts)"
        case .reflectance: return "Reflectance (unitless)"
        case .absorbance: return "Absorbance (AU)"
        }
    }
}

public enum ReferenceAnalysisError: Error, Equatable, CustomStringConvertible {
    case missingRawScan
    case missingCalibration
    case interpretationFailed(code: Int32, message: String)
    case sampleMismatch
    case referenceMismatch

    public var description: String {
        switch self {
        case .missingRawScan: return "Sample raw scan data is unavailable."
        case .missingCalibration: return "Reference calibration matrix is unavailable."
        case .interpretationFailed(let code, let message): return "DLP reference error \(code): \(message)"
        case .sampleMismatch: return "Decoded sample differs from reference interpretation input."
        case .referenceMismatch: return "Reference and sample scan configurations are incompatible."
        }
    }

    public var userMessage: String {
        switch self {
        case .missingRawScan: return "Raw scan data is required for reference interpretation."
        case .missingCalibration: return "Cannot read the device reference calibration matrix."
        case .interpretationFailed: return "Reference does not cover this scan configuration, or calibration data is invalid."
        case .sampleMismatch, .referenceMismatch: return "Reference and sample scan configurations do not match."
        }
    }
}

/// Windows SPEC_SetData uses DLP interpolation before deriving these values.
/// Windows SPEC_GetReflectance and SPEC_GetAbsorbance then use sample/reference
/// and -log10(sample/reference), respectively. Invalid log inputs are explicit nil.
public struct ReferenceAnalysis {
    public let wavelengths: [Double]
    public let sampleIntensity: [Int]
    public let referenceIntensity: [Int]
    public let reflectance: [Double?]
    public let absorbance: [Double?]

    public var finiteReflectanceCount: Int { reflectance.compactMap { $0 }.count }
    public var finiteAbsorbanceCount: Int { absorbance.compactMap { $0 }.count }
    public var invalidAbsorbanceCount: Int { absorbance.filter { $0 == nil }.count }

    public func values(for quantity: SpectrumQuantity) -> [Double?] {
        switch quantity {
        case .intensity: return sampleIntensity.map { Double($0) }
        case .reflectance: return reflectance
        case .absorbance: return absorbance
        }
    }

    public static func analyze(
        sample: Spectrum,
        referenceRaw: [UInt8],
        matrixRaw: [UInt8]
    ) throws -> ReferenceAnalysis {
        guard let sampleRaw = sample.raw, !sampleRaw.isEmpty else {
            throw ReferenceAnalysisError.missingRawScan
        }
        guard !matrixRaw.isEmpty else { throw ReferenceAnalysisError.missingCalibration }
        guard !referenceRaw.isEmpty else { throw ReferenceAnalysisError.referenceMismatch }

        var output = NIRInterpretedReference()
        let rc = sampleRaw.withUnsafeBufferPointer { sampleBuffer in
            referenceRaw.withUnsafeBufferPointer { referenceBuffer in
                matrixRaw.withUnsafeBufferPointer { matrixBuffer in
                    nir_interpret_reference(
                        sampleBuffer.baseAddress, sampleBuffer.count,
                        referenceBuffer.baseAddress, referenceBuffer.count,
                        matrixBuffer.baseAddress, matrixBuffer.count, &output
                    )
                }
            }
        }
        defer { nir_free_interpreted_reference(&output) }
        guard rc == 0 else {
            let message = withUnsafePointer(to: output.message) {
                $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
            }
            throw ReferenceAnalysisError.interpretationFailed(code: output.return_code, message: message)
        }
        let count = Int(output.count)
        guard count == sample.points.count,
              let wavelengths = output.wavelength,
              let samples = output.sample_intensity,
              let references = output.reference_intensity else {
            throw ReferenceAnalysisError.sampleMismatch
        }
        let wavelengthValues = Array(UnsafeBufferPointer(start: wavelengths, count: count))
        let sampleValues = Array(UnsafeBufferPointer(start: samples, count: count)).map(Int.init)
        let referenceValues = Array(UnsafeBufferPointer(start: references, count: count)).map(Int.init)
        for index in 0..<count {
            if abs(wavelengthValues[index] - sample.points[index].wavelength) > 0.01 ||
                sampleValues[index] != sample.points[index].intensity {
                throw ReferenceAnalysisError.sampleMismatch
            }
        }
        return try make(wavelengths: wavelengthValues,
                        sampleIntensity: sampleValues,
                        referenceIntensity: referenceValues)
    }

    /// Apply the same Windows ratio/log step to averaged sample intensities.
    /// The caller must use a reference interpreted for this exact scan config.
    public static func average(sample: Spectrum, reference: ReferenceAnalysis) throws -> ReferenceAnalysis {
        guard sample.points.count == reference.wavelengths.count else {
            throw ReferenceAnalysisError.referenceMismatch
        }
        for index in sample.points.indices {
            guard abs(sample.points[index].wavelength - reference.wavelengths[index]) <= 0.01 else {
                throw ReferenceAnalysisError.referenceMismatch
            }
        }
        return try make(wavelengths: reference.wavelengths,
                        sampleIntensity: sample.points.map(\.intensity),
                        referenceIntensity: reference.referenceIntensity)
    }

    private static func make(
        wavelengths: [Double], sampleIntensity: [Int], referenceIntensity: [Int]
    ) throws -> ReferenceAnalysis {
        guard wavelengths.count == sampleIntensity.count,
              wavelengths.count == referenceIntensity.count else {
            throw ReferenceAnalysisError.referenceMismatch
        }
        let ratios = zip(sampleIntensity, referenceIntensity).map { sample, reference -> Double? in
            guard sample > 0, reference > 0 else { return nil }
            let ratio = Double(sample) / Double(reference)
            return ratio.isFinite && ratio > 0 ? ratio : nil
        }
        return ReferenceAnalysis(
            wavelengths: wavelengths,
            sampleIntensity: sampleIntensity,
            referenceIntensity: referenceIntensity,
            reflectance: ratios,
            absorbance: ratios.map { $0.map { -log10($0) } }
        )
    }
}
