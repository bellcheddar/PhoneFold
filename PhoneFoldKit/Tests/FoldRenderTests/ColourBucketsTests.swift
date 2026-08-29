import Testing
import Foundation
import simd
import FoldCore
@testable import FoldRender

@Suite("Colour buckets")
struct ColourBucketsTests {

    /// A fan of triangles over `count + 2` vertices. Written as a loop because the obvious
    /// flatMap expression defeats the Swift type checker.
    static func strip(count: Int) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(count * 3)
        for i in 0..<count {
            let base = UInt32(i)
            out.append(base)
            out.append(base + 1)
            out.append(base + 2)
        }
        return out
    }

    static func vertex(_ rgb: SIMD3<Float>) -> RenderVertex {
        RenderVertex(position: .zero, normal: SIMD3<Float>(0, 0, 1), residueParameter: 0,
                     structureConfidence: 1, structureCode: 0, residueConfidence: 50,
                     colour: SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1))
    }

    @Test("every triangle survives the split, exactly once")
    func nothingIsLost() {
        let vertices = (0..<30).map { Self.vertex(SIMD3<Float>(Float($0) / 29, 0.2, 0.8)) }
        let indices = Self.strip(count: 28)
        let result = ColourBuckets.split(vertices: vertices, indices: indices)

        #expect(result.indices.count == indices.count, "triangles were lost or duplicated")
        #expect(result.parts.reduce(0) { $0 + $1.count } == indices.count)
        #expect(Set(result.indices) == Set(indices))
    }

    @Test("parts are contiguous and cover the index buffer exactly")
    func partsTile() {
        let vertices = (0..<40).map { Self.vertex(SIMD3<Float>(Float($0 % 8) / 7, 0.5, 0.3)) }
        let indices = Self.strip(count: 38)
        let result = ColourBuckets.split(vertices: vertices, indices: indices)

        var cursor = 0
        for part in result.parts {
            #expect(part.offset == cursor, "parts must tile without gaps or overlap")
            #expect(part.count % 3 == 0, "a part must hold whole triangles")
            cursor += part.count
        }
        #expect(cursor == result.indices.count)
    }

    @Test("distinct colours land in distinct buckets and similar ones merge")
    func bucketing() {
        // Three clearly different colours.
        let distinct = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        var vertices: [RenderVertex] = []
        var indices: [UInt32] = []
        for (i, c) in distinct.enumerated() {
            vertices.append(contentsOf: (0..<3).map { _ in Self.vertex(c) })
            indices.append(contentsOf: [UInt32(i * 3), UInt32(i * 3 + 1), UInt32(i * 3 + 2)])
        }
        #expect(ColourBuckets.split(vertices: vertices, indices: indices).parts.count == 3)

        // Colours a hair apart should merge rather than making a part each.
        var near: [RenderVertex] = []
        var nearIndices: [UInt32] = []
        for i in 0..<3 {
            let c = SIMD3<Float>(0.5 + Float(i) * 0.001, 0.5, 0.5)
            near.append(contentsOf: (0..<3).map { _ in Self.vertex(c) })
            nearIndices.append(contentsOf: [UInt32(i * 3), UInt32(i * 3 + 1), UInt32(i * 3 + 2)])
        }
        #expect(ColourBuckets.split(vertices: near, indices: nearIndices).parts.count == 1)
    }

    @Test("a part's colour is representative of the triangles in it")
    func partColour() {
        let red = SIMD3<Float>(1, 0, 0)
        let vertices = (0..<3).map { _ in Self.vertex(red) }
        let result = ColourBuckets.split(vertices: vertices, indices: [0, 1, 2])
        #expect(result.parts.count == 1)
        #expect(simd_distance(result.parts[0].colour, red) < 1e-5)
    }

    /// The same protein must draw the same way every time.
    @Test("the split is deterministic")
    func deterministic() {
        let vertices = (0..<60).map { Self.vertex(SIMD3<Float>(Float($0 % 13) / 12, 0.4, 0.6)) }
        let indices = Self.strip(count: 58)
        let a = ColourBuckets.split(vertices: vertices, indices: indices)
        let b = ColourBuckets.split(vertices: vertices, indices: indices)
        #expect(a.indices == b.indices)
        #expect(a.parts.map(\.offset) == b.parts.map(\.offset))
    }

    @Test("degenerate input does not trap")
    func degenerate() {
        #expect(ColourBuckets.split(vertices: [], indices: []).parts.isEmpty)
        #expect(ColourBuckets.split(vertices: [Self.vertex(.one)], indices: []).parts.isEmpty)
        // An index pointing past the vertex array is skipped, not dereferenced.
        let r = ColourBuckets.split(vertices: [Self.vertex(.one)], indices: [99, 100, 101])
        #expect(r.parts.isEmpty)
    }

    /// A real trajectory frame should produce a modest number of parts: enough for a smooth
    /// ramp, few enough that the draw call count stays sane.
    @Test("a real frame produces a workable number of parts")
    func realFrame() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/ubiquitin.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let readout = bundle.readouts.last!
        let ss = [SSAssignment](repeating: SSAssignment(structure: .helix, confidence: 0.7),
                                count: readout.caPositions.count)
        let tube = TubeGeometry.build(caPositions: readout.caPositions, secondaryStructure: ss)
        let options = ColourOptions(residueCount: bundle.metadata.residueCount,
                                    residues: bundle.residues)
        let packed = TubeMeshPacker.pack(tube, residueConfidence: readout.confidence,
                                         mode: .confidence, options: options)
        let result = ColourBuckets.split(vertices: packed, indices: tube.indices)
        print("ubiquitin, confidence mode: \(result.parts.count) parts")
        #expect(result.parts.count >= 2, "a real protein should not be one flat colour")
        // Measured on this frame, against the quantisation step each choice gives:
        //
        //   levels 16 -> 36 parts, 6.67% per step      levels 40 -> 61 parts, 2.56%
        //   levels 24 -> 44 parts, 4.35%               levels 48 -> 65 parts, 2.13%
        //   levels 32 -> 51 parts, 3.23%               levels 64 -> 77 parts, 1.59%
        //
        // Parts grow far more slowly than the key space because a protein's colours lie along
        // a ramp rather than filling the cube. Sixteen levels banded visibly on a strand
        // ribbon; forty-eight is the shipped choice at 65 parts, and this bound is set to
        // catch a change of kind rather than to pin the exact number.
        #expect(result.parts.count <= 80, "too many draw calls: \(result.parts.count)")
        #expect(result.indices.count == tube.indices.count)
    }
}

#if canImport(RealityKit)
import RealityKit

/// Pins the unit of `LowLevelMesh.Part.indexOffset`.
///
/// It is a **byte** offset into the index buffer, and nothing in the type system says so: it
/// is an `Int` sitting next to `indexCount`, which is a count of indices. Passing a count
/// there drew each part at a quarter of its intended position, so the parts piled up over the
/// first quarter of the buffer and three quarters of the triangles never drew. A colour
/// bucket is a contiguous run of residues, so the result was a backbone rendered in
/// cleanly cross-sectioned pieces - from a mesh whose every index was present and correct,
/// which is why the diagnostics all read clean.
@MainActor
@Suite("LowLevelMesh part offsets")
struct LowLevelMeshPartOffsetTests {

    /// Build a plausible tube, bucket it, and check the parts tile the index buffer.
    @Test("Parts tile the whole index buffer, contiguously, in bytes")
    func partsTileTheIndexBufferInBytes() throws {
        let ca = (0..<24).map { i -> SIMD3<Float> in
            let t = Float(i) * 0.6
            return SIMD3<Float>(cos(t) * 5, sin(t) * 5, Float(i) * 1.5)
        }
        // Rainbow runs N to C, so the buckets are several and each one is a
        // contiguous run of residues - the shape that made the bug legible on screen.
        let confidence = ca.indices.map { Float($0) / Float(ca.count - 1) }
        let ss = confidence.map { SSAssignment(structure: .coil, confidence: $0) }
        let tube = TubeGeometry.build(caPositions: ca, secondaryStructure: ss)
        let vertices = TubeMeshPacker.pack(tube, residueConfidence: confidence,
                                           mode: .rainbow)
        let buckets = ColourBuckets.split(vertices: vertices, indices: tube.indices)
        #expect(buckets.parts.count > 1, "the ramp must produce several buckets")

        let mesh = try LowLevelTubeMesh(template: tube)
        try mesh.update(vertices: vertices, buckets: buckets)

        let stride = MemoryLayout<UInt32>.stride
        var expectedByteOffset = 0
        for part in mesh.mesh.parts {
            #expect(part.indexOffset == expectedByteOffset,
                    "part offsets must be byte offsets, tiling without gaps or overlap")
            expectedByteOffset += part.indexCount * stride
        }
        #expect(expectedByteOffset == tube.indices.count * stride,
                "the parts together must cover every triangle exactly once")
    }
}
#endif
