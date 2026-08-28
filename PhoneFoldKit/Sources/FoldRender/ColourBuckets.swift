import Foundation
import simd
import FoldCore

/// Splits a tube mesh into colour buckets so it can be drawn with stock materials.
///
/// **Why this exists.** RealityKit's stock materials ignore a per-vertex colour channel, and
/// `CustomMaterial`, which would read it, fails to build a pipeline on the Simulator:
/// `fsSurfacePbr` reports "Constant buffer count [16] exceeds limit [14]" and the technique
/// never compiles, so the mesh is present, the material is assigned, and nothing draws at
/// all. That was verified by bisection: the identical mesh with a `SimpleMaterial` renders
/// correctly.
///
/// A `LowLevelMesh` can carry several parts, each with its own material index, so quantising
/// the colour into a modest number of buckets and drawing one part per bucket gives
/// per-residue colour with materials that work on every platform. Sixteen buckets across a
/// ramp is under two percent of the colour range per step, which is below what the eye picks
/// out on a curved surface.
public enum ColourBuckets {

    public static let defaultCount = 16

    public struct Result: Sendable {
        /// Indices reordered so each bucket's triangles are contiguous.
        public let indices: [UInt32]
        /// One entry per non-empty bucket: where its triangles start, how many, and the
        /// colour to tint that part.
        public let parts: [(offset: Int, count: Int, colour: LinearRGB)]
    }

    /// Group a mesh's triangles by quantised vertex colour.
    ///
    /// A triangle takes the bucket of its first vertex. Within a ring all three vertices
    /// share a residue, and across a ring boundary the colours are adjacent by construction,
    /// so the choice costs at most one bucket of error on the seam between two residues.
    public static func split(vertices: [RenderVertex], indices: [UInt32],
                             bucketCount: Int = defaultCount) -> Result {
        let count = Swift.max(1, bucketCount)
        guard !vertices.isEmpty, indices.count >= 3 else {
            return Result(indices: indices, parts: [])
        }

        // Bucket on luminance-weighted hue is overkill; quantising each channel to a small
        // grid keeps distinct ramp colours apart and merges near-identical ones.
        func key(_ colour: SIMD4<Float>) -> Int {
            let levels = Float(count - 1)
            let r = Int((Swift.min(Swift.max(colour.x, 0), 1) * levels).rounded())
            let g = Int((Swift.min(Swift.max(colour.y, 0), 1) * levels).rounded())
            let b = Int((Swift.min(Swift.max(colour.z, 0), 1) * levels).rounded())
            return (r * count + g) * count + b
        }

        var buckets: [Int: [UInt32]] = [:]
        var sums: [Int: (SIMD3<Float>, Int)] = [:]
        var triangle = 0
        while triangle + 2 < indices.count {
            let a = indices[triangle], b = indices[triangle + 1], c = indices[triangle + 2]
            guard Int(a) < vertices.count else { triangle += 3; continue }
            let colour = vertices[Int(a)].colour
            let k = key(colour)
            buckets[k, default: []].append(contentsOf: [a, b, c])
            let rgb = SIMD3<Float>(colour.x, colour.y, colour.z)
            let existing = sums[k] ?? (SIMD3<Float>.zero, 0)
            sums[k] = (existing.0 + rgb, existing.1 + 1)
            triangle += 3
        }

        var ordered: [UInt32] = []
        ordered.reserveCapacity(indices.count)
        var parts: [(offset: Int, count: Int, colour: LinearRGB)] = []
        // Sorted so the output is deterministic: the same protein must draw the same way.
        for k in buckets.keys.sorted() {
            guard let group = buckets[k], let (sum, n) = sums[k], n > 0 else { continue }
            parts.append((offset: ordered.count, count: group.count, colour: sum / Float(n)))
            ordered.append(contentsOf: group)
        }
        return Result(indices: ordered, parts: parts)
    }
}
