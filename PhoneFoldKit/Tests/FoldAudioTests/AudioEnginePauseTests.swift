import Testing
import Foundation
@testable import FoldAudio

/// Pause, tested where the design actually rests.
///
/// PLAN.md Phase 5b lists "play, pause" among what the wrist asks for, and the app had no pause:
/// it played a fold through. The implementation leans on one claim - that pausing the audio
/// engine freezes `audioTime`, and since the conductor derives its clock from `audioTime` the
/// score stops advancing without a second timebase to keep in step. That claim is what these
/// check, because if it is false the whole arrangement is wrong rather than slightly off.
@Suite("Pausing the audio engine", .serialized)
struct AudioEnginePauseTests {

    @Test("pause stops the engine without tearing it down, and resume brings it back")
    func pauseThenResume() throws {
        let engine = FoldAudioEngine(style: try SonifierTests.style, residueCount: 20)
        try engine.start()
        #expect(engine.isRunning)

        engine.pause()
        #expect(!engine.isRunning)

        try engine.resume()
        #expect(engine.isRunning, "resume restarts the same graph rather than a new one")
        engine.stop()
    }

    /// The load-bearing claim. If the clock kept running while paused, the score would race
    /// ahead in silence and resume somewhere else entirely.
    @Test("the audio clock does not advance while paused")
    func clockFreezes() async throws {
        let engine = FoldAudioEngine(style: try SonifierTests.style, residueCount: 20)
        try engine.start()
        // Let the engine actually render something, or there is no clock to speak of.
        try await Task.sleep(for: .milliseconds(300))
        guard let running = engine.audioTime else {
            // A machine with no output device cannot answer this; say so rather than pass.
            Issue.record("the engine reported no audio time while running")
            engine.stop()
            return
        }

        engine.pause()
        let atPause = engine.audioTime
        try await Task.sleep(for: .milliseconds(400))
        let later = engine.audioTime

        if let atPause, let later {
            let drift = later - atPause
            #expect(drift < 0.05, "the clock advanced across a 0.4 s pause")
        }
        #expect(running > 0)

        try engine.resume()
        try await Task.sleep(for: .milliseconds(300))
        if let resumed = engine.audioTime, let atPause {
            #expect(resumed > atPause, "the clock moves again once resumed")
        }
        engine.stop()
    }

    @Test("pausing something already paused, or resuming something running, is harmless")
    func idempotent() throws {
        let engine = FoldAudioEngine(style: try SonifierTests.style, residueCount: 20)
        try engine.start()
        engine.pause()
        engine.pause()
        #expect(!engine.isRunning)
        try engine.resume()
        try engine.resume()
        #expect(engine.isRunning)
        engine.stop()
    }

    @Test("pausing an engine that never started does nothing")
    func pauseBeforeStart() throws {
        let engine = FoldAudioEngine(style: try SonifierTests.style, residueCount: 20)
        engine.pause()
        #expect(!engine.isRunning)
    }
}
