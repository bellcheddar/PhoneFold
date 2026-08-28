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
            // Four scalar attributes ride in one float4 texture coordinate: residue
            // parameter, structure confidence, structure code, residue confidence.
            .init(semantic: .uv0, format: .float4, layoutIndex: 0,
                  offset: MemoryLayout<RenderVertex>.offset(of: \.residueParameter)!),
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

    /// Rewrite the vertex buffer for one frame. No allocation, no MeshResource rebuild.
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

    /// A `MeshResource` view of the current buffer, for attaching to a `ModelEntity`.
    public func resource() throws -> MeshResource {
        try MeshResource(from: mesh)
    }
}
#endif
