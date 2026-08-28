import Foundation
import simd
import FoldCore

/// One sampled point of a fold's progress, for the traces and the counters panel.
public struct HistorySample: Sendable, Equatable {
    public let frameIndex: Int
    /// 0...1 through the trajectory.
    public let progress: Double
    public let radiusOfGyration: Float
    public let compactness: Float
    public let contactCount: Int
    public let meanConfidence: Float
    public let helixFraction: Float
    public let sheetFraction: Float
    public let coilFraction: Float
    /// Contacts that formed on this frame, for the event rail under the timeline.
    public let newContacts: Int
    public let isRawFrame: Bool

    public init(frameIndex: Int, progress: Double, radiusOfGyration: Float,
                compactness: Float, contactCount: Int, meanConfidence: Float,
                helixFraction: Float, sheetFraction: Float, coilFraction: Float,
                newContacts: Int, isRawFrame: Bool) {
        self.frameIndex = frameIndex
        self.progress = progress
        self.radiusOfGyration = radiusOfGyration
        self.compactness = compactness
        self.contactCount = contactCount
        self.meanConfidence = meanConfidence
        self.helixFraction = helixFraction
        self.sheetFraction = sheetFraction
        self.coilFraction = coilFraction
        self.newContacts = newContacts
        self.isRawFrame = isRawFrame
    }
}

/// Accumulates a fold's progress for the live traces.
///
/// Marc's Phase 2 addition: **use metrics to show the progress of folding**. Everything here
/// is derived from frames that already exist, so the panel costs a few floats per frame
/// rather than any extra geometry or inference.
///
/// Bounded and evenly decimated. A 300-residue fold at 60 fps produces thousands of frames,
/// and a chart cannot show more points than it has pixels; keeping them all would grow
/// without limit for no visible benefit.
public struct FoldHistory: Sendable {

    public let capacity: Int
    public private(set) var samples: [HistorySample] = []
    /// How many frames are folded into each retained sample. Rises as the fold gets longer.
    public private(set) var stride: Int = 1
    /// The newest sample seen, whether or not the decimation gate retained it.
    ///
    /// The retained series is thinned as the fold lengthens, so without this the "current"
    /// reading would lag by up to `stride` frames while the numbers beside it were live.
    /// The chart wants an even series; the readout wants the truth.
    public private(set) var mostRecent: HistorySample?
    private var sinceLastKept = 0

    public init(capacity: Int = 480) {
        self.capacity = Swift.max(8, capacity)
    }

    public mutating func append(_ sample: HistorySample) {
        mostRecent = sample
        sinceLastKept += 1
        // A raw model readout is always kept: those are the real data points, and dropping
        // one to a decimation stride would hide an actual frame behind interpolated ones.
        guard sample.isRawFrame || sinceLastKept >= stride else { return }
        sinceLastKept = 0
        samples.append(sample)
        if samples.count > capacity { decimate() }
    }

    /// Halve the retained samples, keeping every other one, and double the stride.
    private mutating func decimate() {
        var kept: [HistorySample] = []
        kept.reserveCapacity(samples.count / 2 + 1)
        for (i, sample) in samples.enumerated() where i % 2 == 0 { kept.append(sample) }
        // Never lose the most recent point: it is what the readouts are showing right now.
        if let last = samples.last, kept.last?.frameIndex != last.frameIndex {
            kept.append(last)
        }
        samples = kept
        stride *= 2
    }

    public mutating func reset() {
        samples.removeAll()
        stride = 1
        sinceLastKept = 0
        mostRecent = nil
    }

    /// The newest sample, which is not necessarily the last retained one.
    public var latest: HistorySample? { mostRecent }

    /// The last sample retained in the decimated series, for chart continuity.
    public var lastPlotted: HistorySample? { samples.last }

    /// Range of a trace, padded so a flat line does not collapse to zero height.
    public func range(_ value: (HistorySample) -> Float) -> ClosedRange<Float> {
        let values = samples.map(value).filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        if high - low < 1e-4 { return (low - 0.5)...(high + 0.5) }
        let pad = (high - low) * 0.08
        return (low - pad)...(high + pad)
    }

    /// Frames where a contact formed, for marking the timeline.
    public var contactEvents: [HistorySample] { samples.filter { $0.newContacts > 0 } }
}
