import Testing
import Foundation
import simd
@testable import FoldEngine
import FoldCore

/// Exactly one raw frame per readout, whatever the frame rate.
///
/// Contacts advance only on raw frames, so a readout that never gets one contributes nothing to
/// the score. This held by accident for a long time: an eighth of a second per readout at 60 fps
/// is exactly five output frames, so the interpolation parameter landed on integers. Pacing the
/// animation from the score made it 145.5 frames per readout and **2 readouts in 8 were marked**.
@Suite("Raw frame marking")
struct RawFrameCountTests {

    static func bundle(readouts: Int, residues n: Int = 12) -> TrajectoryBundle {
        let acids = (0..<n).map { _ in AminoAcid.alanine }
        let list = (0..<readouts).map { r -> TrajectoryReadout in
            let t = Float(r) / Float(Swift.max(readouts - 1, 1))
            let ca = (0..<n).map { i -> SIMD3<Float> in
                let a = Float(i) * 1.9
                let radius = 9 - 5 * t
                return SIMD3(radius * cos(a), radius * sin(a), Float(i) * 1.5)
            }
            return TrajectoryReadout(recycle: 0, blockIndex: r, caPositions: ca,
                                     confidence: (0..<n).map { _ in 40 + 50 * t })
        }
        return TrajectoryBundle(
            metadata: TrajectoryMetadata(
                name: "raw frame test", sequence: String(acids.map(\.code)),
                provenance: .testFixture, sourceModel: "none/test-fixture",
                blocksPerReadout: 1, recycles: 1,
                generated: "2026-08-31T00:00:00Z"),
            readouts: list)
    }

    @Test("every readout gets exactly one raw frame, at any frame rate")
    func everyReadoutIsMarked() async throws {
        let readouts = 8
        let provider = try SampleTrajectoryProvider(bundle: Self.bundle(readouts: readouts))

        // A whole-number ratio and several that are not. 2.42 s is what a gallery reference
        // gets once the animation is paced from the score, and it is the case that failed.
        let paces: [Float] = [1.0 / 12, 0.247, 2.42, 0.7333, 1.0 / 7]
        for seconds in paces {
            var frames: [FoldFrame] = []
            let sequence = FoldFrameSequence(provider: provider, configuration: .init(
                frameRate: 60, secondsPerRawFrame: seconds))
            for try await frame in sequence { frames.append(frame) }

            let raw = frames.filter { !$0.isInterpolated }
            #expect(raw.count == readouts,
                    "\(seconds) s per readout marked \(raw.count) of \(readouts)")
            // And each one belongs to a different readout, in order.
            #expect(raw.map(\.blockIndex) == Array(0..<readouts))
        }
    }

    @Test("contacts fire once per readout, not once per rendered frame")
    func contactsFireOncePerReadout() async throws {
        let provider = try SampleTrajectoryProvider(bundle: Self.bundle(readouts: 8))
        var frames: [FoldFrame] = []
        let sequence = FoldFrameSequence(provider: provider, configuration: .init(
            frameRate: 60, secondsPerRawFrame: 2.42))
        for try await frame in sequence { frames.append(frame) }

        // An interpolated frame never carries a contact: one contact becoming a burst of sixty
        // is the thing PLAN.md warns about, and it is what a raw-frame test that passed by
        // accident would have hidden.
        let quiet = frames.filter(\.isInterpolated).allSatisfy { $0.newContacts.isEmpty }
        #expect(quiet)
        #expect(frames.contains { !$0.newContacts.isEmpty }, "no contacts formed at all")
    }
}
