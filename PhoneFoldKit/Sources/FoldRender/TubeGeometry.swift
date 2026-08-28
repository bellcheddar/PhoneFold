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

    /// Cartoon proportions, in angstroms.
    ///
    /// These are the numbers that decide whether the render reads as a protein cartoon or as
    /// a length of hose. The first version made helix a *round* section, thicker than coil,
    /// which is what a tube renderer does and not what a cartoon does: helix and sheet are
    /// both **flat ribbons**, and coil is a thin round cord that stays out of their way. The
    /// proportions here are close to PyMOL's defaults, which is the visual language every
    /// structural biologist already reads.
    public struct Profile: Sendable {
        /// Radius of the thin round cord used for coil.
        public var coilRadius: Float = 0.22
        /// The helix ribbon: wide and flat, so a helix reads as a coiled band.
        public var helixHalfWidth: Float = 1.05
        public var helixHalfThickness: Float = 0.25
        /// The strand ribbon.
        public var sheetHalfWidth: Float = 1.10
        public var sheetHalfThickness: Float = 0.20
        /// Half-width at the base of a strand's arrowhead.
        public var arrowHalfWidth: Float = 1.95
        /// Half-width at its point. Not zero: a true point degenerates the ring into a line
        /// and every triangle around it collapses.
        public var arrowTipHalfWidth: Float = 0.07
        /// How many residues at the C-terminal end of a strand the arrowhead spans.
        public var arrowResidues: Float = 1.6
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

        // The ribbon's flat face has to be oriented by the *structure*, not by the curve.
        //
        // A parallel-transported frame is the right answer for a round tube and the wrong one
        // for a cartoon: it carries an arbitrary starting rotation along the chain, so a
        // flattened ribbon ends up twisting at angles that have nothing to do with the
        // protein. The first version of this renderer looked like a hose partly for that
        // reason, and partly because helix was a round section.
        //
        // The frame used here is the one CA-only cartoon renderers use. For each residue take
        // the chain direction and the bisector of the two bonds:
        //
        //     tangent  = ca[i+1] - ca[i-1]
        //     bisector = (ca[i-1] - ca[i]) + (ca[i+1] - ca[i])
        //     side     = tangent x bisector
        //
        // `bisector` points to the concave side of the chain, which for a helix is straight
        // at its axis, so `side` comes out along the axis and the ribbon's broad face turns
        // outward - a coiled band, seen face-on from outside, which is what a helix should
        // look like. Along a strand the bisector alternates with the pleat, so `side` flips
        // by 180 degrees every residue and has to be made continuous, below; once it is, the
        // strand is a flat ribbon with a gentle twist, which is what a strand should look
        // like.
        var sideByResidue: [SIMD3<Float>] = []
        sideByResidue.reserveCapacity(ca.count)
        for i in 0..<ca.count {
            let previous = ca[Swift.max(i - 1, 0)]
            let current = ca[i]
            let following = ca[Swift.min(i + 1, ca.count - 1)]
            let along = following - previous
            let bisector = (previous - current) + (following - current)
            var side = simd_cross(along, bisector)
            if simd_length(side) < 1e-5 {
                // Three collinear alpha carbons leave the ribbon's roll undetermined. Carry
                // the previous residue's frame rather than inventing one, which would show as
                // a kink in the middle of a straight run.
                side = sideByResidue.last
                    ?? perpendicular(to: simd_length(along) > 1e-6
                                     ? simd_normalize(along) : SIMD3<Float>(0, 0, 1))
            }
            side = simd_normalize(side)
            // Continuity. Without this a strand's ribbon flips edge-over-edge at every
            // residue, which reads as a shredded ribbon rather than a twisted one.
            if let previousSide = sideByResidue.last, simd_dot(side, previousSide) < 0 {
                side = -side
            }
            sideByResidue.append(side)
        }

        // Per-sample frame, interpolated between residues and squared up against the tangent.
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(sampleCount)
        for s in 0..<sampleCount {
            let u = parameters[s]
            let i = Swift.min(Int(u), ca.count - 1)
            let j = Swift.min(i + 1, ca.count - 1)
            let f = u - Float(i)
            var side = sideByResidue[i] * (1 - f) + sideByResidue[j] * f
            side -= tangents[s] * simd_dot(side, tangents[s])
            normals.append(simd_length(side) > 1e-6 ? simd_normalize(side)
                                                    : perpendicular(to: tangents[s]))
        }

        // Arrowheads, widening then tapering over the last residues of each strand.
        let arrowWidths = arrowHalfWidths(ss, parameters: parameters, profile: profile)

        var vertices: [TubeVertex] = []
        vertices.reserveCapacity(sampleCount * profile.radialSegments)
        var indices: [UInt32] = []
        indices.reserveCapacity((sampleCount - 1) * profile.radialSegments * 6)

        for s in 0..<sampleCount {
            let tangent = tangents[s]
            let normal = normals[s]
            let binormal = simd_normalize(simd_cross(tangent, normal))
            let (structure, confidence) = interpolatedStructure(ss, at: parameters[s])
            var (halfWidth, halfThickness) = section(for: structure, confidence: confidence,
                                                     profile: profile)
            if let arrow = arrowWidths[s] {
                // Blended in by confidence like every other part of the section, so an
                // arrowhead grows with the strand instead of appearing fully formed.
                let t = Swift.min(Swift.max(confidence, 0), 1)
                halfWidth = profile.coilRadius + (arrow - profile.coilRadius) * t
            }

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
    /// The half-width of each sample that falls inside a strand's arrowhead, or nil.
    ///
    /// PLAN.md asks for arrowheads that "extrude progressively toward each strand's
    /// C-terminal end", which is also what makes a sheet readable: an arrow says which way
    /// the strand runs, and a plain ribbon does not. The head spans the last
    /// `profile.arrowResidues` of each run of strand: it steps out to `arrowHalfWidth` at the
    /// base and tapers to `arrowTipHalfWidth` at the point.
    ///
    /// The tip is deliberately not zero. A ring of radius zero collapses every triangle
    /// around it into a degenerate sliver, and those are exactly the triangles that show up
    /// later as stray spikes.
    static func arrowHalfWidths(_ ss: [SSAssignment], parameters: [Float],
                                profile: Profile) -> [Float?] {
        // Where each run of strand ends, by residue index.
        var strandEnds: [Int] = []
        for i in ss.indices where ss[i].structure == .sheet {
            if i + 1 == ss.count || ss[i + 1].structure != .sheet { strandEnds.append(i) }
        }
        guard !strandEnds.isEmpty, profile.arrowResidues > 0 else {
            return [Float?](repeating: nil, count: parameters.count)
        }
        return parameters.map { u -> Float? in
            for end in strandEnds {
                let distance = Float(end) - u
                guard distance >= 0, distance <= profile.arrowResidues else { continue }
                // 1 at the base of the head, 0 at the point.
                let along = distance / profile.arrowResidues
                return profile.arrowTipHalfWidth
                    + (profile.arrowHalfWidth - profile.arrowTipHalfWidth) * along
            }
            return nil
        }
    }

    static func section(for structure: SecondaryStructure, confidence: Float,
                        profile: Profile) -> (Float, Float) {
        let t = Swift.min(Swift.max(confidence, 0), 1)
        func grow(_ target: Float) -> Float {
            profile.coilRadius + (target - profile.coilRadius) * t
        }
        switch structure {
        case .coil:
            return (profile.coilRadius, profile.coilRadius)
        case .helix:
            return (grow(profile.helixHalfWidth), grow(profile.helixHalfThickness))
        case .sheet:
            return (grow(profile.sheetHalfWidth), grow(profile.sheetHalfThickness))
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
