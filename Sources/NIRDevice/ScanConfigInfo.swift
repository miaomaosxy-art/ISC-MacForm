import Foundation

/// Scan configuration fields that exist in the protocol or serialized DLP config.
/// Do not invent missing values — leave them nil and show "—" in the UI.
public struct ScanConfigInfo: Sendable, Equatable, Codable {
    /// Config display name from serialized scan config (e.g. "Hadamard 1").
    public var name: String?
    /// SCAN_TYPES raw value when known: 0 Column, 1 Hadamard, 2 Slew.
    public var scanTypeCode: Int?
    /// scanConfigIndex from serialized config.
    public var configIndex: Int?
    /// Nominal config range (nm) from serialized config.
    public var wavelengthStartNM: Int?
    public var wavelengthEndNM: Int?
    /// Pattern pixel width from serialized config.
    public var widthPx: Int?
    /// Total desired spectrum points from serialized config.
    public var numPatterns: Int?
    /// Device-side hardware repeats before averaging (not app Repeat Scan).
    public var numRepeats: Int?
    /// Number of slew sections in the config (1 for Hadamard/Column).
    public var numSections: Int?

    /// Active config index from NNO_CMD_SCAN_GET_ACT_CFG (0x23).
    public var activeConfigIndex: Int?
    /// Config count from NNO_CMD_SCAN_CFG_NUM (0x22).
    public var configCount: Int?

    public init(
        name: String? = nil,
        scanTypeCode: Int? = nil,
        configIndex: Int? = nil,
        wavelengthStartNM: Int? = nil,
        wavelengthEndNM: Int? = nil,
        widthPx: Int? = nil,
        numPatterns: Int? = nil,
        numRepeats: Int? = nil,
        numSections: Int? = nil,
        activeConfigIndex: Int? = nil,
        configCount: Int? = nil
    ) {
        self.name = name
        self.scanTypeCode = scanTypeCode
        self.configIndex = configIndex
        self.wavelengthStartNM = wavelengthStartNM
        self.wavelengthEndNM = wavelengthEndNM
        self.widthPx = widthPx
        self.numPatterns = numPatterns
        self.numRepeats = numRepeats
        self.numSections = numSections
        self.activeConfigIndex = activeConfigIndex
        self.configCount = configCount
    }

    /// Type label only from the numeric SCAN_TYPES code. Unknown code stays nil.
    public var scanTypeName: String? {
        guard let code = scanTypeCode else { return nil }
        switch code {
        case 0: return "Column"
        case 1: return "Hadamard"
        case 2: return "Slew"
        default: return nil
        }
    }

    public var rangeText: String? {
        guard let a = wavelengthStartNM, let b = wavelengthEndNM else { return nil }
        return "\(a) – \(b) nm"
    }
}
