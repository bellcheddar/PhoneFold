import Foundation
import simd
import FoldCore

/// The GPU vertex layout for the backbone tube.
///
/// Kept separate from `TubeVertex` and from RealityKit on purpose: this is the exact byte
/// layout written into the vertex buffer, so it is worth being able to test the packing
/// without a Metal device or a display.
///
/// Colour is not stored. The four colour modes cross-fade at runtime, so colour is computed
/// in the shader from the attributes here rather than baked in and rewritten on every mode
/// change.
public struct RenderVertex: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// Continuous chain position in residues. Drives rainbow colouring and the sequence
    /// ribbon's highlight.
    public var residueParameter: Float
    /// 0...1 secondary structure confidence. Drives the emissive rim on helices.
    public var structureConfidence: Float
    /// 0 coil, 1 helix, 2 sheet. A float because vertex attributes are floats and an
    /// integer semantic would need a separate attribute format for no benefit.
    public var structureCode: Float
    /// Per-residue confidence, on the source's own scale. What this *means* depends on the
    /// trajectory's provenance: pLDDT for a predictor, denoising progress for a generator.
    public var residueConfidence: Float
    /// Linear RGB plus alpha, written per frame from the active colour mode.
    ///
    /// The scalars above are kept as well as this: they are what a shader would need to
    /// compute a mode itself, and keeping them means a future move to a Metal surface shader
    /// does not change the vertex layout again.
    public var colour: SIMD4<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, residueParameter: Float,
                structureConfidence: Float, structureCode: Float, residueConfidence: Float,
                colour: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) {
        self.position = position
        self.normal = normal
        self.residueParameter = residueParameter
        self.structureConfidence = structureConfidence
        self.structureCode = structureCode
        self.residueConfidence = residueConfidence
        self.colour = colour
    }
}

public enum TubeMeshPacker {

    /// Pack a tube mesh into the GPU vertex layout, sampling per-residue confidence along
    /// the chain and applying a colour mode.
    ///
    /// `residueConfidence` is indexed by the vertex's fractional residue parameter and
    /// interpolated linearly, because it is bounded and a spline would overshoot its range.
    ///
    /// Passing `from`, `to` and `t` cross-fades between two modes.
    public static func pack(_ mesh: TubeMesh,
                            residueConfidence confidence: [Float],
                            mode: ColourMode = .confidence,
                            fadingTo target: ColourMode? = nil,
                            t: Float = 0,
                            options: ColourOptions? = nil) -> [RenderVertex] {
        let colourOptions = options
            ?? ColourOptions(residueCount: Swift.max(confidence.count, 1))
        return mesh.vertices.map { vertex in
            var packed = RenderVertex(
                position: vertex.position,
                normal: vertex.normal,
                residueParameter: vertex.residueParameter,
                structureConfidence: vertex.structureConfidence,
                structureCode: Float(vertex.structure.rawValue),
                residueConfidence: sample(confidence, at: vertex.residueParameter))
            let rgb = target.map {
                Colouring.colour(packed, from: mode, to: $0, t: t, options: colourOptions)
            } ?? Colouring.colour(packed, mode: mode, options: colourOptions)
            packed.colour = SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
            return packed
        }
    }

    static func sample(_ values: [Float], at u: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        guard values.count > 1 else { return values[0] }
        let clamped = Swift.min(Swift.max(u, 0), Float(values.count - 1))
        let i = Swift.min(Int(clamped.rounded(.down)), values.count - 2)
        let t = clamped - Float(i)
        return values[i] + (values[i + 1] - values[i]) * t
    }

    /// Axis-aligned bounds, needed by RealityKit for culling. Returns nil for an empty mesh
    /// rather than a degenerate box at the origin, which would cull the protein away.
    public static func bounds(_ vertices: [RenderVertex])
        -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
        guard let first = vertices.first else { return nil }
        var minimum = first.position
        var maximum = first.position
        for v in vertices.dropFirst() {
            minimum = simd_min(minimum, v.position)
            maximum = simd_max(maximum, v.position)
        }
        return (minimum, maximum)
    }
}
