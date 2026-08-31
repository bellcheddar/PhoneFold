import Testing
import Foundation
@testable import FoldCore

@Suite("The Live Activity's publishing rule")
struct ActivityReportTests {

    @Test("The first snapshot always publishes")
    func firstAlwaysPublishes() {
        let snapshot = FoldActivitySnapshot(phase: .folding, progress: 0)
        #expect(snapshot.isWorthPublishing(after: nil))
    }

    @Test("A sub-percent step is swallowed")
    func smallStepSwallowed() {
        let previous = FoldActivitySnapshot(phase: .playing, progress: 0.500)
        let next = FoldActivitySnapshot(phase: .playing, progress: 0.5099)
        #expect(!next.isWorthPublishing(after: previous))
    }

    @Test("A whole percent publishes")
    func wholePercentPublishes() {
        let previous = FoldActivitySnapshot(phase: .playing, progress: 0.50)
        let next = FoldActivitySnapshot(phase: .playing, progress: 0.51)
        #expect(next.isWorthPublishing(after: previous))
    }

    /// The regression this rule exists to prevent: playback drives sixty snapshots a second, and
    /// the system's update budget is nowhere near that. At one frame in sixty of a 45-second
    /// piece, publishing everything would be 2,700 updates.
    @Test("A 45-second fold at 60 fps publishes about a hundred times, not thousands")
    func rateOverAWholeFold() {
        let frames = 45 * 60
        var published = 0
        var last: FoldActivitySnapshot?
        for frame in 0...frames {
            let snapshot = FoldActivitySnapshot(phase: .playing,
                                                progress: Double(frame) / Double(frames))
            if snapshot.isWorthPublishing(after: last) {
                published += 1
                last = snapshot
            }
        }
        // 99, and not the 100 or 101 the arithmetic suggests: the step is 1/2700 and a whole
        // percent is 27 of them, but the comparison is against an accumulated Double and a
        // couple of intervals land a hair under 0.01. Measured rather than derived, because
        // the derived number is wrong.
        #expect(published == 99)
        #expect(frames == 2700)
    }

    /// A phase change at the same fraction is the most informative update of the run, and a
    /// rule that only watched progress would swallow it.
    @Test("A phase change publishes even with no progress at all")
    func phaseChangeAlwaysPublishes() {
        let previous = FoldActivitySnapshot(phase: .folding, progress: 1.0)
        let next = FoldActivitySnapshot(phase: .playing, progress: 1.0)
        #expect(next.isWorthPublishing(after: previous))
    }

    /// The extension decodes what the app encodes, so the shape has to survive a round trip.
    @Test("A snapshot round-trips through JSON")
    func roundTrips() throws {
        let snapshot = FoldActivitySnapshot(phase: .playing, progress: 0.42, recycle: 2,
                                            meanConfidence: 78.5, confidenceLabel: "pLDDT")
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(FoldActivitySnapshot.self, from: data)
        #expect(back == snapshot)
    }
}
