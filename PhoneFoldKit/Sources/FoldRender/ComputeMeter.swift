import Foundation

/// What the app can honestly say about where the work is happening.
///
/// Marc asked for a GPU / ANE meter during folding. Two things constrain what that can be:
///
/// 1. **There is no public API for live GPU or ANE utilisation on iOS.** Anything claiming a
///    percentage would be invented.
/// 2. **The app currently plays precomputed trajectories.** Until the Core ML model is wired
///    in, no inference is happening on device at all, so a compute meter would be measuring
///    nothing.
///
/// So this reports what is real: the measured frame cost of the work the app *is* doing, and
/// the compute unit the engine is configured for once there is one. The label says which of
/// those it is, rather than implying a hardware utilisation reading that does not exist.
public struct ComputeMeter: Sendable {

    public enum Workload: String, Sendable {
        /// Replaying a precomputed trajectory. No inference.
        case playback = "Playback"
        /// Generating on device through Core ML.
        case generating = "Generating"
    }

    public enum Unit: String, Sendable {
        case cpu = "CPU"
        case gpu = "GPU"
        case neuralEngine = "ANE"
        case none = "—"
    }

    public private(set) var workload: Workload = .playback
    /// The compute unit the model is configured for. Not a utilisation reading.
    public private(set) var unit: Unit = .none

    private var frameCosts: [Double] = []
    private let window = 60

    public init() {}

    public mutating func configure(workload: Workload, unit: Unit) {
        self.workload = workload
        self.unit = unit
    }

    /// Record how long one frame's work took, in milliseconds.
    public mutating func record(frameCostMilliseconds cost: Double) {
        guard cost.isFinite, cost >= 0 else { return }
        frameCosts.append(cost)
        if frameCosts.count > window { frameCosts.removeFirst(frameCosts.count - window) }
    }

    public var averageFrameCost: Double {
        guard !frameCosts.isEmpty else { return 0 }
        return frameCosts.reduce(0, +) / Double(frameCosts.count)
    }

    /// Fraction of a 60 fps frame budget consumed, 0...1+. This is a real measurement of the
    /// app's own cost, not a hardware utilisation figure.
    public var budgetFraction: Double {
        guard averageFrameCost > 0 else { return 0 }
        return averageFrameCost / (1000.0 / 60.0)
    }

    /// What to show beside the meter. Deliberately says "frame" rather than implying a
    /// hardware reading.
    public var label: String {
        unit == .none ? "\(workload.rawValue) · frame"
                      : "\(workload.rawValue) · \(unit.rawValue) · frame"
    }
}
