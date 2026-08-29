import Foundation
import simd
import FoldCore

/// The colour ramp, baked into a texture so the protein is drawn as a gradient.
///
/// **Why this exists.** RealityKit's stock materials ignore a per-vertex colour channel, so
/// colour was delivered by splitting the mesh into parts and tinting each part's material -
/// see `ColourBuckets`. Every part is one flat colour, which means the ramp arrives as a
/// staircase, and the step size is set by how finely the colours are quantised. On a strand
/// ribbon several angstroms wide and lit almost evenly across its face, that staircase was
/// plainly visible: a screenshot of one showed 26 discrete steps along it.
///
/// Making the steps finer is a dead end. The quantiser's working memory grows with the cube
/// of the level count, and going from 16 levels to 48 - which only takes the step from 6.7%
/// to 2.1% of the range, still visible - already cost 0.38 ms a frame in zeroing alone.
///
/// A texture has no steps. The ramp is baked once per colour mode into a small image, each
/// vertex carries the coordinate that looks its own colour up in it, and the GPU interpolates
/// between texels for free. One material, one draw call, and a continuous gradient.
///
/// The texels are produced by calling `Colouring` itself on a synthetic vertex, so the
/// texture cannot drift away from the colour the rest of the code believes in.
public enum ColourRamp {

    /// Texels across the ramp. Wide enough to resolve one residue of a 314-residue protein in
    /// the modes whose colour varies per residue, with room to spare.
    public static let width = 1024
    /// One row per secondary structure: helix, sheet, coil.
    public static let height = 3

    /// A vertex standing in for one texel of the ramp.
    ///
    /// Every field a mode might read is set from the same `u`, and each mode reads only the
    /// one it cares about, so a single grid serves all four.
    static func sample(u: Float, row: Int, residueCount: Int) -> RenderVertex {
        let structure = SecondaryStructure(rawValue: UInt8(row)) ?? .coil
        return RenderVertex(
            position: .zero, normal: SIMD3<Float>(0, 0, 1),
            residueParameter: u * Float(Swift.max(residueCount - 1, 1)),
            structureConfidence: u,
            structureCode: Float(structure.rawValue),
            residueConfidence: u * 100)
    }

    /// The ramp as 8-bit sRGB RGBA texels, row-major.
    ///
    /// Returned as bytes rather than as an image so this stays testable, and buildable, with
    /// no graphics framework in the way.
    public static func texels(mode: ColourMode, fadingTo target: ColourMode? = nil,
                              t: Float = 0, options: ColourOptions) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let u = Float(column) / Float(width - 1)
                let vertex = sample(u: u, row: row, residueCount: options.residueCount)
                let linear = target.map {
                    Colouring.colour(vertex, from: mode, to: $0, t: t, options: options)
                } ?? Colouring.colour(vertex, mode: mode, options: options)
                let offset = (row * width + column) * 4
                pixels[offset] = encode(linear.x)
                pixels[offset + 1] = encode(linear.y)
                pixels[offset + 2] = encode(linear.z)
                pixels[offset + 3] = 255
            }
        }
        return pixels
    }

    /// Where a vertex looks itself up in the ramp.
    ///
    /// Inset by half a texel at each end so linear filtering never reaches past the edge of
    /// the row, which with the default repeat addressing would wrap a fully confident residue
    /// round to the colour of a hopeless one.
    public static func coordinate(for vertex: RenderVertex, mode: ColourMode,
                                  options: ColourOptions) -> SIMD2<Float> {
        let u: Float
        switch mode {
        case .confidence:
            u = vertex.residueConfidence / 100
        case .secondaryStructure:
            u = vertex.structureConfidence
        case .rainbow, .hydrophobicity:
            u = vertex.residueParameter / Float(Swift.max(options.residueCount - 1, 1))
        }
        let inset = 0.5 / Float(width)
        let clamped = Swift.min(Swift.max(u, 0), 1) * (1 - 2 * inset) + inset
        // Only secondary structure differs between rows; the other modes fill every row
        // identically, so any row answers for them.
        let row = mode == .secondaryStructure
            ? Swift.min(Swift.max(Int(vertex.structureCode.rounded()), 0), height - 1) : 0
        return SIMD2<Float>(clamped, (Float(row) + 0.5) / Float(height))
    }

    /// Linear to 8-bit sRGB.
    static func encode(_ value: Float) -> UInt8 {
        let v = Swift.min(Swift.max(value, 0), 1)
        let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(Swift.min(Swift.max(encoded * 255, 0), 255).rounded())
    }
}
