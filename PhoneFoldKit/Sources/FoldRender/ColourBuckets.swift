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
/// **No longer on the render path.** The app draws the protein as a single part with a ramp
/// texture now - see `ColourRamp` - because every part here is one flat tint, and a ramp
/// delivered as flat tints is a staircase. This is kept because it is still the fallback for
/// any path that cannot sample a texture, and because its tests pin the byte-offset contract
/// of `LowLevelMesh.Part`, which is worth keeping honest either way.
public enum ColourBuckets {

    /// Levels per channel.
    ///
    /// Sixteen levels was justified in an earlier comment as "under two percent of the colour
    /// range per step". That arithmetic was wrong: sixteen levels is fifteen steps, so 6.7%
    /// per step, and on a strand ribbon several angstroms wide and lit almost evenly across
    /// its face those steps showed as clean diagonal bands. Forty-eight levels is 2.1% per
    /// step.
    ///
    /// Two costs, both measured. Draw calls: not 48 cubed of them, because only buckets that
    /// contain triangles become parts and a protein's colours lie along a ramp rather than
    /// filling the cube. And the counting sort's working arrays, which are sized by the key
    /// space and zeroed every frame: that took the 314-residue geometry pass from 2.52 ms to
    /// 2.90 ms. Worth 0.38 ms of a 16.7 ms budget to lose the banding; not worth going
    /// further without making the scratch buffers persistent.
    public static let defaultCount = 48

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

        // Counting sort over the fixed key space, rather than a dictionary of arrays.
        //
        // The obvious `buckets[key, default: []].append(...)` per triangle costs a hash
        // lookup and a copy-on-write check 45,000 times a frame: measured at 3.25 ms for a
        // 314-residue tube against a 0.52 ms budget for the rest of the geometry, which is a
        // fifth of the entire 60 fps frame. The key space is only `count^3`, so counting the
        // triangles per bucket and filling by prefix sum is O(n) with no allocation per
        // triangle.
        let keySpace = count * count * count
        let triangleCount = indices.count / 3
        var keys = [Int32](repeating: -1, count: triangleCount)
        var counts = [Int](repeating: 0, count: keySpace)
        var sums = [SIMD3<Float>](repeating: .zero, count: keySpace)

        for triangle in 0..<triangleCount {
            let a = indices[triangle * 3]
            guard Int(a) < vertices.count else { continue }
            let colour = vertices[Int(a)].colour
            let k = key(colour)
            keys[triangle] = Int32(k)
            counts[k] += 1
            sums[k] += SIMD3<Float>(colour.x, colour.y, colour.z)
        }

        // Prefix sums give each bucket its slice of the output, in ascending key order, so
        // the result is deterministic: the same protein must draw the same way.
        var offsets = [Int](repeating: 0, count: keySpace)
        var parts: [(offset: Int, count: Int, colour: LinearRGB)] = []
        var running = 0
        for k in 0..<keySpace where counts[k] > 0 {
            offsets[k] = running
            parts.append((offset: running, count: counts[k] * 3,
                          colour: sums[k] / Float(counts[k])))
            running += counts[k] * 3
        }

        var ordered = [UInt32](repeating: 0, count: running)
        var cursors = offsets
        for triangle in 0..<triangleCount {
            let k = keys[triangle]
            guard k >= 0 else { continue }
            let slot = cursors[Int(k)]
            ordered[slot] = indices[triangle * 3]
            ordered[slot + 1] = indices[triangle * 3 + 1]
            ordered[slot + 2] = indices[triangle * 3 + 2]
            cursors[Int(k)] = slot + 3
        }

        return Result(indices: ordered, parts: parts)
    }
}
