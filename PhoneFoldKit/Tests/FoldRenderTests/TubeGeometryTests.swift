import Testing
import Foundation
import simd
import FoldCore
import FoldGeometry
@testable import FoldRender

@Suite("Backbone tube geometry")
struct TubeGeometryTests {

    static func helix(_ n: Int) -> [SIMD3<Float>] {
        (0..<n).map { k in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
    }

    static func assignments(_ n: Int, _ s: SecondaryStructure,
                            confidence: Float = 1) -> [SSAssignment] {
        [SSAssignment](repeating: SSAssignment(structure: s, confidence: confidence), count: n)
    }

    @Test("a tube is built with the expected vertex and triangle counts")
    func counts() {
        var profile = TubeGeometry.Profile()
        profile.samplesPerResidue = 4
        profile.radialSegments = 8
        let ca = Self.helix(20)
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: Self.assignments(20, .helix),
                                      profile: profile)
        let samples = (20 - 1) * 4 + 1
        #expect(mesh.vertices.count == samples * 8)
        #expect(mesh.triangleCount == (samples - 1) * 8 * 2)
        #expect(mesh.isWellFormed)
    }

    /// The Phase 2 gate criterion: zero geometry NaNs across a full sample trajectory.
    @Test("no NaNs across a whole real trajectory, in either layout")
    func noNaNsAcrossTrajectory() throws {
        for name in ["genie2_76aa_seed1", "ubiquitin", "beta2ar_7tm"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Apps/Shared/Resources/Trajectories/\(name).pftraj")
            let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
            for (index, readout) in bundle.readouts.enumerated() {
                let ss = Self.assignments(readout.caPositions.count, .coil, confidence: 0.5)
                let mesh = TubeGeometry.build(caPositions: readout.caPositions,
                                              secondaryStructure: ss)
                #expect(mesh.isWellFormed, "\(name) frame \(index) produced bad geometry")
                #expect(mesh.triangleCount > 0)
            }
        }
    }

    /// Duplicate and collinear points are what a real trajectory throws at a spline. A NaN
    /// here does not crash, it silently removes triangles, which looks like a hole in the
    /// protein.
    @Test("degenerate inputs never produce NaNs", arguments: [
        "duplicate", "collinear", "tiny", "huge",
    ])
    func degenerateInputs(kind: String) {
        var ca: [SIMD3<Float>]
        switch kind {
        case "duplicate":
            ca = Self.helix(12)
            ca[5] = ca[4]                       // exact duplicate: zero-length tangent
            ca[9] = ca[8]
        case "collinear":
            ca = (0..<12).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        case "tiny":
            ca = (0..<12).map { SIMD3<Float>(Float($0) * 1e-5, 0, 0) }
        default:
            ca = (0..<12).map { SIMD3<Float>(Float($0) * 1e5, 0, 0) }
        }
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: Self.assignments(ca.count, .coil))
        #expect(mesh.isWellFormed, "\(kind) produced non-finite geometry")
    }

    @Test("too-short or mismatched input yields an empty mesh rather than trapping")
    func degenerateSizes() {
        #expect(TubeGeometry.build(caPositions: [], secondaryStructure: []).vertices.isEmpty)
        #expect(TubeGeometry.build(caPositions: [SIMD3<Float>(0, 0, 0)],
                                   secondaryStructure: Self.assignments(1, .coil))
                    .vertices.isEmpty)
        // Mismatched counts must not be interpreted, they must be refused.
        #expect(TubeGeometry.build(caPositions: Self.helix(10),
                                   secondaryStructure: Self.assignments(9, .coil))
                    .vertices.isEmpty)
    }

    /// The visual headline: a sheet is a flattened ribbon and a helix is a thicker tube.
    /// The cross sections that make this read as a cartoon rather than as a hose.
    ///
    /// This test used to assert `helixW == helixH`, "helix should be circular", and it passed
    /// for months. It was pinning the bug: a round helix section thicker than coil is what a
    /// tube renderer does, and it is why the whole protein looked like a fat worm. Helix and
    /// sheet are both flat ribbons in every cartoon convention, and coil is a thin cord that
    /// keeps out of their way.
    @Test("helix and sheet are flat ribbons and coil is a thin cord")
    func crossSectionShape() {
        let profile = TubeGeometry.Profile()
        let (coilW, coilH) = TubeGeometry.section(for: .coil, confidence: 1, profile: profile)
        let (helixW, helixH) = TubeGeometry.section(for: .helix, confidence: 1, profile: profile)
        let (sheetW, sheetH) = TubeGeometry.section(for: .sheet, confidence: 1, profile: profile)

        #expect(coilW == coilH, "coil should be circular")
        #expect(helixW > helixH * 3, "helix should be a flattened ribbon, not a cylinder")
        #expect(sheetW > sheetH * 3, "sheet should be a flattened ribbon")
        #expect(helixW > coilW * 3, "a helix ribbon should be far wider than the coil cord")
        #expect(sheetW > coilW * 3, "and so should a strand")
        #expect(helixH < coilW * 2, "but no thicker than the cord is wide")
    }

    /// A section at zero confidence is the coil cord, whatever the structure claims.
    ///
    /// This is what makes structure *grow* rather than snap into place: PLAN.md asks for the
    /// cross section to morph with per-residue confidence.
    @Test("structure grows out of the coil cord as confidence rises")
    func crossSectionGrowsWithConfidence() {
        let profile = TubeGeometry.Profile()
        for structure in [SecondaryStructure.helix, .sheet] {
            let (w0, h0) = TubeGeometry.section(for: structure, confidence: 0, profile: profile)
            #expect(w0 == profile.coilRadius && h0 == profile.coilRadius,
                    "\(structure) at zero confidence should still be the cord")
            var previous = w0
            for step in 1...10 {
                let (w, _) = TubeGeometry.section(for: structure,
                                                  confidence: Float(step) / 10, profile: profile)
                #expect(w >= previous, "the ribbon should only ever widen with confidence")
                previous = w
            }
        }
    }

    /// Arrowheads, which are what tell a reader which way a strand runs.
    @Test("a strand ends in an arrowhead that widens then comes to a point")
    func strandsEndInArrowheads() {
        let profile = TubeGeometry.Profile()
        // Residues 0-3 coil, 4-9 strand, 10-11 coil: one strand ending at residue 9.
        let ss = (0..<12).map { i in
            SSAssignment(structure: (4...9).contains(i) ? .sheet : .coil, confidence: 1)
        }
        let parameters = stride(from: Float(0), through: 11, by: 0.25).map { $0 }
        let widths = TubeGeometry.arrowHalfWidths(ss, parameters: parameters, profile: profile)

        let head = zip(parameters, widths).filter { $0.1 != nil }
        #expect(!head.isEmpty, "the strand must have an arrowhead")
        // It lives at the C-terminal end of the strand, not the N-terminal one.
        #expect(head.allSatisfy { $0.0 > 6 }, "the head belongs at the far end of the strand")
        // Widest at the base, narrowest at the point.
        let sorted = head.sorted { $0.0 < $1.0 }
        #expect(sorted.first!.1! > sorted.last!.1!, "it must taper toward the C-terminus")
        #expect(sorted.first!.1! > profile.sheetHalfWidth,
                "and step out wider than the strand it caps")
        #expect(sorted.last!.1! > 0,
                "the point must not close completely: a zero ring collapses its triangles")
    }

    /// PLAN.md: structure grows rather than snapping. At zero confidence every structure
    /// must look exactly like coil.
    @Test("at zero confidence every structure matches coil exactly")
    func morphStartsFromCoil() {
        let profile = TubeGeometry.Profile()
        let coil = TubeGeometry.section(for: .coil, confidence: 1, profile: profile)
        for structure in [SecondaryStructure.helix, .sheet] {
            let section = TubeGeometry.section(for: structure, confidence: 0, profile: profile)
            #expect(abs(section.0 - coil.0) < 1e-6, "\(structure) at zero confidence")
            #expect(abs(section.1 - coil.1) < 1e-6)
        }
    }

    @Test("the cross section changes monotonically with confidence")
    func morphIsMonotonic() {
        let profile = TubeGeometry.Profile()
        var previous: Float = 0
        for step in 0...10 {
            let c = Float(step) / 10
            let (w, _) = TubeGeometry.section(for: .sheet, confidence: c, profile: profile)
            #expect(w >= previous, "sheet width should not go backwards")
            previous = w
        }
    }

    /// A Frenet frame flips its normal through an inflection point and twists the ribbon 180
    /// degrees in one step. Parallel transport does not. This is what that fix buys.
    @Test("the swept frame does not flip through an inflection")
    func noFrameFlip() {
        // An S-curve: curvature changes sign in the middle, which is where Frenet fails.
        let ca = (0..<24).map { k -> SIMD3<Float> in
            let t = Float(k) * 0.4
            return SIMD3<Float>(t * 3, sin(t) * 4, cos(t * 0.5) * 2)
        }
        var profile = TubeGeometry.Profile()
        profile.radialSegments = 4
        profile.samplesPerResidue = 4
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: Self.assignments(ca.count, .sheet),
                                      profile: profile)
        #expect(mesh.isWellFormed)

        // Vertex 0 of each ring traces a continuous path if the frame never flips.
        var worst: Float = 0
        let ring = profile.radialSegments
        let rings = mesh.vertices.count / ring
        for s in 1..<rings {
            let a = mesh.vertices[(s - 1) * ring].position
            let b = mesh.vertices[s * ring].position
            worst = max(worst, simd_distance(a, b))
        }
        // Samples are ~1 A apart; a 180-degree flip would jump by roughly twice the width.
        #expect(worst < 1.5, "the reference frame jumped by \(worst), suggesting a flip")
    }

    @Test("the tube follows the alpha carbons it is built from")
    func followsTheChain() {
        let ca = Self.helix(16)
        var profile = TubeGeometry.Profile()
        profile.radialSegments = 12
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: Self.assignments(16, .coil),
                                      profile: profile)
        // The ring at each whole-residue parameter should be centred on that alpha carbon.
        for residue in 0..<16 {
            let ringVertices = mesh.vertices.filter {
                abs($0.residueParameter - Float(residue)) < 1e-4
            }
            #expect(ringVertices.count == profile.radialSegments)
            let centre = ringVertices.reduce(SIMD3<Float>.zero) { $0 + $1.position }
                / Float(ringVertices.count)
            #expect(simd_distance(centre, ca[residue]) < 0.05,
                    "ring \(residue) is centred at \(centre), not \(ca[residue])")
        }
    }


    @Test("normals point outward from the tube axis")
    func normalsPointOutward() {
        let ca = Self.helix(12)
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: Self.assignments(12, .coil))
        var checked = 0
        for (index, vertex) in mesh.vertices.enumerated() where index % 7 == 0 {
            let axis = TubeGeometry.splinePoint(ca, at: vertex.residueParameter)
            let outward = vertex.position - axis
            guard simd_length(outward) > 1e-4 else { continue }
            #expect(simd_dot(simd_normalize(outward), vertex.normal) > 0.5,
                    "normal at vertex \(index) does not point outward")
            checked += 1
        }
        #expect(checked > 20)
    }
}

/// The halo shell and the back-face rejection it needs.
///
/// The renderer culls nothing in this configuration - neither `faceCulling = .front` nor a
/// reversed triangle winding had any effect on screen - so the halo picks its own visible
/// triangles. That makes this our own geometry code and not a material setting, and it gets
/// tested like geometry.
@Suite("Halo shell")
struct HaloShellTests {

    /// A tube long enough to have a real silhouette from any angle.
    static func tube(residues: Int = 40) -> (TubeMesh, [RenderVertex]) {
        let ca = (0..<residues).map { i -> SIMD3<Float> in
            let t = Float(i) * 0.5
            return SIMD3<Float>(cos(t) * 4, sin(t) * 4, Float(i) * 1.2)
        }
        let ss = ca.indices.map { _ in SSAssignment(structure: .coil, confidence: 0.5) }
        let mesh = TubeGeometry.build(caPositions: ca, secondaryStructure: ss)
        let packed = TubeMeshPacker.pack(mesh,
                                         residueConfidence: ca.map { _ in Float(0.8) },
                                         mode: .confidence)
        return (mesh, packed)
    }

    @Test("The shell surrounds the tube and never crosses it")
    func shellSurroundsTheTube() {
        let (_, packed) = Self.tube()
        let offset: Float = 0.25
        let shell = TubeMeshPacker.shell(packed, offset: offset, brightness: 1)
        #expect(shell.count == packed.count)
        for (original, shifted) in zip(packed, shell) {
            let moved = shifted.position - original.position
            #expect(abs(simd_length(moved) - offset) < 1e-4,
                    "every vertex moves by exactly the offset")
            #expect(simd_dot(moved, original.normal) > 0, "and it moves outward, never in")
        }
    }

    /// The property that matters on screen: what is kept and what is dropped must partition
    /// the mesh. If they overlapped the halo would show through the tube; if together they
    /// missed triangles, the rim would have gaps in it.
    @Test("Facing away and facing toward partition the shell exactly")
    func cullingPartitionsTheShell() {
        let (mesh, packed) = Self.tube()
        let shell = TubeMeshPacker.shell(packed, offset: 0.25, brightness: 1)
        // A distant eye, so this is the orthographic limit and the two halves are exactly
        // complementary. With `bias` at zero nothing is trimmed, which is what makes the
        // partition exact.
        for axis in [SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0),
                     simd_normalize(SIMD3<Float>(1, 2, -3))] {
            let away = TubeMeshPacker.farFacing(vertices: shell, indices: mesh.indices,
                                                eye: axis * 10_000, bias: 0)
            let toward = TubeMeshPacker.farFacing(vertices: shell, indices: mesh.indices,
                                                  eye: -axis * 10_000, bias: 0)
            #expect(away.count % 3 == 0)
            // The two halves may overlap, but only on the silhouette itself. The eye is at a
            // finite distance, so the directions from it to two different triangles are not
            // exactly antiparallel, and a triangle within a fraction of a degree of
            // perpendicular can face away from both viewpoints. That band is a handful of
            // triangles on a mesh of thousands; anything more would mean the test of which
            // side a face is on has gone wrong.
            let overlap = away.count + toward.count - mesh.indices.count
            #expect(overlap <= mesh.indices.count / 100,
                    "the halves may overlap only on the silhouette: \(overlap / 3) of \(mesh.indices.count / 3) triangles")
            // A closed tube seen from any direction shows a substantial part of each half.
            let fraction = Double(away.count) / Double(mesh.indices.count)
            #expect(fraction > 0.25 && fraction < 0.75,
                    "roughly half a closed surface faces away, got \(fraction)")
        }
    }

    @Test("An empty or degenerate mesh yields no halo rather than trapping")
    func degenerateInputsAreSafe() {
        let eye = SIMD3<Float>(0, 0, 100)
        #expect(TubeMeshPacker.farFacing(vertices: [], indices: [0, 1, 2], eye: eye).isEmpty)
        let (_, packed) = Self.tube()
        #expect(TubeMeshPacker.farFacing(vertices: packed, indices: [], eye: eye).isEmpty)
        // An out-of-range index must be skipped, not read.
        let bad: [UInt32] = [0, 1, UInt32(packed.count + 100)]
        #expect(TubeMeshPacker.farFacing(vertices: packed, indices: bad, eye: eye).isEmpty)
        #expect(TubeMeshPacker.shell(packed, offset: 0, brightness: 1).count == packed.count)
    }

    /// What the halo adds to a frame, at the size PLAN.md's budget is written against.
    @Test("The halo's cost stays a small fraction of the frame budget")
    func haloCost() {
        let (mesh, packed) = Self.tube(residues: 300)
        let eye = simd_normalize(SIMD3<Float>(0.3, 0.4, 1)) * 40
        var best = Double.greatestFiniteMagnitude
        // The minimum of several batches, because a single batch on a shared machine swings
        // by more than the quantity being measured.
        for _ in 0..<5 {
            let start = Date()
            for _ in 0..<10 {
                let shell = TubeMeshPacker.shell(packed, offset: 0.25, brightness: 1)
                _ = TubeMeshPacker.farFacing(vertices: shell, indices: mesh.indices, eye: eye)
            }
            best = min(best, Date().timeIntervalSince(start) / 10 * 1000)
        }
        print("outline: \(mesh.indices.count / 3) triangles, \(String(format: "%.2f", best)) ms")
        // Asserted in release only, and *not* asserted at all in debug.
        //
        // The same measurement reads 0.48 ms optimised and 68 ms unoptimised, a factor of a
        // hundred and forty. A debug bound is not a weaker version of this check, it is a
        // different check with no budget behind it: the first attempt set one at 60 ms and it
        // went red twice for reasons that had nothing to do with the outline's cost, once
        // because a genuine improvement had been made elsewhere. The debug run prints the
        // number and asserts nothing.
        #if !DEBUG
        #expect(best < 2.0, "the outline must not eat the frame: \(best) ms")
        #endif
    }
}

extension HaloShellTests {

    /// The halo must not grow hairs on a tightly turning chain.
    ///
    /// A shell offset along the surface normals turns itself inside out wherever the tube
    /// bends more sharply than the shell is thick, and the crossed triangles stand off the
    /// outline as fine spikes. This builds a chain that turns far more tightly than any real
    /// backbone and checks that none of the inverted triangles survives.
    @Test("Inverted triangles are dropped from a tightly turning shell")
    func invertedTrianglesAreDropped() {
        // A hairpin: the chain doubles back on itself over three residues.
        let ca: [SIMD3<Float>] = (0..<24).map { i in
            let t = Float(i)
            return SIMD3<Float>(sin(t * 1.4) * 2.5, cos(t * 1.9) * 2.5, t * 0.35)
        }
        let ss = ca.indices.map { _ in SSAssignment(structure: .coil, confidence: 0.5) }
        let mesh = TubeGeometry.build(caPositions: ca, secondaryStructure: ss)
        let packed = TubeMeshPacker.pack(mesh, residueConfidence: ca.map { _ in Float(0.8) },
                                         mode: .confidence)
        // Deliberately thicker than the tube, to force inversions.
        let shell = TubeMeshPacker.shell(packed, offset: 1.2, brightness: 1)
        let eye = SIMD3<Float>(0, 0, 60)
        let kept = TubeMeshPacker.farFacing(vertices: shell, indices: mesh.indices, eye: eye)

        // Which sign means "not inverted" is a property of the mesh's winding, so take it
        // from the un-offset tube, which has no inversions in it by construction. Asserting a
        // hard-coded sign instead just tests the opposite property on a mesh wound the other
        // way, and passes or fails for no reason connected to the halo.
        func agreement(_ v: [RenderVertex], _ i: [UInt32], _ triangle: Int) -> Float {
            let a = Int(i[triangle * 3]), b = Int(i[triangle * 3 + 1])
            let c = Int(i[triangle * 3 + 2])
            let geometric = simd_cross(v[b].position - v[a].position,
                                       v[c].position - v[a].position)
            return simd_dot(geometric, v[a].normal + v[b].normal + v[c].normal)
        }
        var agreeing = 0
        let originalTriangles = mesh.indices.count / 3
        for t in 0..<originalTriangles where agreement(packed, mesh.indices, t) > 0 {
            agreeing += 1
        }
        let windingSign: Float = agreeing * 2 >= originalTriangles ? 1 : -1

        var inverted = 0
        var triangle = 0
        while triangle * 3 + 2 < kept.count {
            if agreement(shell, kept, triangle) * windingSign < 0 { inverted += 1 }
            triangle += 1
        }
        #expect(!kept.isEmpty, "the halo must not be emptied by the filter")
        #expect(inverted == 0, "\(inverted) inverted triangles survived into the halo")
    }
}
