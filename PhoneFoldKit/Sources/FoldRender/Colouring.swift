import Foundation
import simd
import FoldCore

/// Linear-space RGB. Everything here is linear, not sRGB: the renderer works in linear space
/// and converting once at the end is the only way bloom and the Aurora grade behave.
public typealias LinearRGB = SIMD3<Float>

/// The Aurora Stage palette from PLAN.md section 2.
///
/// Hex values in the plan are sRGB, as hex always is. They are converted to linear here,
/// once, rather than being used raw: an sRGB triple treated as linear is visibly too dark in
/// the mid-tones and the whole stage looks muddy.
public enum Palette {

    /// sRGB hex to linear RGB.
    public static func linear(hex: UInt32) -> LinearRGB {
        func channel(_ byte: UInt32) -> Float {
            let s = Float(byte) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return LinearRGB(channel((hex >> 16) & 0xFF),
                         channel((hex >> 8) & 0xFF),
                         channel(hex & 0xFF))
    }

    // Stage palette
    public static let helixMagenta = linear(hex: 0xFF3D9A)
    public static let sheetCyan = linear(hex: 0x22E5FF)
    public static let coilSlate = linear(hex: 0x6B7C93)
    public static let confidenceAmber = linear(hex: 0xFCB900)
    public static let contactFlash = linear(hex: 0xFFFFFF)

    // Background gradient
    public static let backgroundDeep = linear(hex: 0x0B0A1F)
    public static let backgroundLift = linear(hex: 0x181432)

    // AlphaFold pLDDT ramp, low confidence to high
    public static let pLDDTVeryLow = linear(hex: 0xFF7D45)
    public static let pLDDTLow = linear(hex: 0xFFDB13)
    public static let pLDDTConfident = linear(hex: 0x65CBF3)
    public static let pLDDTVeryHigh = linear(hex: 0x0053D6)

    /// A secondary structure palette that survives deuteranopia and protanopia, for the
    /// Phase 4 accessibility work. Magenta against cyan is already reasonably safe; this
    /// separates them further on luminance as well as hue, so the two are distinguishable
    /// in greyscale.
    public static let helixAccessible = linear(hex: 0xFFB000)
    public static let sheetAccessible = linear(hex: 0x1A6FD4)
    public static let coilAccessible = linear(hex: 0x9AA5B1)
}

/// The four colour modes from PLAN.md Phase 2.
public enum ColourMode: String, CaseIterable, Sendable, Codable {
    /// AlphaFold pLDDT ramp. Orange resolving to blue is the money shot.
    case confidence
    /// Helix magenta, sheet cyan, coil slate.
    case secondaryStructure
    /// N terminus to C terminus.
    case rainbow
    /// Kyte-Doolittle, so core formation is visible.
    case hydrophobicity

    public var displayName: String {
        switch self {
        case .confidence: "Confidence"
        case .secondaryStructure: "Structure"
        case .rainbow: "Rainbow"
        case .hydrophobicity: "Hydrophobicity"
        }
    }

    /// What the confidence mode's legend should say, which depends on where the frames came
    /// from. Labelling denoising progress as pLDDT would be a claim the generator cannot
    /// support.
    public func legend(for source: ConfidenceSource) -> String {
        self == .confidence ? source.displayName : displayName
    }
}

public struct ColourOptions: Sendable {
    /// Use the colour-blind-safe secondary structure palette.
    public var accessiblePalette: Bool = false
    /// Number of residues, for normalising the rainbow.
    public var residueCount: Int
    /// Residue identities, for hydrophobicity. Empty falls back to neutral.
    public var residues: [AminoAcid]

    public init(residueCount: Int, residues: [AminoAcid] = [], accessiblePalette: Bool = false) {
        self.residueCount = residueCount
        self.residues = residues
        self.accessiblePalette = accessiblePalette
    }
}

public enum Colouring {

    /// Colour one vertex under one mode.
    public static func colour(_ vertex: RenderVertex, mode: ColourMode,
                              options: ColourOptions) -> LinearRGB {
        switch mode {
        case .confidence:
            return pLDDT(vertex.residueConfidence)
        case .secondaryStructure:
            return structureColour(vertex, options: options)
        case .rainbow:
            let n = Swift.max(options.residueCount - 1, 1)
            return rainbow(Swift.min(Swift.max(vertex.residueParameter / Float(n), 0), 1))
        case .hydrophobicity:
            return hydrophobicity(at: vertex.residueParameter, residues: options.residues)
        }
    }

    /// Blend two modes for the animated cross-fade. `t` of 0 is `from`, 1 is `to`.
    public static func colour(_ vertex: RenderVertex, from: ColourMode, to: ColourMode,
                              t: Float, options: ColourOptions) -> LinearRGB {
        let clamped = Swift.min(Swift.max(t, 0), 1)
        if clamped <= 0 { return colour(vertex, mode: from, options: options) }
        if clamped >= 1 { return colour(vertex, mode: to, options: options) }
        let a = colour(vertex, mode: from, options: options)
        let b = colour(vertex, mode: to, options: options)
        // Linear-space blend. Blending in sRGB darkens the midpoint of a cross-fade, which
        // reads as a dip to grey halfway through the transition.
        return a + (b - a) * clamped
    }

    // MARK: - Modes

    /// The AlphaFold pLDDT ramp, smoothed.
    ///
    /// AlphaFold's viewer uses hard bands at 50, 70 and 90. Hard bands strobe when confidence
    /// drifts across a boundary during a fold, so the transitions here are **centred on those
    /// boundaries** and 20 points wide. A residue at exactly 90 sits halfway into dark blue,
    /// above 90 is predominantly dark blue, and the band semantics a structural biologist
    /// reads are preserved while the animation stays smooth.
    public static func pLDDT(_ value: Float) -> LinearRGB {
        let v = Swift.min(Swift.max(value, 0), 100)
        if v <= 40 { return Palette.pLDDTVeryLow }
        if v <= 60 {
            return mix(Palette.pLDDTVeryLow, Palette.pLDDTLow, (v - 40) / 20)
        }
        if v <= 80 {
            return mix(Palette.pLDDTLow, Palette.pLDDTConfident, (v - 60) / 20)
        }
        if v <= 100 {
            return mix(Palette.pLDDTConfident, Palette.pLDDTVeryHigh, (v - 80) / 20)
        }
        return Palette.pLDDTVeryHigh
    }

    static func structureColour(_ vertex: RenderVertex, options: ColourOptions) -> LinearRGB {
        let structure = SecondaryStructure(rawValue: UInt8(Swift.max(vertex.structureCode, 0)))
            ?? .coil
        let coil = options.accessiblePalette ? Palette.coilAccessible : Palette.coilSlate
        let target: LinearRGB
        switch structure {
        case .helix: target = options.accessiblePalette ? Palette.helixAccessible : Palette.helixMagenta
        case .sheet: target = options.accessiblePalette ? Palette.sheetAccessible : Palette.sheetCyan
        case .coil: return coil
        }
        // Fade in from coil with confidence, so colour grows with the shape rather than
        // snapping on the frame the assignment flips.
        return mix(coil, target, Swift.min(Swift.max(vertex.structureConfidence, 0), 1))
    }

    /// N to C, through the spectrum. Hue only, at fixed saturation and value, so no residue
    /// is darker than another and the eye reads position rather than brightness.
    public static func rainbow(_ t: Float) -> LinearRGB {
        // 0 (red) to 0.75 (violet); going the whole way round would make the two termini
        // the same colour, which defeats the point.
        hsv(hue: Swift.min(Swift.max(t, 0), 1) * 0.75, saturation: 0.85, value: 1.0)
    }

    /// Kyte-Doolittle, mapped blue (hydrophilic, -4.5) through slate to amber
    /// (hydrophobic, +4.5), so a packing core lights up warm.
    public static func hydrophobicity(at parameter: Float,
                                      residues: [AminoAcid]) -> LinearRGB {
        guard !residues.isEmpty else { return Palette.coilSlate }
        let index = Swift.min(Swift.max(Int(parameter.rounded()), 0), residues.count - 1)
        let scaled = (residues[index].hydropathy + 4.5) / 9.0     // 0...1
        let t = Swift.min(Swift.max(scaled, 0), 1)
        return t < 0.5
            ? mix(Palette.sheetCyan, Palette.coilSlate, t * 2)
            : mix(Palette.coilSlate, Palette.confidenceAmber, (t - 0.5) * 2)
    }

    // MARK: - Helpers

    @inlinable
    public static func mix(_ a: LinearRGB, _ b: LinearRGB, _ t: Float) -> LinearRGB {
        a + (b - a) * Swift.min(Swift.max(t, 0), 1)
    }

    static func hsv(hue: Float, saturation: Float, value: Float) -> LinearRGB {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(h)
        let f = h - Float(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        let srgb: LinearRGB
        switch sector % 6 {
        case 0: srgb = LinearRGB(value, t, p)
        case 1: srgb = LinearRGB(q, value, p)
        case 2: srgb = LinearRGB(p, value, t)
        case 3: srgb = LinearRGB(p, q, value)
        case 4: srgb = LinearRGB(t, p, value)
        default: srgb = LinearRGB(value, p, q)
        }
        // HSV is defined on sRGB values, so the result has to be linearised like any other
        // sRGB triple rather than used directly.
        func toLinear(_ s: Float) -> Float {
            s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return LinearRGB(toLinear(srgb.x), toLinear(srgb.y), toLinear(srgb.z))
    }
}
