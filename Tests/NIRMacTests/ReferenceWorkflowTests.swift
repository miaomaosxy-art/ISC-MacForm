import Foundation
import XCTest
@testable import DLPSpec
@testable import NIRDevice

final class ReferenceWorkflowTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func testLocalReferencePersistsAcrossStoreInstancesAndIsDeviceScoped() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let white = LocalReference(serialNumber: "C36R011", capturedAt: captured,
                                   rawScan: Data([0x12, 0x34, 0x56]))
        try ReferenceStore(directory: directory).save(white)

        let reopened = ReferenceStore(directory: directory)
        XCTAssertEqual(try reopened.load(serialNumber: "C36R011"), white)
        XCTAssertNil(try reopened.load(serialNumber: "OTHER001"))
    }

    func testCorruptOrWrongDeviceReferenceIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReferenceStore(directory: directory)
        try store.save(LocalReference(serialNumber: "C36R011", rawScan: Data([1])))
        let good = directory.appendingPathComponent("C36R011.ref.plist")
        let wrong = directory.appendingPathComponent("OTHER001.ref.plist")
        try FileManager.default.copyItem(at: good, to: wrong)
        XCTAssertThrowsError(try store.load(serialNumber: "OTHER001")) { error in
            XCTAssertEqual(error as? ReferenceStoreError, .deviceMismatch)
        }
        try Data([0, 1, 2]).write(to: good)
        XCTAssertThrowsError(try store.load(serialNumber: "C36R011")) { error in
            XCTAssertEqual(error as? ReferenceStoreError, .corruptFile)
        }
        XCTAssertThrowsError(try store.load(serialNumber: "../escape")) { error in
            XCTAssertEqual(error as? ReferenceStoreError, .invalidSerial)
        }
    }

    func testWindowsRatioAndNegativeLogOnInterpretedIntensities() throws {
        let interpreted = ReferenceAnalysis(
            wavelengths: [900, 901, 902],
            sampleIntensity: [100, 100, 100],
            referenceIntensity: [200, 200, 200],
            reflectance: [0.5, 0.5, 0.5],
            absorbance: [0.3010299956639812, 0.3010299956639812, 0.3010299956639812]
        )
        let average = Spectrum(points: [
            SpectrumPoint(wavelength: 900, intensity: 50),
            SpectrumPoint(wavelength: 901, intensity: 200),
            SpectrumPoint(wavelength: 902, intensity: 0)
        ], source: .dlpspec)
        let result = try ReferenceAnalysis.average(sample: average, reference: interpreted)
        XCTAssertEqual(result.reflectance, [0.25, 1, nil])
        XCTAssertEqual(result.absorbance[0]!, -log10(0.25), accuracy: 1e-12)
        XCTAssertEqual(result.absorbance[1]!, 0, accuracy: 1e-12)
        XCTAssertNil(result.absorbance[2])
        XCTAssertEqual(result.invalidAbsorbanceCount, 1)
    }

    func testMismatchedAxisRejectsDerivedCalculation() throws {
        let interpreted = ReferenceAnalysis(
            wavelengths: [900, 901], sampleIntensity: [100, 100],
            referenceIntensity: [200, 200], reflectance: [0.5, 0.5],
            absorbance: [0.301, 0.301]
        )
        let changedConfig = Spectrum(points: [
            SpectrumPoint(wavelength: 900, intensity: 100),
            SpectrumPoint(wavelength: 902, intensity: 100)
        ], source: .dlpspec)
        XCTAssertThrowsError(try ReferenceAnalysis.average(sample: changedConfig, reference: interpreted)) { error in
            XCTAssertEqual(error as? ReferenceAnalysisError, .referenceMismatch)
        }
    }

    func testOfficialDLPReferencePathOnFixedRawBlobs() throws {
        let raw = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("scan_hadamard1_C36R011.bin")))
        let matrix = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("matrix_synthetic.bin")))
        let sample = try DLPSpectrumDecoder.decode(raw, keepRaw: true)
        let analysis = try ReferenceAnalysis.analyze(sample: sample, referenceRaw: raw, matrixRaw: matrix)
        XCTAssertEqual(analysis.wavelengths.count, 228)
        XCTAssertEqual(analysis.sampleIntensity, analysis.referenceIntensity)
        for index in analysis.wavelengths.indices {
            XCTAssertEqual(analysis.reflectance[index]!, 1, accuracy: 1e-9)
            XCTAssertEqual(analysis.absorbance[index]!, -log10(analysis.reflectance[index]!), accuracy: 1e-9)
        }
    }

    func testPreviousReferenceSurvivesRestartAndExportsDerivedCSV() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("scan_hadamard1_C36R011.bin")))
        let matrix = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("matrix_synthetic.bin")))
        let decoded = try DLPSpectrumDecoder.decode(raw, keepRaw: true)
        let local = LocalReference(serialNumber: "C36R011", capturedAt: decoded.timestamp,
            rawScan: Data(raw), config: decoded.config, pga: decoded.pga,
            temperature: decoded.temperature, humidity: decoded.humidity)
        try ReferenceStore(directory: directory).save(local)

        let restartedStore = ReferenceStore(directory: directory)
        let previous = try XCTUnwrap(restartedStore.load(serialNumber: "C36R011"))
        let restored = try DLPSpectrumDecoder.decode([UInt8](previous.rawScan))
        XCTAssertEqual(restored.configurationName, decoded.configurationName)
        XCTAssertEqual(restored.pga, decoded.pga)
        XCTAssertEqual(previous.config, decoded.config)

        let analysis = try ReferenceAnalysis.analyze(sample: decoded,
            referenceRaw: [UInt8](previous.rawScan), matrixRaw: matrix)
        let csv = try ReferenceCSV.string(sample: decoded, analysis: analysis,
            metadata: ReferenceExportMetadata(source: "Previous",
                referenceTimestamp: previous.capturedAt,
                referenceConfig: previous.config?.name, referencePGA: previous.pga))
        XCTAssertTrue(csv.contains("# reference_source=Previous\n"))
        XCTAssertTrue(csv.contains("# reference_config=Hadamard 1\n"))
        XCTAssertTrue(csv.contains("# sample_pga="))
        XCTAssertTrue(csv.contains("# reference_pga="))
        XCTAssertTrue(csv.contains("wavelength_nm,sample_intensity,reference_intensity,reflectance,absorbance_au\n"))
        XCTAssertEqual(csv.split(separator: "\n").filter { $0.first?.isNumber == true }.count, 228)
    }
}
