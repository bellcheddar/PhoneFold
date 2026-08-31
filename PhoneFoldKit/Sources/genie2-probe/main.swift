import Foundation
import CoreML
import FoldEngine
import FoldCore
import simd

// Measures the centre of mass along Genie 2's reverse process, with and without re-centring.
//
// The hypothesis under test: `sampleOnce` never returned its working translations to the
// zero-centre-of-mass subspace. Genie's translation diffusion is defined on that subspace and
// the network only ever saw zero-CoM inputs, so an uncorrected CoM random walk takes the input
// out of distribution - and the posterior mean multiplies by 1/sqrt(alpha_t), which is 2 at
// t = 1000, so whatever the network then returns is amplified by every step that follows.
//
// A single-step comparison against the Python reference cannot see this: at step one both are
// centred. Only the trajectory shows it.

let repoModel = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "Models/Genie2Step_L64.mlpackage")
guard FileManager.default.fileExists(atPath: repoModel.path) else {
    print("no model at \(repoModel.path) - run from the repository root")
    exit(1)
}
let compiled = try MLModel.compileModel(at: repoModel)
let sampler = Genie2Sampler(model: try MLModel(contentsOf: compiled))

func norm(_ x: [SIMD3<Double>]) -> Double {
    let centre = x.reduce(SIMD3<Double>.zero, +) / Double(x.count)
    return simd_length(centre)
}

for recentre in [false, true] {
    print(recentre ? "\n=== with re-centring ===" : "=== as shipped, no re-centring ===")
    for seed in UInt64(1)...6 {
        var maxCoM = 0.0
        var lastFiniteStep = -1
        // One run per seed, not two. Sampling each seed twice - once observed, once for the
        // final coordinates - exhausted Core ML's IOSurface pool part way through the second
        // pass ("Failed to allocate memory IOSurface object"), which is a limit of the probe
        // and not of the sampler. The observer already sees the final state.
        var final: [SIMD3<Double>] = []
        do {
            _ = try sampler.sampleOnce(
                seed: seed, scale: 0.6, frameCount: 24, recentre: recentre,
                progress: nil, shouldContinue: nil,
                observe: { step, trans in
                    let n = norm(trans)
                    if n.isFinite {
                        maxCoM = Swift.max(maxCoM, n)
                        lastFiniteStep = step
                        final = trans
                    }
                })
            var spacings: [Double] = []
            for i in 1..<final.count { spacings.append(simd_distance(final[i], final[i - 1])) }
            let mean = spacings.reduce(0, +) / Double(Swift.max(spacings.count, 1))
            let centre = final.reduce(SIMD3<Double>.zero, +) / Double(Swift.max(final.count, 1))
            let rg = (final.reduce(0.0) { $0 + simd_length_squared($1 - centre) }
                      / Double(Swift.max(final.count, 1))).squareRoot()
            print(String(format:
                "  seed %d  OK        max|CoM| %8.3f  CA-CA %.2f A  Rg %.1f A", seed, maxCoM,
                mean, rg))
        } catch {
            print(String(format: "  seed %d  DIVERGED  max|CoM| %8.3f  last finite step %d",
                         seed, maxCoM, lastFiniteStep))
        }
    }
}
