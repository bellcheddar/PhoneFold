import Foundation
import simd
import FoldCore

#if canImport(RealityKit)
import RealityKit

/// Owns a `LowLevelMesh` and rewrites its vertex buffer in place, once per frame.
///
/// PLAN.md Phase 2 is specific: do not rebuild `MeshResource` per frame. Allocating a new
/// mesh sixty times a second is the difference between a smooth fold and a stuttering one,
/// because each rebuild re-uploads and re-validates the whole buffer. `LowLevelMesh` exists
/// precisely so the buffer can be written without that round trip.
///
/// The mesh is allocated once at a **fixed capacity** for the whole trajectory: residue count
/// and the sweep profile do not change mid-fold, so the vertex count is constant and only the
/// contents change. Indices are written once, at setup, for the same reason.
/// `@MainActor` because `LowLevelMesh` is: RealityKit resources are main-actor isolated, and
/// pretending otherwise would only move the race somewhere harder to see. The expensive part,
/// building the tube geometry, is deliberately not on the main actor - only the buffer write
/// is.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@MainActor
public final class LowLevelTubeMesh {

    public private(set) var mesh: LowLevelMesh
    public let vertexCapacity: Int
    public let indexCapacity: Int
    /// Counts how many times the vertex buffer has been rewritten, for the frame-time budget
    /// test and the debug overlay.
    public private(set) var updateCount = 0

    public enum MeshError: Error, CustomStringConvertible {
        case emptyMesh
        case capacityExceeded(needed: Int, capacity: Int)

        public var description: String {
            switch self {
            case .emptyMesh:
                "Cannot build a renderer mesh from an empty tube."
            case .capacityExceeded(let needed, let capacity):
                "The tube needs \(needed) vertices but the mesh was allocated for \(capacity)."
            }
        }
    }

    /// Allocate for a tube of known size. `template` fixes the capacity and the index buffer.
    public init(template: TubeMesh) throws {
        guard !template.vertices.isEmpty, !template.indices.isEmpty else {
            throw MeshError.emptyMesh
        }
        vertexCapacity = template.vertices.count
        indexCapacity = template.indices.count

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCapacity
        descriptor.indexCapacity = indexCapacity
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0,
                  offset: MemoryLayout<RenderVertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, layoutIndex: 0,
                  offset: MemoryLayout<RenderVertex>.offset(of: \.normal)!),
            // The computed colour rides in the `.color` channel, which a custom surface
            // shader reads as `geometry.color()`. RealityKit's *stock* materials ignore a
            // vertex colour channel, which is why the tube renders flat grey without a
            // custom shader; the channel itself is delivered correctly.
            .init(semantic: .color, format: .float4, layoutIndex: 0,
                  offset: MemoryLayout<RenderVertex>.offset(of: \.colour)!),
            // uv0 is where the colour comes from: it indexes the ramp texture, which is what
            // makes the protein a gradient instead of a staircase of flat-tinted mesh parts.
            // See `ColourRamp`.
            .init(semantic: .uv0, format: .float2, layoutIndex: 0,
                  offset: MemoryLayout<RenderVertex>.offset(of: \.rampCoordinate)!),
            .init(semantic: .uv1, format: .float2, layoutIndex: 0,
                  offset: MemoryLayout<RenderVertex>.offset(of: \.structureCode)!),
        ]
        descriptor.vertexLayouts = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<RenderVertex>.stride)
        ]
        descriptor.indexType = .uint32
        mesh = try LowLevelMesh(descriptor: descriptor)

        // Indices never change: the topology is fixed for the whole trajectory.
        mesh.withUnsafeMutableIndices { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            for (i, index) in template.indices.enumerated() { buffer[i] = index }
        }
    }

    /// Rewrite the vertex buffer and the index buffer, splitting the mesh into one part per
    /// colour bucket so stock materials can draw per-residue colour. See `ColourBuckets`.
    public func update(vertices: [RenderVertex],
                       buckets: ColourBuckets.Result) throws {
        guard vertices.count <= vertexCapacity else {
            throw MeshError.capacityExceeded(needed: vertices.count, capacity: vertexCapacity)
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let buffer = raw.bindMemory(to: RenderVertex.self)
            for (i, vertex) in vertices.enumerated() { buffer[i] = vertex }
        }
        mesh.withUnsafeMutableIndices { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            for (i, index) in buckets.indices.enumerated() where i < indexCapacity {
                buffer[i] = index
            }
        }
        let box = TubeMeshPacker.bounds(vertices)
        let bounds = box.map { BoundingBox(min: $0.minimum, max: $0.maximum) }
            ?? BoundingBox(min: .zero, max: .zero)
        // `indexOffset` is a **byte** offset into the index buffer, not a count of indices.
        // It maps onto Metal's `indexBufferOffset`, and the name reads like an index. Passing
        // the count put every part after the first at a quarter of its intended position, so
        // the parts overlapped near the start of the buffer and the last three quarters of
        // the triangles were never drawn. Because a colour bucket is a contiguous run of
        // residues, the undrawn ones showed up as cleanly cross-sectioned gaps in the chain -
        // a backbone in pieces, from a mesh whose every index was present and correct.
        let indexStride = MemoryLayout<UInt32>.stride
        mesh.parts.replaceAll(buckets.parts.enumerated().map { index, part in
            LowLevelMesh.Part(indexOffset: part.offset * indexStride, indexCount: part.count,
                              topology: .triangle, materialIndex: index, bounds: bounds)
        })
        updateCount += 1
    }

    /// Single-part update, for callers that do not need per-colour parts.
    public func update(vertices: [RenderVertex]) throws {
        guard vertices.count <= vertexCapacity else {
            throw MeshError.capacityExceeded(needed: vertices.count, capacity: vertexCapacity)
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let buffer = raw.bindMemory(to: RenderVertex.self)
            for (i, vertex) in vertices.enumerated() { buffer[i] = vertex }
        }
        let box = TubeMeshPacker.bounds(vertices)
        let bounds = box.map {
            BoundingBox(min: $0.minimum, max: $0.maximum)
        } ?? BoundingBox(min: .zero, max: .zero)
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: indexCapacity,
                              topology: .triangle, materialIndex: 0, bounds: bounds)
        ])
        updateCount += 1
    }

    /// Update with an explicit set of indices, drawn as one part.
    ///
    /// Used by the halo, whose visible triangles change as the protein turns.
    public func update(vertices: [RenderVertex], indices: [UInt32]) throws {
        guard vertices.count <= vertexCapacity else {
            throw MeshError.capacityExceeded(needed: vertices.count, capacity: vertexCapacity)
        }
        guard indices.count <= indexCapacity else {
            throw MeshError.capacityExceeded(needed: indices.count, capacity: indexCapacity)
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let buffer = raw.bindMemory(to: RenderVertex.self)
            for (i, vertex) in vertices.enumerated() { buffer[i] = vertex }
        }
        mesh.withUnsafeMutableIndices { raw in
            let buffer = raw.bindMemory(to: UInt32.self)
            for (i, index) in indices.enumerated() { buffer[i] = index }
        }
        let box = TubeMeshPacker.bounds(vertices)
        let bounds = box.map { BoundingBox(min: $0.minimum, max: $0.maximum) }
            ?? BoundingBox(min: .zero, max: .zero)
        mesh.parts.replaceAll([
            LowLevelMesh.Part(indexOffset: 0, indexCount: indices.count,
                              topology: .triangle, materialIndex: 0, bounds: bounds)
        ])
        updateCount += 1
    }

    /// A `MeshResource` view of the current buffer, for attaching to a `ModelEntity`.
    public func resource() throws -> MeshResource {
        try MeshResource(from: mesh)
    }
}
#endif
