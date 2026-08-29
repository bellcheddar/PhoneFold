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
    /// Where this vertex reads its colour out of the ramp texture. See `ColourRamp`.
    ///
    /// This is what the stock material actually samples, and the reason the protein is drawn
    /// as a gradient rather than as a staircase of flat-tinted parts. `colour` above is kept
    /// because it is still the truth for tests, for snapshots, and for any future path that
    /// can read a vertex colour channel.
    public var rampCoordinate: SIMD2<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, residueParameter: Float,
                structureConfidence: Float, structureCode: Float, residueConfidence: Float,
                colour: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                rampCoordinate: SIMD2<Float> = .zero) {
        self.position = position
        self.normal = normal
        self.residueParameter = residueParameter
        self.structureConfidence = structureConfidence
        self.structureCode = structureCode
        self.residueConfidence = residueConfidence
        self.colour = colour
        self.rampCoordinate = rampCoordinate
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
            packed.rampCoordinate = ColourRamp.coordinate(for: packed, mode: mode,
                                                          options: colourOptions)
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

    /// A halo shell: the same surface pushed out along its own normals.
    ///
    /// This is glow done in object space, because screen-space bloom is not reachable from
    /// here - see `PostProcess.metal` for the three APIs that were tried. Offsetting along
    /// the normal keeps the halo welded to the tube by construction, which is the property
    /// that matters: a glow drawn from projected residue positions would drift out of
    /// register with the geometry at exactly the moments the fold is most interesting, and
    /// the drift would look like a rendering fault rather than a lighting choice.
    ///
    /// Only the far wall is drawn, and `farFacing` selects it here on the CPU rather than
    /// asking the renderer to cull. Neither `faceCulling = .front` nor reversing the triangle
    /// winding had any effect: this configuration culls nothing, so the shell drew its near
    /// wall and the tube disappeared behind a flat silhouette. Choosing the triangles
    /// ourselves is the one version of this that cannot be ignored.
    ///
    /// - Parameters:
    ///   - vertices: the packed tube.
    ///   - offset: how far to push, in scene units.
    ///   - brightness: multiplies the colour. Above 1 the halo is brighter than the surface
    ///     it surrounds, which is what makes it read as emission rather than as a smear.
    public static func shell(_ vertices: [RenderVertex],
                             offset: Float,
                             brightness: Float) -> [RenderVertex] {
        guard offset > 0 else { return vertices }
        return vertices.map { vertex in
            var shifted = vertex
            shifted.position = vertex.position + vertex.normal * offset
            shifted.colour = SIMD4<Float>(vertex.colour.x * brightness,
                                          vertex.colour.y * brightness,
                                          vertex.colour.z * brightness,
                                          vertex.colour.w)
            return shifted
        }
    }

    /// Swap two corners of every triangle, so each face points the other way.
    ///
    /// Used to build an inverted hull. Nothing else about the mesh changes: same vertices,
    /// same count, same order of triangles, so a mesh allocated from the original template
    /// still has exactly the right capacity.
    public static func reverseWinding(_ indices: [UInt32]) -> [UInt32] {
        var reversed = indices
        var triangle = 0
        while triangle * 3 + 2 < reversed.count {
            reversed.swapAt(triangle * 3 + 1, triangle * 3 + 2)
            triangle += 1
        }
        return reversed
    }

    /// The triangles of a closed shell that face away from the viewer.
    ///
    /// This is back-face culling, done here because the renderer would not do it: see the
    /// note on `shell`.
    ///
    /// Two details decide whether the result looks like a rim of light or like a torn edge.
    ///
    /// The direction to the viewer is computed **per triangle** from the eye position, not
    /// taken as one axis for the whole mesh. A single axis is the orthographic assumption,
    /// and the stage's camera has a 42 degree field of view: toward the edges of a protein
    /// that fills the frame the true direction is several degrees off, and the silhouette it
    /// selects is wrong by a band of triangles.
    ///
    /// And triangles are kept only when they face away by a small margin, which steadies the
    /// band right on the silhouette where the sign is near zero.
    ///
    /// The margin does not make the rim's outer edge smooth, and nothing here can: the halo
    /// is selected a whole triangle at a time, so its boundary is a chain of triangle edges
    /// and shows fine teeth. Widening the margin only moves which triangles are chosen. What
    /// does control how visible the teeth are is the rim's width against the tessellation -
    /// a thinner halo makes the same teeth proportionally larger, which is why the halo is
    /// set at roughly half the coil radius rather than trimmed down. Smoothing it properly
    /// would need a per-vertex alpha fade, and stock materials ignore vertex colour, which is
    /// the constraint this whole renderer is built around.
    ///
    /// - Parameters:
    ///   - eye: the viewer's position, in the same space as the vertices.
    ///   - bias: how firmly a triangle must face away, as a cosine. Zero is the exact
    ///     silhouette.
    ///
    /// Triangles the offset has turned inside out are dropped as well. Where the tube turns
    /// more tightly than the halo is thick, neighbouring rings cross over each other once
    /// pushed out along their normals, and the crossed triangles show as fine hairs standing
    /// off the outline. An inverted triangle is recognisable without knowing anything about
    /// the curvature: its geometric normal, the cross product of two edges, ends up opposing
    /// the vertex normals it was built from. Which sign means "agreeing" depends on the
    /// mesh's winding, so the majority across the mesh decides it and the minority is
    /// discarded - self-calibrating, rather than hard-coding a convention that a later change
    /// to the sweep could quietly reverse.
    /// - Returns: indices for the triangles pointing away, in their original order, so the
    ///   result is deterministic.
    public static func farFacing(vertices: [RenderVertex], indices: [UInt32],
                                 eye: SIMD3<Float>, bias: Float = 0.10) -> [UInt32] {
        guard !vertices.isEmpty, indices.count >= 3 else { return [] }
        let triangleCount = indices.count / 3

        // Which way round this mesh is wound: the sign that agrees between the geometric
        // normal and the vertex normals for most of its triangles.
        func agreement(_ triangle: Int) -> Float {
            let a = Int(indices[triangle * 3])
            let b = Int(indices[triangle * 3 + 1])
            let c = Int(indices[triangle * 3 + 2])
            guard a < vertices.count, b < vertices.count, c < vertices.count else { return 0 }
            let geometric = simd_cross(vertices[b].position - vertices[a].position,
                                       vertices[c].position - vertices[a].position)
            let smooth = vertices[a].normal + vertices[b].normal + vertices[c].normal
            return simd_dot(geometric, smooth)
        }
        // Computed once and kept, not recomputed inside the selection loop: the same cross
        // product per triangle twice over is the whole of the halo's cost twice over.
        var agreements = [Float](repeating: 0, count: triangleCount)
        var agreeing = 0
        for triangle in 0..<triangleCount {
            let value = agreement(triangle)
            agreements[triangle] = value
            if value > 0 { agreeing += 1 }
        }
        let windingSign: Float = agreeing * 2 >= triangleCount ? 1 : -1

        var kept: [UInt32] = []
        kept.reserveCapacity(indices.count / 2)
        var triangle = 0
        while triangle * 3 + 2 < indices.count {
            let a = Int(indices[triangle * 3])
            let b = Int(indices[triangle * 3 + 1])
            let c = Int(indices[triangle * 3 + 2])
            if a < vertices.count, b < vertices.count, c < vertices.count {
                // The face normal from the three vertex normals rather than from a cross
                // product of the edges: the tube's vertex normals are already the swept
                // cross section's outward normals, and a degenerate triangle at a tight turn
                // would give a cross product of zero length and a random sign.
                let normal = vertices[a].normal + vertices[b].normal + vertices[c].normal
                let centroid = (vertices[a].position + vertices[b].position
                                + vertices[c].position) / 3
                let toEye = eye - centroid
                let lengths = simd_length(normal) * simd_length(toEye)
                let upright = agreements[triangle] * windingSign > 0
                if upright, lengths > 0, simd_dot(normal, toEye) / lengths < -bias {
                    kept.append(indices[triangle * 3])
                    kept.append(indices[triangle * 3 + 1])
                    kept.append(indices[triangle * 3 + 2])
                }
            }
            triangle += 1
        }
        return kept
    }
}
