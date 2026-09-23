import XCTest
@testable import DLPSpec
@testable import NIRDevice
@testable import NIRProtocol

/// Golden Test Vector for the verified NIR-M-R2 complete-scan decode path.
///
/// Fixture is a live 3822-byte complete scan from NIR-M-R2 / C36R011 / Hadamard 1.
/// Values describe THIS fixture only — do not hardcode for other configs/devices.
final class GoldenDecodeTests: XCTestCase {
    private var fixtureURL: URL {
        // Tests/NIRMacTests/Fixtures/scan_hadamard1_C36R011.bin
        let this = URL(fileURLWithPath: #filePath)
        return this
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("scan_hadamard1_C36R011.bin")
    }

    private func loadFixture() throws -> [UInt8] {
        let data = try Data(contentsOf: fixtureURL)
        return [UInt8](data)
    }

    func testFixtureExistsAndSize() throws {
        let raw = try loadFixture()
        XCTAssertEqual(raw.count, 3822, "Golden complete scan is 3822 bytes")
    }

    func testGoldenDecodePass() throws {
        let raw = try loadFixture()
        XCTAssertTrue(DLPSpectrumDecoder.isAvailable)
        let spectrum = try DLPSpectrumDecoder.decode(raw, keepRaw: true)

        XCTAssertEqual(spectrum.points.count, 228, "Hadamard 1 fixture has 228 points")
        XCTAssertEqual(spectrum.serialNumber, "C36R011")
        XCTAssertEqual(spectrum.configurationName, "Hadamard 1")

        let first = spectrum.points[0]
        let last = spectrum.points[spectrum.points.count - 1]

        XCTAssertEqual(first.wavelength, 901.816, accuracy: 1e-3, "first wavelength nm")
        XCTAssertEqual(last.wavelength, 1701.175, accuracy: 1e-3, "last wavelength nm")

        // Intensities are fixture-specific (this capture: 1522 / 615).
        XCTAssertEqual(first.intensity, 1522)
        XCTAssertEqual(last.intensity, 615)

        // Wavelength axis is strictly increasing (tiny blips rejected by validate).
        for i in 1..<spectrum.points.count {
            XCTAssertGreaterThan(spectrum.points[i].wavelength, spectrum.points[i - 1].wavelength - 1e-9)
        }
    }

    func testWavelengthAxisStableAcrossRepeatedDecode() throws {
        let raw = try loadFixture()
        let a = try DLPSpectrumDecoder.decode(raw)
        let b = try DLPSpectrumDecoder.decode(raw)
        XCTAssertEqual(a.points.count, b.points.count)
        var maxDelta = 0.0
        for i in 0..<a.points.count {
            maxDelta = max(maxDelta, abs(a.points[i].wavelength - b.points[i].wavelength))
        }
        XCTAssertEqual(maxDelta, 0.0, accuracy: 1e-9, "same raw must give identical wavelength axis")
    }

    func testAverageRequiresMatchingWavelengthAxis() throws {
        let raw = try loadFixture()
        let a = try DLPSpectrumDecoder.decode(raw)
        let b = try DLPSpectrumDecoder.decode(raw)
        let avg = try SpectrumMath.average([a, b])
        XCTAssertEqual(avg.points.count, 228)
        XCTAssertEqual(avg.points[0].intensity, a.points[0].intensity)
        XCTAssertEqual(avg.points[227].intensity, a.points[227].intensity)

        // Mutating a wavelength must reject averaging.
        var badPoints = b.points
        badPoints[10] = SpectrumPoint(wavelength: badPoints[10].wavelength + 0.5, intensity: badPoints[10].intensity)
        let bad = Spectrum(points: badPoints, source: b.source)
        XCTAssertThrowsError(try SpectrumMath.average([a, bad])) { error in
            guard let e = error as? SpectrumAverageError else {
                return XCTFail("expected SpectrumAverageError")
            }
            if case .wavelengthMismatch = e { /* ok */ } else {
                XCTFail("expected wavelengthMismatch, got \(e)")
            }
        }
    }

    func testCSVHeaderMetadata() throws {
        let raw = try loadFixture()
        let spectrum = try DLPSpectrumDecoder.decode(raw)
        let csv = spectrum.csvString()
        XCTAssertTrue(csv.contains("# serial=C36R011"))
        XCTAssertTrue(csv.contains("# config=Hadamard 1"))
        XCTAssertTrue(csv.contains("# points=228"))
        XCTAssertTrue(csv.contains("# timestamp="))
        XCTAssertTrue(csv.contains("wavelength_nm,intensity"))
    }

    func testScanConfigFieldsFromDecode() throws {
        let raw = try loadFixture()
        let spectrum = try DLPSpectrumDecoder.decode(raw)
        let cfg = try XCTUnwrap(spectrum.config)
        XCTAssertEqual(cfg.name, "Hadamard 1")
        XCTAssertEqual(cfg.scanTypeName, "Hadamard")
        // Geometry comes from serialized config; assert only what the fixture encodes.
        if let start = cfg.wavelengthStartNM {
            XCTAssertEqual(start, 900, accuracy: 5)
        }
        if let end = cfg.wavelengthEndNM {
            XCTAssertEqual(end, 1700, accuracy: 5)
        }
        if let patterns = cfg.numPatterns {
            XCTAssertEqual(patterns, 228)
        }
        XCTAssertNotNil(cfg.numRepeats)
        XCTAssertNotNil(cfg.widthPx)
    }

    func testFilenameHelpers() {
        let date = Date(timeIntervalSince1970: 1_758_000_000) // fixed, formatter uses local tz
        let csv = SpectrumFileNamer.singleCSVName(serial: "C36R011", date: date)
        XCTAssertTrue(csv.hasPrefix("C36R011_"))
        XCTAssertTrue(csv.hasSuffix(".csv"))
        let dir = SpectrumFileNamer.sessionDirectoryName(serial: "C36R011", date: date)
        XCTAssertTrue(dir.hasPrefix("NIR_C36R011_"))
        XCTAssertEqual(SpectrumFileNamer.scanCSVName(index: 1), "scan_001.csv")
        XCTAssertEqual(SpectrumFileNamer.scanRawName(index: 5), "scan_005.bin")
        XCTAssertEqual(SpectrumFileNamer.averageCSVName, "average.csv")
    }
}
