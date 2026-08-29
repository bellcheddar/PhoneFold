import Testing
import Foundation
import simd
import FoldCore
@testable import FoldRender

/// The two junction defects Marc photographed: the coil cord bursting through the tip of a
/// strand's arrowhead, and the washed-out colour band across every ribbon end.
@Suite("Structure junctions")
struct JunctionTests {

    static func helix(_ n: Int) -> [SIMD3<Float>] {
        (0..<n).map { k in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
    }

    /// coil - strand - coil, the shape every mid-chain arrowhead sits in.
    static func strandChain(_ n: Int = 14, strand: ClosedRange<Int> = 4...9) -> [SSAssignment] {
        (0..<n).map {
            SSAssignment(structure: strand.contains($0) ? .sheet : .coil, confidence: 1)
        }
    }

    /// The thinnest half-extent of each ring, in ring order (junction duplicates included).
    static func ringMinExtents(_ mesh: TubeMesh, residues: Int,
                               profile: TubeGeometry.Profile) -> [Float] {
        let ring = profile.radialSegments
        let rings = TubeGeometry.ringLayout(residues: residues, profile: profile).count
        return (0..<rings).map { s in
            var centroid = SIMD3<Float>.zero
            for r in 0..<ring { centroid += mesh.vertices[s * ring + r].position }
            centroid /= Float(ring)
            var minimum = Float.greatestFiniteMagnitude
            for r in 0..<ring {
                minimum = Swift.min(minimum,
                                    simd_distance(mesh.vertices[s * ring + r].position,
                                                  centroid))
            }
            return minimum
        }
    }

    /// The arrowhead's taper must end **on** the coil cord, not inside it.
    ///
    /// The arrow's width multiplier used to be applied to the already-confidence-blended
    /// width. At the tip the boundary fade has taken that width down to the coil radius
    /// already, so multiplying by the tip fraction collapsed the ring to a 0.023 sliver -
    /// and the 0.20 cord drawn at the very next sample burst out of it, a rearward-facing
    /// step that showed end-on as a round grey disc in the middle of the arrowhead.
    /// Measured on protein G's first strand: halfWidth 0.0229 at the tip sample, 0.2000 one
    /// sample later, an 8.7-fold step. Scaling the un-blended target instead makes the tip
    /// ring the cord's own circle.
    @Test("the coil cord never bursts through an arrowhead tip")
    func arrowTipMeetsTheCord() {
        let profile = TubeGeometry.Profile()
        let ca = Self.helix(14)
        let ss = Self.strandChain()
        let mesh = TubeGeometry.build(caPositions: ca, secondaryStructure: ss)
        let extents = Self.ringMinExtents(mesh, residues: ca.count, profile: profile)

        var worst: Float = 1
        for s in 1..<extents.count {
            let a = extents[s - 1], b = extents[s]
            guard a > 1e-6, b > 1e-6 else { continue }
            worst = Swift.max(worst, Swift.max(a / b, b / a))
        }
        // The barb at the arrow's base is a step in *width*; the thin extent stays the
        // ribbon's thickness throughout, so nothing legitimate comes near this bound. The
        // collapsed tip was an 8.7-fold step.
        #expect(worst < 1.5,
                "adjacent rings jump \(worst)-fold in their thinnest extent - a section is collapsing")
    }

    /// No visible triangle spans two structures.
    ///
    /// Colour rides in a ramp texture with one row per structure, addressed by uv0. A quad
    /// whose two rings straddle a boundary interpolates that coordinate **across rows**, and
    /// the sampler blends the rows on the way: every helix end wore a pale washed-out band,
    /// and a sheet-to-coil junction passes through the helix row and flashed magenta
    /// (measured on screen: junction pixels at G/R 0.28 against 0.19 on the pure face).
    /// The junction rings are duplicated so the paint changes across a zero-area pair
    /// instead: any triangle whose vertices disagree about structure must never rasterise.
    @Test("triangles that mix structures have zero area")
    func mixedTrianglesAreDegenerate() {
        let n = 24
        // helix, sheet and coil junctions in one chain, mid-confidence like a folding frame.
        let ss = (0..<n).map { i -> SSAssignment in
            let structure: SecondaryStructure = i < 8 ? .helix : (i < 12 ? .coil : .sheet)
            return SSAssignment(structure: structure, confidence: 0.8)
        }
        let mesh = TubeGeometry.build(caPositions: Self.helix(n), secondaryStructure: ss)

        var mixed = 0
        var mixedVisible = 0
        var triangle = 0
        while triangle * 3 + 2 < mesh.indices.count {
            let a = mesh.vertices[Int(mesh.indices[triangle * 3])]
            let b = mesh.vertices[Int(mesh.indices[triangle * 3 + 1])]
            let c = mesh.vertices[Int(mesh.indices[triangle * 3 + 2])]
            if !(a.structure == b.structure && b.structure == c.structure) {
                mixed += 1
                let area = simd_length(simd_cross(b.position - a.position,
                                                  c.position - a.position)) / 2
                if area > 1e-6 { mixedVisible += 1 }
            }
            triangle += 1
        }
        #expect(mixed > 0, "no junction triangles at all - the layout is not being exercised")
        #expect(mixedVisible == 0,
                "\(mixedVisible) visible triangles mix structures - they will blend ramp rows on screen")
    }

    /// The junction rings must not change the mesh's size from frame to frame: the renderer
    /// allocates its vertex buffer once per trajectory.
    @Test("the ring layout depends on the chain, never on the frame's assignments")
    func layoutIsFrameInvariant() {
        let profile = TubeGeometry.Profile()
        let ca = Self.helix(14)
        let allCoil = (0..<14).map { _ in SSAssignment(structure: .coil, confidence: 0.1) }
        let a = TubeGeometry.build(caPositions: ca, secondaryStructure: allCoil)
        let b = TubeGeometry.build(caPositions: ca, secondaryStructure: Self.strandChain())
        #expect(a.vertices.count == b.vertices.count)
        #expect(a.indices.count == b.indices.count)
        #expect(a.vertices.count
                == TubeGeometry.ringLayout(residues: 14, profile: profile).count
                    * profile.radialSegments + 2 * (profile.radialSegments + 1))
    }
}

/// A ribbon narrows into the cord over several residues, and the colour does not follow it.
@Suite("Boundary taper")
struct BoundaryTaperTests {

    static func chain(_ n: Int) -> [SIMD3<Float>] {
        (0..<n).map { i in
            let t = Float(i) * 0.6
            return SIMD3<Float>(cos(t) * 3, sin(t) * 3, Float(i) * 1.4)
        }
    }

    /// Ten helix residues then ten coil.
    static func assignment() -> [SSAssignment] {
        (0..<20).map { SSAssignment(structure: $0 < 10 ? .helix : .coil, confidence: 0.95) }
    }

    @Test("The ribbon tapers into the cord instead of collapsing across one residue")
    func taperIsGradual() {
        let ss = TubeGeometry.levelledConfidence(Self.assignment())
        var sharp = TubeGeometry.Profile(); sharp.boundaryFadeResidues = 0
        var eased = TubeGeometry.Profile(); eased.boundaryFadeResidues = 1.5

        func worstStep(_ profile: TubeGeometry.Profile) -> Float {
            let track = TubeGeometry.taperedConfidence(ss, profile: profile)
            var previous: Float = -1
            var worst: Float = 0
            for k in stride(from: Float(7), through: 12, by: 0.1) {
                let (structure, confidence) = TubeGeometry.interpolatedStructure(track, at: k)
                let (w, _) = TubeGeometry.section(for: structure, confidence: confidence,
                                                 profile: profile, widthScale: 1)
                if previous >= 0 { worst = Swift.max(worst, abs(w - previous)) }
                previous = w
            }
            return worst
        }
        let before = worstStep(sharp)
        let after = worstStep(eased)
        #expect(after < before * 0.6,
                "the shoulder is still abrupt: \(before) to \(after) per tenth of a residue")
    }

    /// The taper is for the *shape*. If it reaches the colour, every ribbon end washes out to
    /// coil slate again - which is exactly what happened when the per-ring `paint` shadowed
    /// the levelled array and indexed the tapered one instead.
    @Test("Tapering the shape does not change any vertex's colour attributes")
    func taperDoesNotTouchColour() {
        let ca = Self.chain(20)
        let ss = Self.assignment()
        var sharp = TubeGeometry.Profile(); sharp.boundaryFadeResidues = 0
        var eased = TubeGeometry.Profile(); eased.boundaryFadeResidues = 1.5

        let a = TubeGeometry.build(caPositions: ca, secondaryStructure: ss, profile: sharp)
        let b = TubeGeometry.build(caPositions: ca, secondaryStructure: ss, profile: eased)
        try? #require(a.vertices.count == b.vertices.count)
        var differing = 0
        for (x, y) in zip(a.vertices, b.vertices) {
            if x.structure != y.structure
                || abs(x.structureConfidence - y.structureConfidence) > 1e-6 { differing += 1 }
        }
        #expect(differing == 0,
                "\(differing) vertices changed colour attributes when only the shape should move")
        // And the shape really did move, or the test above proves nothing.
        var moved = 0
        for (x, y) in zip(a.vertices, b.vertices)
        where simd_distance(x.position, y.position) > 1e-4 { moved += 1 }
        #expect(moved > 0, "the taper did not change the geometry at all")
    }
}
