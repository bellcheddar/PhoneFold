import Testing
import Foundation
@testable import FoldSync

/// PLAN.md Phase 5b's machine gate: "complication timeline entries generated correctly."
@Suite("Complication timeline")
struct FoldComplicationTests {

    static func state(playing: Bool, progress: Double, confidence: Double?) -> FoldRemote.State {
        FoldRemote.State(title: "Trp-cage TC5b", isPlaying: playing, progress: progress,
                         meanConfidence: confidence)
    }

    /// The entry that matters most, because a complication cannot ask. Without it a fold from
    /// this morning is still on the face at six with a ring that reads as live.
    @Test("the timeline carries a stale entry, dated when it becomes true")
    func staleEntryIsScheduled() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = FoldComplication.timeline(
            from: Self.state(playing: true, progress: 0.4, confidence: 80), now: now)

        #expect(entries.count == 2)
        #expect(entries[0].date == now)
        #expect(!entries[0].isStale)
        #expect(entries[1].isStale)
        #expect(entries[1].date == now.addingTimeInterval(FoldComplication.freshness))
        #expect(entries[1].ringFraction == 0)
        #expect(entries[1].inlineText.contains("no recent fold"))
    }

    @Test("with nothing ever heard, the only entry is the stale one")
    func nothingHeard() {
        let entries = FoldComplication.timeline(from: nil)
        #expect(entries.count == 1)
        #expect(entries[0].isStale)
        #expect(entries[0].shortText == "-")
    }

    /// A ring showing progress after the fold ends sits permanently full and says nothing; a
    /// ring showing confidence before there is any starts full and falls, which reads as the
    /// fold getting worse.
    @Test("the ring shows progress while folding and confidence once it has finished")
    func ringMeaningSwitches() {
        let playing = FoldComplication.timeline(
            from: Self.state(playing: true, progress: 0.25, confidence: 90))[0]
        #expect(abs(playing.ringFraction - 0.25) < 0.001)
        #expect(playing.shortText == "25%")

        let finished = FoldComplication.timeline(
            from: Self.state(playing: false, progress: 1, confidence: 88))[0]
        #expect(abs(finished.ringFraction - 0.88) < 0.001)
        #expect(finished.shortText == "88")
    }

    @Test("a confidence outside 0 to 100 cannot overfill or invert the ring")
    func ringIsClamped() {
        let high = FoldComplication.timeline(
            from: Self.state(playing: false, progress: 1, confidence: 140))[0]
        #expect(high.ringFraction == 1)
        let low = FoldComplication.timeline(
            from: Self.state(playing: false, progress: 1, confidence: -5))[0]
        #expect(low.ringFraction == 0)
    }

    @Test("a finished fold with no confidence falls back to progress rather than an empty ring")
    func noConfidence() {
        let entry = FoldComplication.timeline(
            from: Self.state(playing: false, progress: 1, confidence: nil))[0]
        #expect(entry.ringFraction == 1)
    }

    @Test("the inline text names the protein and says which number it is showing")
    func inlineText() {
        let playing = FoldComplication.timeline(
            from: Self.state(playing: true, progress: 0.5, confidence: 80))[0]
        #expect(playing.inlineText == "Trp-cage TC5b 50%")

        let finished = FoldComplication.timeline(
            from: Self.state(playing: false, progress: 1, confidence: 80))[0]
        #expect(finished.inlineText.contains("pLDDT 80"))
    }

    /// The label travels with the reading, because a generated backbone's confidence is not
    /// pLDDT and calling it that on a watch face is the same claim as calling it that anywhere.
    @Test("the confidence label is carried rather than assumed")
    func labelIsCarried() {
        var state = Self.state(playing: false, progress: 1, confidence: 70)
        state.confidenceLabel = "denoising"
        let entry = FoldComplication.timeline(from: state)[0]
        #expect(entry.inlineText.contains("denoising 70"))
    }
}
