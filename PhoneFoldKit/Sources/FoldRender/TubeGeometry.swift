import Foundation
import simd
import FoldCore

/// One vertex of the swept backbone tube.
///
/// Colour is deliberately absent: it is a function of the colour mode, which changes at
/// runtime with an animated cross-fade, so it is applied per frame rather than baked into
/// geometry. What is baked in is everything a colour mode needs — which residue this vertex
/// belongs to, and how confident its secondary structure is.
public struct TubeVertex: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// Continuous position along the chain, in residues. Fractional between residues.
    public var residueParameter: Float
    /// 0...1, how strongly this point has taken on its secondary structure. Drives the
    /// emissive rim on helices and the arrowhead extrusion on strands.
    public var structureConfidence: Float
    public var structure: SecondaryStructure

    public init(position: SIMD3<Float>, normal: SIMD3<Float>,
                residueParameter: Float, structureConfidence: Float,
                structure: SecondaryStructure) {
        self.position = position
        self.normal = normal
        self.residueParameter = residueParameter
        self.structureConfidence = structureConfidence
        self.structure = structure
    }
}

public struct TubeMesh: Sendable {
    public var vertices: [TubeVertex]
    public var indices: [UInt32]

    public var triangleCount: Int { indices.count / 3 }

    /// Every position and normal finite, and every index in range.
    ///
    /// The Phase 2 gate asserts zero geometry NaNs across a full sample trajectory, and this
    /// is the predicate it uses. A NaN vertex does not crash: it silently removes triangles
    /// from the render, which looks like a hole in the protein.
    public var isWellFormed: Bool {
        for v in vertices {
            guard v.position.x.isFinite, v.position.y.isFinite, v.position.z.isFinite,
                  v.normal.x.isFinite, v.normal.y.isFinite, v.normal.z.isFinite,
                  v.residueParameter.isFinite, v.structureConfidence.isFinite
            else { return false }
            // A degenerate normal shades as a black facet.
            guard simd_length(v.normal) > 0.5 else { return false }
        }
        return indices.allSatisfy { $0 < UInt32(vertices.count) }
    }
}

/// Sweeps a cross section along a spline through the CA trace.
///
/// The cross section **morphs** with per-residue secondary structure confidence rather than
/// switching, which is what makes structure grow in instead of snapping: PLAN.md Phase 2 is
/// explicit that nothing should pop.
public enum TubeGeometry {

    public struct Profile: Sendable {
        /// Radius of the circular section used for coil.
        public var coilRadius: Float = 0.45
        /// Radius of the thicker circular section used for helix.
        public var helixRadius: Float = 0.80
        /// Half-width of the flattened ribbon used for sheet.
        public var sheetHalfWidth: Float = 1.40
        /// Half-thickness of that ribbon.
        public var sheetHalfThickness: Float = 0.28
        /// Spline samples per residue. Higher is smoother and costs vertices.
        public var samplesPerResidue: Int = 6
        /// Vertices around the cross section.
        public var radialSegments: Int = 12

        public init() {}
    }

    /// Build the tube for one frame.
    ///
    /// Returns an empty mesh rather than trapping for a chain too short to sweep: a frame
    /// should degrade, not take the renderer down.
    public static func build(caPositions ca: [SIMD3<Float>],
                             secondaryStructure ss: [SSAssignment],
                             profile: Profile = Profile()) -> TubeMesh {
        guard ca.count >= 2, ss.count == ca.count,
              profile.radialSegments >= 3, profile.samplesPerResidue >= 1
        else { return TubeMesh(vertices: [], indices: []) }

        let sampleCount = (ca.count - 1) * profile.samplesPerResidue + 1
        var centres: [SIMD3<Float>] = []
        var tangents: [SIMD3<Float>] = []
        var parameters: [Float] = []
        centres.reserveCapacity(sampleCount)

        for s in 0..<sampleCount {
            let u = Float(s) / Float(profile.samplesPerResidue)
            centres.append(splinePoint(ca, at: u))
            parameters.append(u)
        }
        // Tangents by central difference on the sampled curve, which is stable even where
        // the analytic derivative vanishes at a cusp.
        for s in 0..<sampleCount {
            let a = centres[Swift.max(s - 1, 0)]
            let b = centres[Swift.min(s + 1, sampleCount - 1)]
            let delta = b - a
            tangents.append(simd_length(delta) > 1e-6
                            ? simd_normalize(delta)
                            : SIMD3<Float>(0, 0, 1))
        }

        // Parallel transport the reference frame along the curve.
        //
        // A Frenet frame would be the obvious choice and is wrong: its normal flips through
        // an inflection point, which twists the ribbon by 180 degrees in a single step.
        // Transporting the frame by the minimal rotation between consecutive tangents has no
        // such discontinuity.
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(sampleCount)
        var reference = perpendicular(to: tangents[0])
        normals.append(reference)
        for s in 1..<sampleCount {
            let rotation = minimalRotation(from: tangents[s - 1], to: tangents[s])
            reference = simd_normalize(rotation.act(reference))
            // Re-orthogonalise against drift accumulated over hundreds of steps.
            reference = simd_normalize(reference - tangents[s] * simd_dot(reference, tangents[s]))
            normals.append(reference)
        }

        var vertices: [TubeVertex] = []
        vertices.reserveCapacity(sampleCount * profile.radialSegments)
        var indices: [UInt32] = []
        indices.reserveCapacity((sampleCount - 1) * profile.radialSegments * 6)

        for s in 0..<sampleCount {
            let tangent = tangents[s]
            let normal = normals[s]
            let binormal = simd_normalize(simd_cross(tangent, normal))
            let (structure, confidence) = interpolatedStructure(ss, at: parameters[s])
            let (halfWidth, halfThickness) = section(for: structure, confidence: confidence,
                                                     profile: profile)

            for r in 0..<profile.radialSegments {
                let angle = 2 * Float.pi * Float(r) / Float(profile.radialSegments)
                let offset = normal * (cos(angle) * halfWidth)
                    + binormal * (sin(angle) * halfThickness)
                // Surface normal of an ellipse is not the radial direction; scale each axis
                // by the reciprocal of its half-extent. Getting this wrong makes a flattened
                // strand light as though it were still round.
                let rawNormal = normal * (cos(angle) / Swift.max(halfWidth, 1e-4))
                    + binormal * (sin(angle) / Swift.max(halfThickness, 1e-4))
                let unit = simd_length(rawNormal) > 1e-6
                    ? simd_normalize(rawNormal) : normal
                vertices.append(TubeVertex(position: centres[s] + offset,
                                           normal: unit,
                                           residueParameter: parameters[s],
                                           structureConfidence: confidence,
                                           structure: structure))
            }
        }

        let ring = UInt32(profile.radialSegments)
        for s in 0..<(sampleCount - 1) {
            let base = UInt32(s) * ring
            for r in 0..<profile.radialSegments {
                let next = UInt32((r + 1) % profile.radialSegments)
                let a = base + UInt32(r)
                let b = base + next
                let c = a + ring
                let d = b + ring
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return TubeMesh(vertices: vertices, indices: indices)
    }

    // MARK: - Cross section

    /// Half-width and half-thickness of the cross section, blended by confidence.
    ///
    /// Coil is the resting shape, so every structure blends out of coil rather than out of
    /// nothing. That is what makes a helix grow rather than appear.
    static func section(for structure: SecondaryStructure, confidence: Float,
                        profile: Profile) -> (Float, Float) {
        let t = Swift.min(Swift.max(confidence, 0), 1)
        switch structure {
        case .coil:
            return (profile.coilRadius, profile.coilRadius)
        case .helix:
            let r = profile.coilRadius + (profile.helixRadius - profile.coilRadius) * t
            return (r, r)
        case .sheet:
            let w = profile.coilRadius + (profile.sheetHalfWidth - profile.coilRadius) * t
            let h = profile.coilRadius + (profile.sheetHalfThickness - profile.coilRadius) * t
            return (w, h)
        }
    }

    /// The assignment at a fractional residue position, with confidence eased between
    /// neighbours so the section changes smoothly rather than in steps at residue boundaries.
    static func interpolatedStructure(_ ss: [SSAssignment], at u: Float)
        -> (SecondaryStructure, Float) {
        guard !ss.isEmpty else { return (.coil, 0) }
        let clamped = Swift.min(Swift.max(u, 0), Float(ss.count - 1))
        let i = Swift.min(Int(clamped.rounded(.down)), Swift.max(ss.count - 2, 0))
        let t = clamped - Float(i)
        let a = ss[i]
        let b = ss[Swift.min(i + 1, ss.count - 1)]
        if a.structure == b.structure {
            return (a.structure, a.confidence + (b.confidence - a.confidence) * t)
        }
        // Across a boundary, fade the outgoing structure out rather than cutting to the
        // incoming one: the shape passes through coil, which is what a real ribbon does.
        return t < 0.5
            ? (a.structure, a.confidence * (1 - t * 2))
            : (b.structure, b.confidence * ((t - 0.5) * 2))
    }

    // MARK: - Curve and frames

    /// Catmull-Rom through the CA positions, so the tube passes through every alpha carbon.
    static func splinePoint(_ ca: [SIMD3<Float>], at u: Float) -> SIMD3<Float> {
        let n = ca.count
        guard n > 1 else { return ca.first ?? .zero }
        let clamped = Swift.min(Swift.max(u, 0), Float(n - 1))
        let i = Swift.min(Int(clamped.rounded(.down)), n - 2)
        let t = clamped - Float(i)
        let p0 = ca[Swift.max(i - 1, 0)]
        let p1 = ca[i]
        let p2 = ca[i + 1]
        let p3 = ca[Swift.min(i + 2, n - 1)]
        let t2 = t * t
        let t3 = t2 * t
        let a: SIMD3<Float> = p1 * 2
        let b: SIMD3<Float> = (p2 - p0) * t
        let c: SIMD3<Float> = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
        let d: SIMD3<Float> = (p1 * 3 - p2 * 3 + p3 - p0) * t3
        return (a + b + c + d) * 0.5
    }

    static func perpendicular(to v: SIMD3<Float>) -> SIMD3<Float> {
        // Pick the axis least aligned with v, so the cross product is well conditioned.
        let axis: SIMD3<Float> = abs(v.x) < abs(v.y)
            ? (abs(v.x) < abs(v.z) ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1))
            : (abs(v.y) < abs(v.z) ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        let perpendicular = simd_cross(v, axis)
        return simd_length(perpendicular) > 1e-6
            ? simd_normalize(perpendicular) : SIMD3<Float>(1, 0, 0)
    }

    static func minimalRotation(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let dot = simd_dot(a, b)
        if dot > 0.999999 { return simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
        if dot < -0.999999 { return simd_quatf(angle: .pi, axis: perpendicular(to: a)) }
        let axis = simd_normalize(simd_cross(a, b))
        return simd_quatf(angle: acos(Swift.min(Swift.max(dot, -1), 1)), axis: axis)
    }
}
