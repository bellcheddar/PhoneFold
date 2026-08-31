import Foundation
import simd
import CoreML
import FoldCore

/// Drives Genie 2's reverse diffusion on the device, one Core ML step at a time.
///
/// The exported model is a single denoising step: SE(3) frames and a timestep in, predicted
/// noise out. Everything else - the cosine schedule, the posterior mean, the noise added back
/// at each step, and rebuilding the rotational part of the frames from the translations - is
/// here, ported from `genie/diffusion` and `genie/sampler` and checked against them.
///
/// **This engine generates; it does not fold toward anything.** There is no reference structure
/// and no target: it starts from Gaussian noise and ends at a backbone that has never existed.
/// That is a different act from the other two engines and the app says so.
public final class Genie2Sampler: @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible {
        case modelMissing
        case modelFailed(String)
        case wrongLength(expected: Int, asked: Int)
        /// The reverse process produced something that is not a chain. Named specifically,
        /// because "inconsistent trajectory" three layers downstream says nothing about which
        /// of a dozen possible causes it was.
        case degenerateOutput(reason: String)

        public var description: String {
            switch self {
            case .modelMissing: "The Genie 2 model is not in the app bundle."
            case .modelFailed(let m): "Genie 2 could not run: \(m)"
            case .wrongLength(let expected, let asked):
                "This Genie 2 export generates \(expected) residues, not \(asked)."
            case .degenerateOutput(let reason): "Genie 2 produced no usable backbone: \(reason)"
            }
        }
    }

    /// The exported model is compiled for a fixed length; a different one needs a new export.
    public static let residues = 64

    private let model: MLModel
    public let schedule: Genie2Schedule

    public init(model: MLModel, timesteps: Int = 1000) {
        self.model = model
        self.schedule = Genie2Schedule(timesteps: timesteps)
    }

    /// Load the model that ships in the app bundle.
    public static func bundled(configuration: MLModelConfiguration = .init()) throws
        -> Genie2Sampler {
        // `.mlpackage` is compiled to `.mlmodelc` at build time, so that is what is in the
        // bundle; asking for the package name would find nothing.
        guard let url = Bundle.main.url(forResource: "Genie2Step_L64", withExtension: "mlmodelc")
        else { throw Failure.modelMissing }
        return Genie2Sampler(model: try MLModel(contentsOf: url, configuration: configuration))
    }

    // MARK: - Multi-array plumbing

    /// Write a flat sequence into a multi-array, honouring its strides.
    ///
    /// **Never `index * width`.** Core ML is free to pad rows, and its arrays report that
    /// through `strides` rather than through `shape`. Indexing by arithmetic on the shape reads
    /// correctly for the first element and is progressively wrong after it, which produces a
    /// perfectly plausible-looking result built from the wrong numbers.
    static func fill(_ array: MLMultiArray, residues: Int, columns: Int,
                     _ value: (Int, Int) -> Float) {
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        // Shapes here are [1, N, C] or [1, N, C, C]; the leading batch stride is strides[0].
        for residue in 0..<residues {
            for column in 0..<columns {
                let offset = residue * strides[1] + column * strides[2]
                pointer[offset] = value(residue, column)
            }
        }
    }

    static func fillMatrix(_ array: MLMultiArray, residues: Int,
                           _ value: (Int, Int, Int) -> Float) {
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        for residue in 0..<residues {
            for row in 0..<3 {
                for column in 0..<3 {
                    let offset = residue * strides[1] + row * strides[2] + column * strides[3]
                    pointer[offset] = value(residue, row, column)
                }
            }
        }
    }

    static func read(_ array: MLMultiArray, residues: Int) -> [SIMD3<Double>] {
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        return (0..<residues).map { residue in
            SIMD3<Double>(Double(pointer[residue * strides[1]]),
                          Double(pointer[residue * strides[1] + strides[2]]),
                          Double(pointer[residue * strides[1] + 2 * strides[2]]))
        }
    }

    // MARK: - Sampling

    /// Run the reverse process, retrying with the next seed if it diverges.
    ///
    /// **The divergence had a cause, and it was here rather than in the arithmetic.** Half the
    /// seeds used to reach NaN part way through the reverse process - measured: seeds 1, 2 and 6
    /// of the first six - and the retry above was shipped as an admitted workaround while the
    /// reason was unknown. Everything that could be checked against the reference implementation
    /// had been, and agreed: fed identical starting coordinates, one step of this Swift matches
    /// the Python to 0.01 in the predicted noise and 0.015 in the updated translations, the
    /// schedule matches to float32's own precision, the frames match element for element, and
    /// the generator is standard normal with no serial correlation.
    ///
    /// What none of that could see is a quantity that only drifts *over* a trajectory. Genie's
    /// translation diffusion is defined on the **zero-centre-of-mass subspace**, and the network
    /// only ever saw inputs from it. `sampleOnce` centred the coordinates it *recorded* but
    /// never the ones it fed back in, so the centre of mass performed an unconstrained random
    /// walk: measured at up to 114 A from the origin, on a chain whose own radius of gyration is
    /// about 11 A. Once the input is that far out of distribution the predicted noise is
    /// meaningless, and the posterior mean multiplies by `1/sqrt(alpha_t)` - which is 2 at
    /// t = 1000 - so it is amplified by every step that follows. Some draws tipped over; the
    /// surprise in hindsight is that any survived.
    ///
    /// Projecting back onto the subspace each step fixes it, and the evidence is not just the
    /// absence of a NaN:
    ///
    /// | | seeds 1-6 | max &#124;CoM&#124; | CA-CA spacing |
    /// |---|---|---|---|
    /// | as shipped | 3 of 6 diverged | 114 A | 3.86 to 3.94 A |
    /// | re-centred | 6 of 6 succeeded | 0 | 3.85 to 3.86 A |
    ///
    /// The spacing is the second signal. Ideal consecutive CA-CA is 3.8 A; without re-centring
    /// even the seeds that survived were drifting up to 3.94 and scattering eight times as
    /// widely. That is a geometry improving, not merely a crash avoided.
    ///
    /// **The retry is kept, and is no longer load-bearing.** It costs nothing when nothing
    /// diverges, and removing the net at the same moment as fixing the thing it was catching
    /// would leave a future regression with nowhere to land.
    public func sample(seed: UInt64 = 1, scale: Double = 0.6, frameCount: Int = 180,
                       attempts: Int = 4, recentre: Bool = true,
                       progress: (@Sendable (Double) -> Void)? = nil,
                       shouldContinue: (@Sendable () -> Bool)? = nil)
        throws -> [[SIMD3<Double>]] {
        var lastFailure: Error?
        for attempt in 0..<Swift.max(attempts, 1) {
            do {
                return try sampleOnce(seed: seed &+ UInt64(attempt), scale: scale,
                                      frameCount: frameCount, recentre: recentre,
                                      progress: progress,
                                      shouldContinue: shouldContinue)
            } catch let failure as Failure {
                guard case .degenerateOutput = failure else { throw failure }
                lastFailure = failure
                if let shouldContinue, !shouldContinue() { throw Failure.modelFailed("cancelled") }
            }
        }
        throw lastFailure ?? Failure.degenerateOutput(reason: "every attempt diverged")
    }

    /// One reverse run.
    ///
    /// `observe` is called after every step with the step index and the working translations,
    /// which is how the centre-of-mass drift was measured without duplicating this loop into a
    /// diagnostic copy that could then disagree with it.
    public func sampleOnce(seed: UInt64, scale: Double, frameCount: Int,
                           recentre: Bool = true,
                           progress: (@Sendable (Double) -> Void)?,
                           shouldContinue: (@Sendable () -> Bool)?,
                           observe: ((Int, [SIMD3<Double>]) -> Void)? = nil)
        throws -> [[SIMD3<Double>]] {
        let n = Self.residues
        var rng = SplitMix64(seed: seed)

        // Pure noise, and the frames that go with it.
        var trans = (0..<n).map { _ in
            SIMD3<Double>(rng.gaussian(), rng.gaussian(), rng.gaussian())
        }
        // Genie's translation diffusion lives on the zero-centre-of-mass subspace, so the
        // starting draw belongs there too rather than being an arbitrary point in R^3N.
        if recentre { trans = Self.centred(trans) }
        var rots = FrenetFrames.compute(trans)

        let transArray = try MLMultiArray(shape: [1, NSNumber(value: n), 3], dataType: .float32)
        let rotsArray = try MLMultiArray(shape: [1, NSNumber(value: n), 3, 3],
                                         dataType: .float32)
        let stepArray = try MLMultiArray(shape: [1], dataType: .int32)

        let total = schedule.timesteps
        let stride = Swift.max(total / Swift.max(frameCount - 1, 1), 1)
        var frames: [[SIMD3<Double>]] = [Self.centred(trans)]
        frames.reserveCapacity(frameCount)

        for step in stride_reversed(from: total, to: 1) {
            Self.fill(transArray, residues: n, columns: 3) { residue, column in
                Float(trans[residue][column])
            }
            Self.fillMatrix(rotsArray, residues: n) { residue, row, column in
                // simd indexes [column][row]; the model wants row-major, as torch stacked it.
                Float(rots[residue][column][row])
            }
            stepArray[0] = NSNumber(value: Int32(step))

            let input = try MLDictionaryFeatureProvider(dictionary: [
                "trans": MLFeatureValue(multiArray: transArray),
                "rots": MLFeatureValue(multiArray: rotsArray),
                "timesteps": MLFeatureValue(multiArray: stepArray),
            ])
            guard let output = try? model.prediction(from: input),
                  let z = output.featureValue(for: "z")?.multiArrayValue
            else { throw Failure.modelFailed("the step model returned no noise estimate") }
            let noise = Self.read(z, residues: n)

            let terms = schedule.meanTerms(at: step)
            var mean = [SIMD3<Double>](repeating: .zero, count: n)
            for i in 0..<n { mean[i] = (trans[i] - noise[i] * terms.noiseWeight) * terms.scale }

            if step == 1 {
                trans = mean
            } else {
                let sigma = schedule.sqrtBetas[step]
                for i in 0..<n {
                    let jitter = SIMD3<Double>(rng.gaussian(), rng.gaussian(), rng.gaussian())
                    mean[i] += jitter * (scale * sigma)
                }
                trans = mean
            }
            // **Back onto the zero-centre-of-mass subspace, every step.** See `sample` for
            // what happens without it.
            if recentre { trans = Self.centred(trans) }
            rots = FrenetFrames.compute(trans)
            observe?(step, trans)

            let done = total - step + 1
            if done % stride == 0, frames.count < frameCount {
                frames.append(Self.centred(trans))
                progress?(Double(done) / Double(total))
                if let shouldContinue, !shouldContinue() { break }
            }
        }
        if frames.last.map({ $0 != Self.centred(trans) }) ?? true {
            frames.append(Self.centred(trans))
        }
        try Self.validate(frames, residues: n)
        return frames
    }

    /// Check the reverse process produced a chain, and say precisely what is wrong if not.
    ///
    /// Without this a bad frame surfaces as "that trajectory's frames disagree with each other"
    /// from the provider, which is true and useless: it names the symptom three layers from
    /// the cause and does not say whether the coordinates were non-finite, the wrong count, or
    /// simply not a polypeptide.
    static func validate(_ frames: [[SIMD3<Double>]], residues n: Int) throws {
        guard !frames.isEmpty else {
            throw Failure.degenerateOutput(reason: "no frames were produced")
        }
        for (index, frame) in frames.enumerated() {
            guard frame.count == n else {
                throw Failure.degenerateOutput(
                    reason: "frame \(index) has \(frame.count) residues, expected \(n)")
            }
            for (residue, p) in frame.enumerated()
            where !p.x.isFinite || !p.y.isFinite || !p.z.isFinite {
                throw Failure.degenerateOutput(
                    reason: "frame \(index) residue \(residue) is \(p)")
            }
        }
        // The final frame must be a backbone: consecutive alpha carbons about 3.8 A apart.
        let final = frames[frames.count - 1]
        var total = 0.0
        for i in 0..<(final.count - 1) { total += simd_length(final[i + 1] - final[i]) }
        let mean = total / Double(Swift.max(final.count - 1, 1))
        guard mean > 2.5, mean < 6 else {
            throw Failure.degenerateOutput(
                reason: String(format: "mean CA-CA spacing is %.2f A, not a backbone", mean))
        }
    }

    /// Each frame on its own centroid, which is what Genie 2's own writer does. This removes
    /// translational drift only; rotational alignment between frames is the playback's job.
    static func centred(_ x: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard !x.isEmpty else { return x }
        let centre = x.reduce(SIMD3<Double>.zero, +) / Double(x.count)
        return x.map { $0 - centre }
    }

    /// `total` down to `to`, inclusive, which `stride(from:through:by:)` expresses awkwardly
    /// for a descending range and which is easy to get off by one.
    private func stride_reversed(from total: Int, to lowest: Int) -> [Int] {
        Array((lowest...total).reversed())
    }
}
