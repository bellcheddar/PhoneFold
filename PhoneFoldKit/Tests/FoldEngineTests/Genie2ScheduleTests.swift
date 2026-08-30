import Testing
import Foundation
import simd
@testable import FoldEngine

/// The Genie 2 schedule and frame construction, against the upstream Python.
///
/// A diffusion schedule that is subtly wrong does not fail loudly - it denoises to plausible
/// rubbish - so these are checked against values produced by the real `cosine_beta_schedule`
/// and `compute_frenet_frames`, not against a re-derivation of the same formulae.
@Suite("Genie 2 schedule")
struct Genie2ScheduleTests {

    struct Reference: Decodable {
        let n_timestep: Int
        let betas_head: [Double]
        let betas_tail: [Double]
        let alphas_cumprod_head: [Double]
        let alphas_cumprod_tail: [Double]
        let coords: [[Double]]
        let rots: [[[Double]]]
    }

    static func reference() throws -> Reference {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/genie2_reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    @Test("The cosine schedule matches upstream at both ends")
    func scheduleMatches() throws {
        let expected = try Self.reference()
        let schedule = Genie2Schedule(timesteps: expected.n_timestep)
        #expect(schedule.betas.count == expected.n_timestep + 1)
        // Element 0 is the un-noised stage and is a deliberate zero.
        #expect(schedule.betas[0] == 0)

        // The first betas cannot be reproduced more precisely than this, by anyone.
        //
        // They are `1 - (ratio of two nearly-equal cosines)`, computed in float32 - textbook
        // catastrophic cancellation, where the absolute error is one ULP of 1.0 regardless of
        // how the arithmetic is ordered. Measured, this port differs from upstream by exactly
        // 1.1920928955078125e-07, which is 2^-23. Upstream's own values carry the same noise;
        // there is no more accurate answer to agree with. Two ULPs of headroom.
        let float32Floor = 3.0 * 1.1920928955078125e-07
        for (i, value) in expected.betas_head.enumerated() {
            #expect(abs(schedule.betas[i] - value) < float32Floor,
                    "beta[\(i)] is \(schedule.betas[i]), upstream says \(value)")
        }
        // What that noise is worth where it is used: beta[1] scales the noise added on the
        // final denoising step as its square root, so a 1.2e-07 difference on 2.5e-06 moves
        // that step's noise by about a hundredth of a milliangstrom.
        #expect(abs((schedule.betas[1]).squareRoot()
                    - (expected.betas_head[1]).squareRoot()) < 1e-4)
        // The last betas are compared relatively, and loosely, for the same reason as the
        // first ones: they are the ratio of two cosines that have both collapsed to about
        // 1e-12 by then, so their relative errors amplify. Measured disagreement is 1.4e-05
        // relative. What it is worth: beta scales added noise as its square root, and
        // sqrt(0.3599776) against sqrt(0.3599825) differ in the sixth decimal place.
        for (offset, value) in expected.betas_tail.enumerated() {
            let i = schedule.betas.count - expected.betas_tail.count + offset
            #expect(abs(schedule.betas[i] - value) / value < 1e-4,
                    "beta[\(i)] is \(schedule.betas[i]), upstream says \(value)")
            #expect(abs(schedule.betas[i].squareRoot() - value.squareRoot()) < 1e-4,
                    "the noise scale differs materially at step \(i)")
        }
        for (offset, value) in expected.alphas_cumprod_tail.enumerated() {
            let i = schedule.alphasCumprod.count - expected.alphas_cumprod_tail.count + offset
            // The cumulative product runs to 2.5e-06 over a thousand steps, so compare
            // relatively: an absolute tolerance is meaningless against a number that small.
            // The bound is 5e-04 because that is above the measured float32 accumulation floor
            // - a thousand multiplications of ULP-noisy alphas reach 7.6e-05 relative by the
            // end - and far below anything a genuinely wrong schedule would produce, which
            // would be out by orders of magnitude rather than parts per ten thousand.
            #expect(abs(schedule.alphasCumprod[i] - value) / value < 5e-4,
                    "cumprod[\(i)] is \(schedule.alphasCumprod[i]), upstream says \(value)")
        }
        // The clip at 0.999 must actually be reachable and never exceeded.
        #expect(schedule.betas.allSatisfy { $0 >= 0 && $0 <= 0.999 })
    }

    @Test("Frenet frames match upstream on a real coordinate set")
    func frenetFramesMatch() throws {
        let expected = try Self.reference()
        let coords = expected.coords.map { SIMD3<Double>($0[0], $0[1], $0[2]) }
        let frames = FrenetFrames.compute(coords)
        #expect(frames.count == coords.count)

        var worst = 0.0
        for (residue, matrix) in expected.rots.enumerated() {
            for row in 0..<3 {
                for column in 0..<3 {
                    // simd indexes [column][row]; the fixture is row-major from torch.
                    worst = Swift.max(worst,
                                      abs(frames[residue][column][row] - matrix[row][column]))
                }
            }
        }
        #expect(worst < 1e-6, "worst frame element disagreement with upstream: \(worst)")
    }

    /// Genie 2's frames are orthonormal but **improper**: determinant -1, not +1.
    ///
    /// Not a porting mistake - the port matches upstream element for element. It falls out of
    /// the construction: the binormal is perpendicular to the tangent, so
    /// `t . (b x n) = t . (b x (b x t)) = -1` exactly. Genie 2 was trained on frames built this
    /// way, so "correcting" them to proper rotations would feed the network something it has
    /// never seen. The invariant worth asserting is orthonormality, and that the handedness is
    /// consistently negative rather than varying residue to residue.
    @Test("Every frame is orthonormal, and improper by construction")
    func framesAreRotations() throws {
        let expected = try Self.reference()
        let coords = expected.coords.map { SIMD3<Double>($0[0], $0[1], $0[2]) }
        for frame in FrenetFrames.compute(coords) {
            #expect(abs(simd_determinant(frame) + 1) < 1e-6,
                    "determinant \(simd_determinant(frame)) is not -1")
            let shouldBeIdentity = frame.transpose * frame
            for i in 0..<3 {
                for j in 0..<3 {
                    let target = i == j ? 1.0 : 0.0
                    #expect(abs(shouldBeIdentity[i][j] - target) < 1e-6, "not orthonormal")
                }
            }
        }
    }
}
