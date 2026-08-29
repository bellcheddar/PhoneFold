import Foundation

/// Timing that survives a busy machine.
///
/// Wall-clock budgets in tests are a trap on a shared machine: the same code measured 2.52 ms
/// alone and 3.32 ms inside a parallel test run, and the performance gates in this suite went
/// red twice for reasons that had nothing to do with the code. Widening the band each time
/// only postpones it and blunts the check.
///
/// So the budget is expressed against a calibration measured *in the same run*: a fixed,
/// deterministic piece of arithmetic whose cost tracks whatever else the machine is doing. The
/// assertion is then a ratio, and a ratio does not care how loaded the box is.
enum Bench {

    /// A deterministic workload, sized to take a similar order of time to a frame's geometry.
    static func calibrationMilliseconds() -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = Date()
            var accumulator: Double = 0
            for i in 0..<2_000_000 { accumulator += Double(i % 7) * 1.000001 }
            best = Swift.min(best, Date().timeIntervalSince(start) * 1000)
            precondition(accumulator > 0)
        }
        return best
    }

    /// Fastest of several batches, which is the closest estimate of the real cost.
    static func fastestMilliseconds(batches: Int = 5, iterations: Int = 10,
                                    _ body: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<batches {
            let start = Date()
            for _ in 0..<iterations { body() }
            best = Swift.min(best, Date().timeIntervalSince(start) / Double(iterations) * 1000)
        }
        return best
    }

    /// The cost of `body` as a multiple of the calibration, measured **interleaved**.
    ///
    /// Calibrating once and measuring once leaves a window between them, and a load spike
    /// that lands in that window skews the ratio - which is how both performance tests failed
    /// together on one run out of eight while passing on the others. Pairing the two
    /// measurements inside each batch and taking the smallest ratio closes it: a spike has to
    /// hit every batch, and hit both halves of one equally, to survive.
    static func ratioToCalibration(batches: Int = 5, iterations: Int = 10,
                                   _ body: () -> Void) -> (ratio: Double, milliseconds: Double,
                                                           calibration: Double) {
        var bestRatio = Double.greatestFiniteMagnitude
        var atMilliseconds = 0.0
        var atCalibration = 0.0
        for _ in 0..<batches {
            let workStart = Date()
            for _ in 0..<iterations { body() }
            let work = Date().timeIntervalSince(workStart) / Double(iterations) * 1000

            let calibrationStart = Date()
            var accumulator: Double = 0
            for i in 0..<2_000_000 { accumulator += Double(i % 7) * 1.000001 }
            precondition(accumulator > 0)
            let calibration = Date().timeIntervalSince(calibrationStart) * 1000

            let ratio = work / calibration
            if ratio < bestRatio {
                bestRatio = ratio; atMilliseconds = work; atCalibration = calibration
            }
        }
        return (bestRatio, atMilliseconds, atCalibration)
    }
}
