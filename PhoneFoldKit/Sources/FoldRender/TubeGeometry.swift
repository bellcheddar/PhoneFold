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
        public var coilRadius: Float = 0.20
        /// The helix ribbon: wide and flat, so a helix reads as a coiled band.
        public var helixHalfWidth: Float = 1.35
        public var helixHalfThickness: Float = 0.25
        /// The strand ribbon.
        public var sheetHalfWidth: Float = 1.40
        public var sheetHalfThickness: Float = 0.22
        /// Half-width at the base of a strand's arrowhead.
        public var arrowHalfWidth: Float = 1.95
        /// Half-width at its point. Not zero: a true point degenerates the ring into a line
        /// and every triangle around it collapses.
        public var arrowTipHalfWidth: Float = 0.16
        /// How many residues at the C-terminal end of a strand the arrowhead spans.
        public var arrowResidues: Float = 1.6
        /// How many times to average the ribbon's roll along the chain.
        ///
        /// Removes the per-residue alternation of a beta pleat, which otherwise corkscrews a
        /// strand that should lie flat. A steady roll, like a helix's, survives it.
        public var frameSmoothingPasses: Int = 3
        /// How square the ribbon's cross section is.
        ///
        /// The cross section is a superellipse, |x/w|^k + |y/h|^k = 1. At k = 2 that is an
        /// ellipse, which is what a tube renderer sweeps and what made the strands look like
        /// flattened sausages rather than the flat slabs a ribbon diagram draws. Raising k
        /// squares the section off: at 6 the faces are flat and the edges crisp, with just
        /// enough rounding left on the corners to catch a highlight. Coil keeps k = 2,
        /// because a cord is round.
        public var ribbonSharpness: Float = 6
        /// Spline samples per residue. Higher is smoother and costs vertices.
        public var samplesPerResidue: Int = 10
        /// How hard to pull the guide path toward the axis of a helix or strand.
        ///
        /// 0 draws the raw alpha-carbon path and 1 is fully smoothed. Applied `smoothingPasses`
        /// times and scaled by each residue's structure confidence, so structure still grows in
        /// rather than snapping.
        public var smoothing: Float = 1.0
        public var smoothingPasses: Int = 3
        /// Vertices around the cross section.
        public var radialSegments: Int = 20

        public init() {}

        /// The thinnest half-extent any cross section reaches.
        ///
        /// An outline drawn further out than this crosses through the surface it is meant to
        /// surround, and the crossing shows as a dark sliver at the pinch points - the tip of
        /// an arrowhead, the edge of a ribbon on a tight turn. Anything offsetting the surface
        /// should size itself from this rather than pick a number.
        public var thinnestHalfExtent: Float {
            Swift.min(coilRadius, Swift.min(helixHalfThickness,
                                            Swift.min(sheetHalfThickness, arrowTipHalfWidth)))
        }
    }

    /// Precomputed cross sections, one row per quantised sharpness.
    ///
    /// The superellipse needs `pow` four times per vertex, and at 314 residues that is a
    /// quarter of a million calls a frame - measured at 1.1 ms, more than half the entire
    /// geometry pass. But the sharpness is constant around a ring and varies only with
    /// confidence, so sixteen rows spanning ellipse to slab cover every section the renderer
    /// ever sweeps, to a precision far below what a screen shows.
    struct SectionTable {
        /// Unit offsets and unit-ish normal weights around one ring.
        let offsets: [SIMD2<Float>]
        let normals: [SIMD2<Float>]
    }

    static let sharpnessLevels = 16

    static func sectionTable(segments: Int, sharpness k: Float,
                             aspect: Float) -> SectionTable {
        // Angles chosen so the ring's vertices are evenly spaced *along the section*, not
        // evenly spaced in angle.
        //
        // Uniform angle is badly behaved on a flattened superellipse. Measured on the helix
        // ribbon - half-width 1.05, half-thickness 0.30, sharpness 6 - twenty uniform-angle
        // samples put **fourteen of them on the two thin edges**, leaving the broad faces
        // spanned by segments 9.8 times longer than the shortest. Shading interpolated across
        // spacing that uneven is what made the sides of the helices look coarse. Spacing by
        // arc length takes the ratio to 2.8 and puts six on the edges.
        //
        // `aspect` is the section's width-to-thickness ratio, which decides where the arc
        // length actually is; it travels with the sharpness, since a section flattens and
        // squares off together.
        let dense = 2048
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(dense)
        for i in 0..<dense {
            let angle = 2 * Float.pi * Float(i) / Float(dense)
            let cosine = cos(angle), sine = sin(angle)
            points.append(SIMD2<Float>(
                copysign(pow(abs(cosine), 2 / k), cosine) * aspect,
                copysign(pow(abs(sine), 2 / k), sine)))
        }
        var cumulative = [Float](repeating: 0, count: dense + 1)
        for i in 0..<dense {
            cumulative[i + 1] = cumulative[i]
                + simd_length(points[(i + 1) % dense] - points[i])
        }
        let total = cumulative[dense]

        var offsets: [SIMD2<Float>] = []
        var normals: [SIMD2<Float>] = []
        offsets.reserveCapacity(segments)
        normals.reserveCapacity(segments)
        for r in 0..<segments {
            let wanted = total * Float(r) / Float(segments)
            // First dense sample at or past the wanted arc length.
            var lo = 0, hi = dense
            while lo < hi {
                let mid = (lo + hi) / 2
                if cumulative[mid] < wanted { lo = mid + 1 } else { hi = mid }
            }
            let angle = 2 * Float.pi * Float(Swift.min(lo, dense - 1)) / Float(dense)
            let cosine = cos(angle), sine = sin(angle)
            offsets.append(SIMD2<Float>(copysign(pow(abs(cosine), 2 / k), cosine),
                                        copysign(pow(abs(sine), 2 / k), sine)))
            normals.append(SIMD2<Float>(copysign(pow(abs(cosine), 2 * (k - 1) / k), cosine),
                                        copysign(pow(abs(sine), 2 * (k - 1) / k), sine)))
        }
        return SectionTable(offsets: offsets, normals: normals)
    }

    /// One confidence per secondary-structure element, not per residue.
    ///
    /// The cross section grows with confidence so that structure appears rather than snaps,
    /// and confidence is assigned per residue, so a ribbon's width followed every wobble in
    /// the assigner's certainty. Measured on protein G's second strand, the half-width ran
    /// 0.72, 0.92, 1.05, 0.95, 0.83, 0.72 - a 1.46-fold swing along a single strand, which on
    /// screen is a ribbon pinching in and out like a squeezed tube. No cartoon draws that: an
    /// element has one width, and tapers only where it ends.
    ///
    /// Averaging over the run keeps the growth - the mean rises as the fold settles - and
    /// takes away the lumpiness. The taper at each end is unaffected, because that comes from
    /// `interpolatedStructure` fading across the boundary rather than from these values.
    static func levelledConfidence(_ ss: [SSAssignment]) -> [SSAssignment] {
        guard !ss.isEmpty else { return ss }
        var levelled = ss
        var start = 0
        while start < ss.count {
            var end = start
            while end + 1 < ss.count, ss[end + 1].structure == ss[start].structure { end += 1 }
            if ss[start].structure != .coil {
                var total: Float = 0
                for i in start...end { total += ss[i].confidence }
                let mean = total / Float(end - start + 1)
                for i in start...end {
                    levelled[i] = SSAssignment(structure: ss[i].structure, confidence: mean)
                }
            }
            start = end + 1
        }
        return levelled
    }

    /// Guide points for the spline: the alpha-carbon path, smoothed inside helices and
    /// strands.
    ///
    /// **Why a cartoon cannot spline the raw CA path.** An alpha helix has 3.6 residues per
    /// turn, so a turn of the backbone is barely three and a half control points. A spline
    /// through them is perfectly smooth and still traces a rounded triangle, which is what a
    /// helix genuinely looks like at the level of its alpha carbons and not what anyone means
    /// by a helix. Every cartoon renderer smooths first; drawing the raw path is why these
    /// helices came out squared off.
    ///
    /// A [1, 2, 1] pass pulls each guide point toward the mean of its neighbours, which for a
    /// helix is toward the axis and for a strand flattens the pleat.
    ///
    /// **Strands only.** It used to apply to helices too, to round off the 3.6-residue
    /// polygon they were drawn as, and that was treating a symptom: the polygon came from the
    /// spline cutting corners, which `splinePoint` now fixes properly with circular arcs.
    /// Smoothing a helix shrinks it - one full [1, 2, 1] pass multiplies the radius by
    /// (2 + 2 cos 100 degrees) / 4, which is 0.41. A helix should be drawn at the radius it
    /// has, so nothing here touches one.
    ///
    /// **A strand may curve; it may not zigzag.** Those are separable, and separating them is
    /// what set the strength. The alternating component - how far each alpha carbon sits off
    /// the midpoint of its neighbours - is the pleat, and a [1, 2, 1] pass attacks it
    /// directly while barely touching a smooth bend. Measured on protein G's sheet:
    ///
    ///     strength x passes   zigzag mean/worst   curvature kept
    ///     none                1.743 / 2.157 A     2.82 A
    ///     0.4 x 1             1.141 / 1.636 A     2.47 A     <- what shipped, and visibly wrong
    ///     1.0 x 3             0.169 / 0.498 A     1.75 A     <- here
    ///     1.0 x 6             0.132 / 0.333 A     1.45 A
    ///
    /// At the old setting the zigzag was 1.14 A, about the ribbon's own half-width, which is
    /// why the edges looked serrated. Three full passes take it down by a factor of nearly
    /// seven and keep the curve; going further buys little and starts straightening the sheet
    /// itself, which is real structure.
    ///
    /// Scaled by structure confidence, so a residue that is not yet confidently helical keeps
    /// its true position and the smoothing eases in with the ribbon.
    static func guidePoints(_ ca: [SIMD3<Float>], secondaryStructure ss: [SSAssignment],
                            profile: Profile) -> [SIMD3<Float>] {
        guard ca.count >= 3, profile.smoothing > 0, profile.smoothingPasses > 0 else { return ca }
        var guide = ca
        for _ in 0..<profile.smoothingPasses {
            var next = guide
            for i in 1..<(guide.count - 1) {
                guard ss[i].structure == .sheet else { continue }
                let averaged = (guide[i - 1] + guide[i] * 2 + guide[i + 1]) * 0.25
                let amount = profile.smoothing * Swift.min(Swift.max(ss[i].confidence, 0), 1)
                next[i] = guide[i] + (averaged - guide[i]) * amount
            }
            guide = next
        }
        return guide
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

        // One confidence per element, so a ribbon has one width. See `levelledConfidence`.
        let ss = levelledConfidence(ss)
        // Smoothed guide points, not the raw alpha carbons. See `guidePoints`.
        let ca = guidePoints(ca, secondaryStructure: ss, profile: profile)

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

        // Smooth the frame along the chain.
        //
        // Making the sign continuous stops a strand's ribbon flipping edge over edge, but it
        // does not stop it *twisting*: a beta strand pleats side to side, so the bisector -
        // and with it the ribbon's roll - alternates every residue. Measured on protein G's
        // sheet, consecutive residues were rolling by tens of degrees, and a strand drawn on
        // that frame corkscrews instead of lying flat.
        //
        // A symmetric [1, 2, 1] average removes the alternation and leaves a steady rotation
        // alone, which is exactly the distinction wanted here: the pleat is noise, while a
        // helix's roll is the helix, and averaging a vector that turns at a constant rate
        // returns the same direction with a slightly shorter length, which normalising undoes.
        for _ in 0..<profile.frameSmoothingPasses {
            var smoothed = sideByResidue
            for i in 1..<(sideByResidue.count - 1) {
                let sum = sideByResidue[i - 1] + sideByResidue[i] * 2 + sideByResidue[i + 1]
                if simd_length(sum) > 1e-6 { smoothed[i] = simd_normalize(sum) }
            }
            sideByResidue = smoothed
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
        let arrowScale = arrowScales(ss, parameters: parameters, profile: profile)

        // One cross-section table per quantised sharpness, built once for the whole frame.
        let levels = Swift.max(sharpnessLevels, 2)
        // A section flattens and squares off together, so the aspect ratio used to place the
        // vertices travels with the sharpness: round at level 0, the ribbon's own ratio at
        // the top.
        let ribbonAspect = profile.helixHalfWidth / Swift.max(profile.helixHalfThickness, 1e-4)
        let tables = (0..<levels).map { level -> SectionTable in
            let t = Float(level) / Float(levels - 1)
            return sectionTable(segments: profile.radialSegments,
                                sharpness: 2 + (profile.ribbonSharpness - 2) * t,
                                aspect: 1 + (ribbonAspect - 1) * t)
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
            // The shape morphs across a boundary; the colour does not. See `colouredStructure`.
            let (paintStructure, paintConfidence) = colouredStructure(ss, at: parameters[s])
            var (halfWidth, halfThickness) = section(for: structure, confidence: confidence,
                                                     profile: profile)
            // Scales the section rather than replacing it, so the arrow can only shape a
            // strand and never widen the coil either side of one.
            halfWidth *= arrowScale[s]

            // Superellipse |x/w|^k + |y/h|^k = 1, read from the precomputed table: k = 2 is
            // the ellipse this used to sweep, higher is a slab with crisp edges.
            let t = Swift.min(Swift.max(confidence, 0), 1)
            let level = structure == .coil ? 0
                : Int((t * Float(levels - 1)).rounded())
            let table = tables[Swift.min(Swift.max(level, 0), levels - 1)]
            for r in 0..<profile.radialSegments {
                let section = table.offsets[r]
                let offset = normal * (section.x * halfWidth)
                    + binormal * (section.y * halfThickness)
                // The surface normal is the gradient of that implicit form, not the radial
                // direction: n proportional to (sign(x)|x/w|^(k-1)/w, sign(y)|y/h|^(k-1)/h).
                // Getting this wrong lights a flat slab as though it were still round, which
                // is most of what made the old sections read as sausages.
                let weight = table.normals[r]
                let rawNormal = normal * (weight.x / Swift.max(halfWidth, 1e-4))
                    + binormal * (weight.y / Swift.max(halfThickness, 1e-4))
                let unit = simd_length(rawNormal) > 1e-6
                    ? simd_normalize(rawNormal) : normal
                vertices.append(TubeVertex(position: centres[s] + offset,
                                           normal: unit,
                                           residueParameter: parameters[s],
                                           structureConfidence: paintConfidence,
                                           structure: paintStructure))
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

        // End caps: a triangle fan across the first and last ring.
        //
        // Without them the tube is open at both termini - measured as exactly
        // 2 x radialSegments boundary edges on every build - and this renderer culls
        // nothing (`faceCulling` and reversed winding are both ignored; see METRICS.md
        // P2-05), so an open end shows the tube's *interior* wall. On screen that is a
        // helix ending in a hollow scoop with a dark inside.
        //
        // The ring vertices are duplicated rather than shared, because a cap is flat: its
        // normal is the outward tangent, not the ring's radial normal, and sharing
        // vertices would smear the cap's shading around the rim.
        //
        // Winding matches the sweep's own convention - geometric normal *opposing* the
        // vertex normals (measured: 0 of 4,400 sweep triangles agree) - so `farFacing`,
        // which calibrates its inversion test on the mesh's majority winding, treats the
        // caps exactly like the wall they close.
        for end in [0, sampleCount - 1] {
            let outward = end == 0 ? -tangents[0] : tangents[sampleCount - 1]
            let ringBase = end * profile.radialSegments
            let capBase = UInt32(vertices.count)
            let sample = vertices[ringBase]
            vertices.append(TubeVertex(position: centres[end], normal: outward,
                                       residueParameter: sample.residueParameter,
                                       structureConfidence: sample.structureConfidence,
                                       structure: sample.structure))
            for r in 0..<profile.radialSegments {
                var rim = vertices[ringBase + r]
                rim.normal = outward
                vertices.append(rim)
            }
            for r in 0..<profile.radialSegments {
                let next = UInt32((r + 1) % profile.radialSegments)
                let rim = capBase + 1 + UInt32(r)
                let rimNext = capBase + 1 + next
                indices.append(contentsOf: end == 0
                               ? [capBase, rim, rimNext]
                               : [capBase, rimNext, rim])
            }
        }
        return TubeMesh(vertices: vertices, indices: indices)
    }

    // MARK: - Cross section

    /// Half-width and half-thickness of the cross section, blended by confidence.
    ///
    /// Coil is the resting shape, so every structure blends out of coil rather than out of
    /// nothing. That is what makes a helix grow rather than appear.
    /// A multiplier on the strand's half-width, shaping the arrowhead. 1 everywhere else.
    ///
    /// PLAN.md asks for arrowheads that "extrude progressively toward each strand's
    /// C-terminal end", which is also what tells a reader which way a strand runs.
    ///
    /// **A multiplier, not an absolute width.** The first version returned a width and the
    /// caller used it in place of the section's own, which had two consequences on a real
    /// protein. Trp-cage's assignment is `-HHHHHHH--HHH----E--`: one single sheet residue. A
    /// head 1.6 residues long therefore reached back across two *coil* residues and widened
    /// them, because an absolute width overrides whatever the structure there actually is.
    /// And past the tip the width jumped straight back to the full strand width - 0.11 to
    /// 0.84 between two samples a quarter of a residue apart - which is the notch that showed
    /// up in the ribbon. As a multiplier both problems go: outside a strand it is 1, so the
    /// section decides, and there is nothing to jump back to.
    ///
    /// The head is also never longer than the strand it caps, so a one-residue strand gets a
    /// one-residue arrow rather than one that starts before the strand does.
    static func arrowScales(_ ss: [SSAssignment], parameters: [Float],
                            profile: Profile) -> [Float] {
        var scales = [Float](repeating: 1, count: parameters.count)
        guard profile.arrowResidues > 0, profile.sheetHalfWidth > 0 else { return scales }

        // Runs of strand, as (first, last) residue indices.
        var runs: [(start: Int, end: Int)] = []
        var start: Int?
        for i in ss.indices {
            if ss[i].structure == .sheet {
                if start == nil { start = i }
                if i + 1 == ss.count || ss[i + 1].structure != .sheet {
                    runs.append((start!, i))
                    start = nil
                }
            }
        }
        guard !runs.isEmpty else { return scales }

        for (index, u) in parameters.enumerated() {
            for run in runs {
                let head = Swift.min(profile.arrowResidues, Float(run.end - run.start) + 1)
                let base = Float(run.end) - head
                // The point sits at the end of the *strand's extent*, not at its last residue
                // index. `interpolatedStructure` fades a structure out over the half residue
                // past its last one, so stopping the taper at the index left the width
                // snapping back to the full strand for that half residue: measured as a jump
                // from 0.123 to 0.719 between two samples a tenth of a residue apart, which
                // is the notch that kept appearing in the ribbon.
                let tip = Float(run.end) + 0.5
                guard u >= base, u <= tip, head > 0 else { continue }
                let along = Swift.max((tip - u) / (head + 0.5), 0)
                let target = profile.arrowTipHalfWidth
                    + (profile.arrowHalfWidth - profile.arrowTipHalfWidth) * along
                scales[index] = target / profile.sheetHalfWidth
                break
            }
        }
        return scales
    }

    /// How square this sample's cross section should be, 2 being a true ellipse.
    ///
    /// Blended in with confidence like the widths, so a ribbon squares off as it forms
    /// instead of snapping from cord to slab.
    static func sharpness(for structure: SecondaryStructure, confidence: Float,
                          profile: Profile) -> Float {
        guard structure != .coil else { return 2 }
        let t = Swift.min(Swift.max(confidence, 0), 1)
        return 2 + (profile.ribbonSharpness - 2) * t
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
    /// The structure and confidence a sample should be **coloured** by.
    ///
    /// Deliberately not `interpolatedStructure`, which fades the outgoing structure's
    /// confidence to zero at a boundary so the cross section can pass through coil on its way
    /// from ribbon to cord. That morph is right for the *shape* - PLAN.md wants structure to
    /// grow rather than snap - and wrong for the colour, because it takes the ribbon's colour
    /// to coil slate as well. On a settled protein that puts a grey wedge across the last
    /// residue of every helix, which reads as the coil showing through the ribbon.
    ///
    /// Colour instead takes the nearer residue's own element, at its own confidence, so it
    /// changes at the boundary the way a cartoon's does while the shape still morphs.
    static func colouredStructure(_ ss: [SSAssignment], at u: Float)
        -> (SecondaryStructure, Float) {
        guard !ss.isEmpty else { return (.coil, 0) }
        let clamped = Swift.min(Swift.max(u, 0), Float(ss.count - 1))
        let nearest = Int(clamped.rounded())
        let residue = ss[Swift.min(Swift.max(nearest, 0), ss.count - 1)]
        return (residue.structure, residue.confidence)
    }

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
    /// A point on the circle through `a`, `b`, `c`, going from `b` to `c` as `t` runs 0 to 1.
    ///
    /// Falls back to a straight line when the three points are collinear, which is both the
    /// degenerate case and the correct answer for it.
    static func arcPoint(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                         t: Float) -> SIMD3<Float> {
        let u = b - a
        let v = c - a
        let normal = simd_cross(u, v)
        let normalLength = simd_length(normal)
        let line = b + (c - b) * t

        // How sharply the chain turns here, as the sine of the angle between the two spans.
        //
        // The old guard was on the *absolute* length of the cross product, and that is not a
        // test of anything: at 3.8 angstrom spacing a sine of a hundred-millionth still
        // clears 1e-7, and the circle it describes has a centre computed from the difference
        // of two nearly equal large numbers. The result is a huge, wildly unstable circle,
        // and the arc through it wanders. Strands are where this bit: they are close to
        // straight to begin with, and smoothing their pleat straightens them further, so the
        // ribbon came out with kinks in it.
        //
        // Below the floor the answer is a straight line, which for collinear points is not an
        // approximation but the correct answer. Between floor and ceiling the two are blended
        // so there is no seam where the treatment changes.
        let sine = normalLength / Swift.max(simd_length(u) * simd_length(v), 1e-12)
        let straightBelow: Float = 0.02
        let curvedAbove: Float = 0.10
        guard sine > straightBelow else { return line }
        let arcWeight = Swift.min((sine - straightBelow) / (curvedAbove - straightBelow), 1)

        let uu = simd_dot(u, u)
        let vv = simd_dot(v, v)
        let centre = a + (simd_cross(normal, u) * vv + simd_cross(v, normal) * uu)
            / (2 * normalLength * normalLength)
        let radius = simd_length(b - centre)
        guard radius > 1e-6, radius.isFinite else { return line }

        let e1 = (b - centre) / radius
        let nHat = normal / normalLength
        let e2 = simd_cross(nHat, e1)
        let toC = c - centre
        // The signed angle from b to c, taken the short way round: consecutive alpha carbons
        // never subtend more than half a turn.
        let sweep = atan2(simd_dot(toC, e2), simd_dot(toC, e1))
        let angle = sweep * t
        let arc = centre + (e1 * cos(angle) + e2 * sin(angle)) * radius
        guard arc.x.isFinite, arc.y.isFinite, arc.z.isFinite else { return line }
        return line + (arc - line) * arcWeight
    }

    /// The guide curve, interpolated so that a helix comes out round.
    ///
    /// **Why not Catmull-Rom.** An alpha helix advances 100 degrees per residue, so a turn is
    /// 3.6 alpha carbons. A Catmull-Rom spline through points that far apart on a circle cuts
    /// the corners badly: its midpoint between two of them sits at 0.831 of the radius, nearly
    /// 17 percent inside the true curve. That is not a subtle artefact - it is the whole
    /// reason the helices kept coming out as rounded triangles, and no amount of extra
    /// tessellation fixes it, because the curve itself is the wrong shape.
    ///
    /// Blending the two circular arcs through each overlapping triple reproduces a circle
    /// *exactly*, so a helix is drawn at its true radius. The blend, weighted (1-t) and t
    /// between the arc through the previous triple and the arc through the next, is the
    /// standard construction and is C1 continuous at the joins.
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
        let before = arcPoint(p0, p1, p2, t: t)
        let after = arcPoint(p3, p1, p2, t: t)
        return before * (1 - t) + after * t
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
