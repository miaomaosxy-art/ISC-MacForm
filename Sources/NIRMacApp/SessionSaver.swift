import AppKit
import DLPSpec
import Foundation
import NIRDevice
import UniformTypeIdentifiers

enum SessionSaveError: Error, Equatable {
    case noSpectra
    case panelCancelled
    case writeFailed(String)

    var userMessage: String {
        switch self {
        case .noSpectra: return "No spectrum to save."
        case .panelCancelled: return "Save cancelled."
        case .writeFailed(let m): return "Could not save: \(m)"
        }
    }
}

/// CSV / session / optional raw export. Filename scheme:
///   single:  C36R011_20260923_143012.csv
///   session: NIR_C36R011_20260923_143012/{scan_001.csv,...,average.csv}
enum SessionSaver {
    @MainActor
    static func saveSingleCSV(spectrum: Spectrum, serial: String?) -> Result<URL, SessionSaveError> {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SpectrumFileNamer.singleCSVName(
            serial: serial ?? spectrum.serialNumber,
            date: spectrum.timestamp
        )
        guard panel.runModal() == .OK, let url = panel.url else {
            return .failure(.panelCancelled)
        }
        do {
            try spectrum.csvString().write(to: url, atomically: true, encoding: .utf8)
            return .success(url)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    @MainActor
    static func saveSession(
        scans: [Spectrum],
        average: Spectrum?,
        serial: String?,
        saveRaw: Bool,
        referenceAnalyses: [ReferenceAnalysis] = [],
        referenceMetadata: ReferenceExportMetadata? = nil,
        averageAnalysis: ReferenceAnalysis? = nil,
        date: Date = Date()
    ) -> Result<URL, SessionSaveError> {
        guard !scans.isEmpty else { return .failure(.noSpectra) }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Session Here"
        panel.message = "Choose a parent folder for the scan session directory."
        guard panel.runModal() == .OK, let parent = panel.url else {
            return .failure(.panelCancelled)
        }

        let sessionName = SpectrumFileNamer.sessionDirectoryName(
            serial: serial ?? scans.first?.serialNumber,
            date: date
        )
        let sessionDir = parent.appendingPathComponent(sessionName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            for (i, scan) in scans.enumerated() {
                let csvURL = sessionDir.appendingPathComponent(SpectrumFileNamer.scanCSVName(index: i + 1))
                let csv: String
                if referenceAnalyses.indices.contains(i), let referenceMetadata {
                    csv = try ReferenceCSV.string(sample: scan,
                                                   analysis: referenceAnalyses[i],
                                                   metadata: referenceMetadata)
                } else {
                    csv = scan.csvString()
                }
                try csv.write(to: csvURL, atomically: true, encoding: .utf8)
                if saveRaw, let raw = scan.raw {
                    let binURL = sessionDir.appendingPathComponent(SpectrumFileNamer.scanRawName(index: i + 1))
                    try Data(raw).write(to: binURL)
                }
            }
            if let average {
                let avgURL = sessionDir.appendingPathComponent(SpectrumFileNamer.averageCSVName)
                let csv: String
                if let averageAnalysis, let referenceMetadata {
                    csv = try ReferenceCSV.string(sample: average, analysis: averageAnalysis,
                                                  metadata: referenceMetadata)
                } else {
                    csv = average.csvString()
                }
                try csv.write(to: avgURL, atomically: true, encoding: .utf8)
            }
            return .success(sessionDir)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Save a single spectrum plus optional raw next to a chosen CSV (single-scan raw path).
    @MainActor
    static func saveSingleCSVWithRaw(spectrum: Spectrum, serial: String?, saveRaw: Bool,
                                     analysis: ReferenceAnalysis? = nil,
                                     referenceMetadata: ReferenceExportMetadata? = nil) -> Result<URL, SessionSaveError> {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SpectrumFileNamer.singleCSVName(
            serial: serial ?? spectrum.serialNumber,
            date: spectrum.timestamp
        )
        guard panel.runModal() == .OK, let url = panel.url else {
            return .failure(.panelCancelled)
        }
        do {
            let csv: String
            if let analysis, let referenceMetadata {
                csv = try ReferenceCSV.string(sample: spectrum, analysis: analysis,
                                              metadata: referenceMetadata)
            } else {
                csv = spectrum.csvString()
            }
            try csv.write(to: url, atomically: true, encoding: .utf8)
            if saveRaw, let raw = spectrum.raw {
                let binURL = url.deletingPathExtension().appendingPathExtension("bin")
                try Data(raw).write(to: binURL)
            }
            return .success(url)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }
}
