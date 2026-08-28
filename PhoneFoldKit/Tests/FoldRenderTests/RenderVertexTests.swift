import Testing
import Foundation
import simd
import FoldCore
@testable import FoldRender

@Suite("GPU vertex packing")
struct RenderVertexTests {

    static func mesh(residues: Int = 12,
                     structure: SecondaryStructure = .helix) -> TubeMesh {
        let ca = (0..<residues).map { k -> SIMD3<Float> in
            let t = Float(k) * 100 * .pi / 180
            return SIMD3<Float>(2.3 * cos(t), 2.3 * sin(t), Float(k) * 1.5)
        }
        let ss = [SSAssignment](repeating: SSAssignment(structure: structure, confidence: 0.8),
                                count: residues)
        return TubeGeometry.build(caPositions: ca, secondaryStructure: ss)
    }

    /// The vertex struct is written straight into a GPU buffer, so its layout is a contract.
    /// If a field is added or reordered without updating the attribute offsets, the shader
    /// reads the wrong bytes and the protein renders as noise rather than failing.
    ///
    /// **`SIMD3<Float>` occupies 16 bytes, not 12**: it is 16-byte aligned, so the fourth
    /// lane is padding. The vertex is therefore 48 bytes, not the 40 that counting floats
    /// suggests. The `.float3` attribute format still reads correctly because the mesh takes
    /// its offsets from `MemoryLayout.offset(of:)` rather than from arithmetic on field
    /// sizes; hard-coding 12 there would silently shear every normal.
    @Test("the vertex layout matches what the mesh descriptor assumes")
    func layout() {
        #expect(MemoryLayout<SIMD3<Float>>.size == 16, "SIMD3 is padded, not tightly packed")
        #expect(MemoryLayout<RenderVertex>.size == 64)
        #expect(MemoryLayout<RenderVertex>.stride == 64)
        #expect(MemoryLayout<RenderVertex>.offset(of: \.position) == 0)
        #expect(MemoryLayout<RenderVertex>.offset(of: \.normal) == 16)
        // The four scalars must be contiguous: they are read as one float4 attribute.
        let base = MemoryLayout<RenderVertex>.offset(of: \.residueParameter)!
        #expect(base == 32)
        #expect(MemoryLayout<RenderVertex>.offset(of: \.structureConfidence) == base + 4)
        #expect(MemoryLayout<RenderVertex>.offset(of: \.structureCode) == base + 8)
        #expect(MemoryLayout<RenderVertex>.offset(of: \.residueConfidence) == base + 12)
        // And the float4 attributes must not read past the end of the struct.
        #expect(base + 16 <= MemoryLayout<RenderVertex>.stride)
        let colour = MemoryLayout<RenderVertex>.offset(of: \.colour)!
        #expect(colour == 48)
        #expect(colour + 16 <= MemoryLayout<RenderVertex>.stride)
    }

    @Test("packing preserves geometry and carries the attributes through")
    func packing() {
        let tube = Self.mesh()
        let confidence = (0..<12).map { Float($0) * 5 }
        let packed = TubeMeshPacker.pack(tube, residueConfidence: confidence)

        #expect(packed.count == tube.vertices.count)
        for (a, b) in zip(packed, tube.vertices) {
            #expect(a.position == b.position)
            #expect(a.normal == b.normal)
            #expect(a.residueParameter == b.residueParameter)
            #expect(a.structureConfidence == b.structureConfidence)
            #expect(a.structureCode == Float(b.structure.rawValue))
        }
        #expect(packed.allSatisfy { $0.residueConfidence.isFinite })
    }

    @Test("structure codes match the enum the shader will branch on")
    func structureCodes() {
        for (structure, code) in [(SecondaryStructure.coil, Float(0)),
                                  (.helix, 1), (.sheet, 2)] {
            let packed = TubeMeshPacker.pack(Self.mesh(structure: structure),
                                             residueConfidence: [Float](repeating: 50, count: 12))
            // Interior vertices carry the structure; the ends fade through coil.
            let middle = packed[packed.count / 2]
            #expect(middle.structureCode == code)
        }
    }

    @Test("per-residue confidence is sampled and interpolated, never extrapolated")
    func confidenceSampling() {
        let values: [Float] = [0, 100]
        #expect(TubeMeshPacker.sample(values, at: 0) == 0)
        #expect(TubeMeshPacker.sample(values, at: 1) == 100)
        #expect(TubeMeshPacker.sample(values, at: 0.5) == 50)
        // Out of range clamps rather than running past the ends.
        #expect(TubeMeshPacker.sample(values, at: -3) == 0)
        #expect(TubeMeshPacker.sample(values, at: 9) == 100)
        #expect(TubeMeshPacker.sample([], at: 0.5) == 0)
        #expect(TubeMeshPacker.sample([42], at: 0.5) == 42)
    }

    /// Degenerate bounds cull the protein out of the scene entirely, which looks like the
    /// renderer failing rather than a bad box.
    @Test("bounds enclose every vertex, and an empty mesh has none")
    func bounds() {
        let packed = TubeMeshPacker.pack(Self.mesh(),
                                         residueConfidence: [Float](repeating: 50, count: 12))
        let box = TubeMeshPacker.bounds(packed)
        let unwrapped = try! #require(box)
        for v in packed {
            #expect(v.position.x >= unwrapped.minimum.x && v.position.x <= unwrapped.maximum.x)
            #expect(v.position.y >= unwrapped.minimum.y && v.position.y <= unwrapped.maximum.y)
            #expect(v.position.z >= unwrapped.minimum.z && v.position.z <= unwrapped.maximum.z)
        }
        #expect(TubeMeshPacker.bounds([]) == nil)
    }

    /// The per-frame path must not allocate a new mesh: PLAN.md forbids rebuilding
    /// MeshResource per frame. This measures the cost of the work the renderer actually does
    /// every frame, which is geometry plus packing.
    @Test("a frame's geometry and packing fits the 60 fps budget")
    func perFrameCost() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/Shared/Resources/Trajectories/beta2ar_7tm.pftraj")
        let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
        let readout = bundle.readouts[bundle.readouts.count / 2]
        let ss = [SSAssignment](repeating: SSAssignment(structure: .helix, confidence: 0.7),
                                count: readout.caPositions.count)

        let iterations = 20
        let start = Date()
        var total = 0
        for _ in 0..<iterations {
            let tube = TubeGeometry.build(caPositions: readout.caPositions,
                                          secondaryStructure: ss)
            total += TubeMeshPacker.pack(tube, residueConfidence: readout.confidence).count
        }
        let perFrame = Date().timeIntervalSince(start) / Double(iterations) * 1000
        print(String(format: "314-residue tube: %.2f ms/frame, %d vertices",
                     perFrame, total / iterations))
        #expect(total > 0)

        if ProcessInfo.processInfo.environment["PHONEFOLD_SKIP_PERF_BUDGET"] == "1" { return }
        #if DEBUG
        #expect(perFrame < 2000)
        #else
        // The engine already uses ~1.65 ms of the 16.7 ms budget; geometry must leave room
        // for the actual draw.
        #expect(perFrame < 8.0, "tube build exceeded its share of the 60 fps budget")
        #endif
    }
}
