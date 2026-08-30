import Foundation
import simd

/// Genie 2's cosine variance schedule, and the quantities its reverse process needs.
///
/// Ported from `genie/diffusion/schedule.py` in the upstream repository. The schedule is not in
/// the exported Core ML model - that model is a single denoising step, taking frames and a
/// timestep and returning predicted noise - so the reverse process has to be driven from here,
/// and every constant it uses has to match the training-time schedule exactly. A schedule that
/// is subtly wrong does not fail: it produces plausible-looking rubbish.
///
/// Indexing follows the upstream convention: element 0 is the un-noised stage and is a
/// deliberate zero, so `betas` has `n + 1` entries and step `t` runs from 1 to `n`.
public struct Genie2Schedule: Sendable {

    public let timesteps: Int
    public let betas: [Double]
    public let alphas: [Double]
    public let sqrtAlphas: [Double]
    public let alphasCumprod: [Double]
    public let sqrtOneMinusAlphasCumprod: [Double]
    public let sqrtBetas: [Double]

    public init(timesteps n: Int = 1000) {
        self.timesteps = n
        let steps = n + 1
        // **Computed in Float, deliberately.** Torch builds this schedule in float32, and the
        // early betas are a difference of two nearly-equal cosines - catastrophic cancellation,
        // where float32 rounding is the dominant term. In Double the answer is mathematically
        // better and *wrong for this model*: beta[1] comes out 2.4625e-06 against the
        // 2.5034e-06 the network was trained and sampled with, a 1.6% difference on the very
        // last denoising step. Matching the reference implementation matters more here than
        // matching the formula.
        var cumprodCosine = [Float](repeating: 0, count: steps)
        for i in 0..<steps {
            let x = Float(i)
            let c = cos((x / Float(steps)) * .pi * 0.5)
            cumprodCosine[i] = c * c
        }
        let first = cumprodCosine[0]
        for i in 0..<steps { cumprodCosine[i] /= first }

        // betas from the ratio of consecutive cumulative products, clipped, with a leading 0.
        var b = [Double](repeating: 0, count: steps)
        for i in 1..<steps {
            let raw = 1 - cumprodCosine[i] / cumprodCosine[i - 1]
            b[i] = Double(Swift.min(Swift.max(raw, 0), 0.999))
        }
        betas = b
        alphas = b.map { 1 - $0 }
        sqrtAlphas = alphas.map { $0.squareRoot() }
        sqrtBetas = b.map { $0.squareRoot() }

        var running = 1.0
        var cumulative = [Double](repeating: 0, count: steps)
        for i in 0..<steps {
            running *= alphas[i]
            cumulative[i] = running
        }
        alphasCumprod = cumulative
        sqrtOneMinusAlphasCumprod = cumulative.map { Swift.max(1 - $0, 0).squareRoot() }
    }

    /// The weight applied to the predicted noise at step `t`, and the mean's scale.
    ///
    /// `trans_mean = (1 / sqrt(alpha_t)) * (trans - w_z * z_pred)`, which is the standard DDPM
    /// posterior mean written the way the upstream sampler writes it.
    public func meanTerms(at t: Int) -> (noiseWeight: Double, scale: Double) {
        let index = Swift.min(Swift.max(t, 0), timesteps)
        let w = (1 - alphas[index]) / sqrtOneMinusAlphasCumprod[index]
        return (w, 1 / sqrtAlphas[index])
    }
}

/// Frenet-Serret frames along a chain of alpha carbons.
///
/// Genie 2 works on SE(3) frames, and its sampler rebuilds the rotational part from the
/// translations at every step rather than diffusing it - so this is not an optional nicety, it
/// is part of the reverse process and has to match.
///
/// Ported from `compute_frenet_frames` in `genie/utils/geo_utils.py`. The first residue takes
/// the second's rotation and the last takes the second-last's, because a frame needs three
/// consecutive points and the ends do not have them.
public enum FrenetFrames {

    /// Columns of each returned matrix are the tangent, binormal and normal, in that order,
    /// which is how the upstream `torch.stack([t, b, n], dim=-1)` lays them out.
    public static func compute(_ coords: [SIMD3<Double>],
                               epsilon: Double = 1e-10) -> [simd_double3x3] {
        let n = coords.count
        guard n >= 3 else {
            return [simd_double3x3](repeating: matrix_identity_double3x3, count: Swift.max(n, 0))
        }
        // Unit tangents between consecutive residues.
        var t = [SIMD3<Double>](repeating: .zero, count: n - 1)
        for i in 0..<(n - 1) {
            let d = coords[i + 1] - coords[i]
            // The epsilon is inside the square root upstream, not added to the length after,
            // and it matters for a degenerate step where the difference is zero.
            t[i] = d / (epsilon + simd_dot(d, d)).squareRoot()
        }
        var frames = [simd_double3x3](repeating: matrix_identity_double3x3, count: n)
        for i in 0..<(n - 2) {
            let cross = simd_cross(t[i], t[i + 1])
            let b = cross / (epsilon + simd_dot(cross, cross)).squareRoot()
            let normal = simd_cross(b, t[i + 1])
            // Residue i + 1 is the one with three consecutive points around it.
            frames[i + 1] = simd_double3x3(columns: (t[i + 1], b, normal))
        }
        // The ends borrow their neighbour's frame.
        frames[0] = frames[1]
        frames[n - 1] = frames[n - 2]
        return frames
    }
}
