import Testing
import Foundation
import simd
import FoldCore
@testable import FoldRender

/// The swept tube must be a closed surface.
///
/// The sweep connects consecutive rings with quads, and until it emitted end caps the first
/// and last ring were left open: two rings of boundary edges, one per terminus. This renderer
/// culls nothing - `faceCulling` and reversed winding are both ignored (measured, see
/// METRICS.md P2-05) - so an open end shows the tube's *interior* wall: on screen, a helix
/// whose end faces the camera is a hollow scoop with a dark inside.
@Suite("Tube end caps")
struct TubeCapTests {

    /// Edges referenced by exactly one triangle. A closed (watertight) surface has none; an
    /// open tube has one ring of them per open end.
    ///
    /// Vertices are welded by position before counting, because the caps duplicate the
    /// terminal ring's vertices on purpose - a cap is flat, so its rim needs the outward
    /// tangent as its normal, not the ring's radial normal. Welding still catches a real
    /// hole: with no cap there is nothing at the terminus to share the ring's edges with.
    static func boundaryEdgeCount(_ mesh: TubeMesh) -> Int {
        var welded: [SIMD3<Int32>: UInt32] = [:]
        var remap: [UInt32] = []
        remap.reserveCapacity(mesh.vertices.count)
        for v in mesh.vertices {
            let key = SIMD3<Int32>(Int32((v.position.x * 1e4).rounded()),
                                   Int32((v.position.y * 1e4).rounded()),
                                   Int32((v.position.z * 1e4).rounded()))
            if let existing = welded[key] {
                remap.append(existing)
            } else {
                let fresh = UInt32(welded.count)
                welded[key] = fresh
                remap.append(fresh)
            }
        }
        var edges: [UInt64: Int] = [:]
        var triangle = 0
        while triangle * 3 + 2 < mesh.indices.count {
            let corners = [remap[Int(mesh.indices[triangle * 3])],
                           remap[Int(mesh.indices[triangle * 3 + 1])],
                           remap[Int(mesh.indices[triangle * 3 + 2])]]
            for k in 0..<3 {
                let a = corners[k], b = corners[(k + 1) % 3]
                guard a != b else { continue }   // welded-degenerate edge
                let key = a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a)
                edges[key, default: 0] += 1
            }
            triangle += 1
        }
        return edges.values.count { $0 == 1 }
    }

    static func helix(_ n: Int) -> [SIMD3<Float>] {
        (0..<n).map { k in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
    }

    static func assignments(_ n: Int, _ s: SecondaryStructure) -> [SSAssignment] {
        [SSAssignment](repeating: SSAssignment(structure: s, confidence: 1), count: n)
    }

    @Test("the swept tube is watertight: no boundary edges at the termini")
    func watertight() {
        for structure in [SecondaryStructure.helix, .sheet, .coil] {
            let ca = Self.helix(12)
            let mesh = TubeGeometry.build(caPositions: ca,
                                          secondaryStructure: Self.assignments(12, structure))
            #expect(mesh.isWellFormed)
            let open = Self.boundaryEdgeCount(mesh)
            #expect(open == 0,
                    "\(structure): \(open) boundary edges - the tube's ends are open")
        }
    }

    @Test("the caps face outward, along the chain direction at each end")
    func capsFaceOutward() {
        var profile = TubeGeometry.Profile()
        let ring = profile.radialSegments
        let ca = Self.helix(12)
        let mesh = TubeGeometry.build(caPositions: ca,
                                      secondaryStructure: Self.assignments(12, .helix),
                                      profile: profile)
        let samples = (ca.count - 1) * profile.samplesPerResidue + 1
        // The sweep's vertices come first; the caps are appended after them.
        let sweepCount = samples * ring
        #expect(mesh.vertices.count > sweepCount, "no cap vertices were appended")

        func centroid(ringAt s: Int) -> SIMD3<Float> {
            var sum = SIMD3<Float>.zero
            for r in 0..<ring { sum += mesh.vertices[s * ring + r].position }
            return sum / Float(ring)
        }
        // The chain direction at each terminus, from the sweep itself.
        let startOut = simd_normalize(centroid(ringAt: 0) - centroid(ringAt: 1))
        let endOut = simd_normalize(centroid(ringAt: samples - 1)
                                    - centroid(ringAt: samples - 2))

        // Cap vertex normals: flat, along the outward tangent.
        let capVertices = mesh.vertices[sweepCount...]
        let startCap = capVertices.prefix(ring + 1)
        let endCap = capVertices.suffix(ring + 1)
        for v in startCap {
            #expect(simd_dot(v.normal, startOut) > 0.99,
                    "start cap normal \(v.normal) is not the outward tangent \(startOut)")
        }
        for v in endCap {
            #expect(simd_dot(v.normal, endOut) > 0.99,
                    "end cap normal \(v.normal) is not the outward tangent \(endOut)")
        }
        // And the caps sit on their rings: every cap vertex within the section's extent of
        // the terminal ring centroid.
        let extent = profile.arrowHalfWidth + 1
        for v in startCap {
            #expect(simd_distance(v.position, centroid(ringAt: 0)) < extent)
        }
        for v in endCap {
            #expect(simd_distance(v.position, centroid(ringAt: samples - 1)) < extent)
        }
    }

    /// Degenerate chains must not make the caps produce non-finite geometry.
    @Test("caps stay well-formed on degenerate chains")
    func degenerateChains() {
        let collinear = (0..<8).map { SIMD3<Float>(Float($0) * 3.8, 0, 0) }
        var duplicated = Self.helix(8)
        duplicated[1] = duplicated[0]
        duplicated[7] = duplicated[6]
        for ca in [collinear, duplicated] {
            let mesh = TubeGeometry.build(caPositions: ca,
                                          secondaryStructure: Self.assignments(8, .coil))
            #expect(mesh.isWellFormed)
            #expect(Self.boundaryEdgeCount(mesh) == 0)
        }
    }
}
