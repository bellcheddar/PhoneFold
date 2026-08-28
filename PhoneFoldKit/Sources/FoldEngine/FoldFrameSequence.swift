import Foundation
import simd
import FoldCore
import FoldGeometry

/// A backpressured stream of enriched `FoldFrame` values.
///
/// **Pull-based on purpose.** PLAN.md Phase 1 requires that frames are never dropped, because
/// the order of a trajectory *is* the trajectory, and that a slow consumer slows the clock
/// rather than losing frames. `AsyncStream` cannot express that: its buffering policies all
/// either drop frames or grow without bound, and its continuation cannot block. An
/// `AsyncSequence` whose iterator computes each frame on demand is backpressured by
/// construction, needs no buffer, and cannot drop anything.
///
/// Each frame is produced by aligning the raw readouts, interpolating between them,
/// assigning secondary structure, and computing metrics. Contacts are advanced **only on raw
/// frames**: firing them on interpolated frames would turn one contact into a burst of sixty.
public struct FoldFrameSequence: AsyncSequence, Sendable {
    public typealias Element = FoldFrame

    public struct Configuration: Sendable {
        /// Output frames per second.
        public var frameRate: Float
        /// Wall-clock seconds each raw readout occupies. Playback pacing, not anything the
        /// model did: raw readouts have no time of their own.
        public var secondsPerRawFrame: Float
        /// Which secondary structure assigner to use.
        public var assigner: SecondaryStructureAssigner
        /// Frames of hysteresis before a residue is allowed to change state.
        public var hysteresisWindow: Int
        /// Emit in real time. Off by default so tests and offline export run at full speed.
        public var paced: Bool

        public init(frameRate: Float = 60,
                    secondsPerRawFrame: Float = 1.0 / 12.0,
                    assigner: SecondaryStructureAssigner = .learned,
                    hysteresisWindow: Int = 3,
                    paced: Bool = false) {
            self.frameRate = frameRate
            self.secondsPerRawFrame = secondsPerRawFrame
            self.assigner = assigner
            self.hysteresisWindow = hysteresisWindow
            self.paced = paced
        }
    }

    let readouts: [TrajectoryReadout]
    let residues: [AminoAcid]
    let configuration: Configuration

    public init(provider: some FoldFrameProvider, configuration: Configuration = .init()) {
        self.readouts = provider.readouts
        self.residues = provider.residues
        self.configuration = configuration
    }

    /// Number of frames this sequence will produce.
    public var frameCount: Int {
        let interpolator = TrajectoryInterpolator(rawFrames: readouts.map(\.caPositions),
                                                  alreadyAligned: true)
        return interpolator.outputFrameCount(frameRate: configuration.frameRate,
                                             secondsPerRawFrame: configuration.secondsPerRawFrame)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(readouts: readouts, residues: residues, configuration: configuration)
    }

    public struct Iterator: AsyncIteratorProtocol {
        let interpolator: TrajectoryInterpolator
        let readouts: [TrajectoryReadout]
        let residues: [AminoAcid]
        let configuration: Configuration
        let total: Int

        var index = 0
        var hysteresis: SSHysteresis
        var contacts = ContactTracker()
        var lastRawFrameIndex = -1

        init(readouts: [TrajectoryReadout], residues: [AminoAcid],
             configuration: Configuration) {
            // Align once, up front: interpolating between two orientations of the same
            // structure without aligning drags every atom through the middle of the molecule.
            self.interpolator = TrajectoryInterpolator(rawFrames: readouts.map(\.caPositions))
            self.readouts = readouts
            self.residues = residues
            self.configuration = configuration
            self.total = TrajectoryInterpolator(rawFrames: readouts.map(\.caPositions),
                                                alreadyAligned: true)
                .outputFrameCount(frameRate: configuration.frameRate,
                                  secondsPerRawFrame: configuration.secondsPerRawFrame)
            self.hysteresis = SSHysteresis(window: configuration.hysteresisWindow,
                                           residueCount: readouts.first?.caPositions.count ?? 0)
        }

        public mutating func next() async -> FoldFrame? {
            if Task.isCancelled { return nil }
            guard index < total, !readouts.isEmpty else { return nil }

            if configuration.paced, index > 0, configuration.frameRate > 0 {
                let nanoseconds = UInt64(1_000_000_000 / Double(configuration.frameRate))
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled { return nil }
            }

            let u = interpolator.parameter(forOutputFrame: index, outOf: total)
            let ca = interpolator.positions(at: u)
            let isRaw = interpolator.isRawFrame(u)
            let rawIndex = Swift.min(Int(u.rounded()), readouts.count - 1)
            let readout = readouts[rawIndex]

            // Contacts advance only on raw readouts, and only once per readout.
            var newContacts: [ContactEvent] = []
            if isRaw, rawIndex != lastRawFrameIndex {
                newContacts = contacts.update(caPositions: ca, residues: residues)
                lastRawFrameIndex = rawIndex
            }

            let rawAssignment = configuration.assigner.assign(caPositions: ca)
            let assignment = hysteresis.smooth(rawAssignment)

            let confidence = interpolatedConfidence(at: u)
            let metrics = Metrics.compute(caPositions: ca, residues: residues,
                                          confidence: confidence)

            // A CA-trace provider has no full backbone; build a placeholder residue whose
            // atoms are all the CA. Consumers that need real N, C and O check the bundle's
            // provenance rather than trusting these.
            let backbone: [BackboneResidue] = readout.backbone.map { residues in
                zip(residues, ca).map { original, position in
                    let shift = position - original.ca
                    return BackboneResidue(n: original.n + shift, ca: position,
                                           c: original.c + shift, o: original.o + shift)
                }
            } ?? ca.map { BackboneResidue(n: $0, ca: $0, c: $0, o: $0) }

            let frame = FoldFrame(
                index: index,
                recycle: readout.recycle,
                blockIndex: readout.blockIndex,
                backbone: backbone,
                pLDDT: confidence,
                secondaryStructure: assignment,
                newContacts: newContacts,
                radiusOfGyration: metrics.radiusOfGyration,
                meanPLDDT: metrics.meanConfidence,
                isInterpolated: !isRaw)
            index += 1
            return frame
        }

        /// Confidence interpolated linearly between the neighbouring raw readouts.
        ///
        /// Linear rather than Catmull-Rom deliberately: confidence is bounded (0 to 100 for
        /// pLDDT, 0 to 100 for denoising progress) and a spline overshoots at the ends,
        /// which would report a confidence above 100.
        func interpolatedConfidence(at u: Float) -> [Float] {
            guard readouts.count > 1 else { return readouts.first?.confidence ?? [] }
            let clamped = Swift.min(Swift.max(u, 0), Float(readouts.count - 1))
            let i = Swift.min(Int(clamped.rounded(.down)), readouts.count - 2)
            let t = clamped - Float(i)
            let a = readouts[i].confidence
            let b = readouts[i + 1].confidence
            guard a.count == b.count else { return a }
            return zip(a, b).map { $0 + ($1 - $0) * t }
        }
    }
}
