import Testing
import Foundation
@testable import FoldSync

/// PLAN.md Phase 5b: "Wrist haptics of the fold, the phone keeping the audio."
///
/// The wrist itself cannot be put in a test suite, so the decision of *when* it buzzes is a
/// value type with the clock passed in, and this is that decision.
@Suite("When the wrist buzzes")
struct WristHapticsTests {

    @Test("a burst of contacts is felt and a trickle is not")
    func onlyBursts() {
        var haptics = WristHaptics(minimumInterval: 0.35, burstThreshold: 3)
        #expect(haptics.contacts(1, at: 1) == nil)
        #expect(haptics.contacts(2, at: 2) == nil)
        #expect(haptics.contacts(3, at: 3) == .contact)
        #expect(haptics.contacts(0, at: 4) == nil)
    }

    /// Taptic transients closer together than about a fifth of a second run into one long
    /// buzz. A fold forms contacts several times a second, so without this the whole fold is
    /// one continuous vibration.
    @Test("two bursts inside the interval give one buzz")
    func rateLimited() {
        var haptics = WristHaptics(minimumInterval: 0.35, burstThreshold: 3)
        #expect(haptics.contacts(9, at: 10.0) == .contact)
        #expect(haptics.contacts(9, at: 10.2) == nil)
        #expect(haptics.contacts(9, at: 10.4) == .contact)
    }

    /// The subtle one, and the one that fails silently: if a suppressed event moved the clock,
    /// a continuous stream of contacts would push the window forward for ever and the wrist
    /// would buzz exactly once and then never again - which looks like the feature being off.
    @Test("a suppressed burst does not push the window forward")
    func suppressionDoesNotResetTheClock() {
        var haptics = WristHaptics(minimumInterval: 0.35, burstThreshold: 3)
        var felt = 0
        // Eleven readings a tenth of a second apart: a full second of contacts forming
        // continuously, which is what the middle of a fold actually looks like.
        var time = 0.0
        for step in 0...10 {
            time = Double(step) / 10
            if haptics.contacts(9, at: time) != nil { felt += 1 }
        }
        // At a 0.35 s floor that is three buzzes - at 0, 0.4 and 0.8 - and it is three
        // rather than one because a suppressed reading leaves the clock alone.
        #expect(felt == 3, "felt \(felt) buzzes in a second, not three")
    }

    @Test("the start of a fold is never suppressed")
    func startAlwaysFires() {
        var haptics = WristHaptics(minimumInterval: 5, burstThreshold: 3)
        #expect(haptics.contacts(9, at: 100) == .contact)
        // A second fold started immediately after the first: within the interval, and it must
        // still be felt or the wrist misses the start of every fold played back to back.
        #expect(haptics.began(at: 100.05) == .began)
    }

    /// The heaviest burst of contacts in a fold is the one immediately before it arrives, so
    /// the rate-limit window is almost always still open at the end. Rate limiting this would
    /// swallow the one cue the feature exists for, and only on the folds that end hardest.
    @Test("arrival is never suppressed by the burst that preceded it")
    func arrivalAlwaysFires() {
        var haptics = WristHaptics(minimumInterval: 0.35, burstThreshold: 3)
        #expect(haptics.contacts(40, at: 60.0) == .contact)
        #expect(haptics.finished(at: 60.01) == .finished)
    }

    /// A scrub backwards, or a new run on a clock that starts again. A `lastCueTime` in the
    /// future would otherwise lock the wrist out until the clock caught up with it.
    @Test("a clock that goes backwards does not lock the wrist out")
    func backwardsClock() {
        var haptics = WristHaptics(minimumInterval: 0.35, burstThreshold: 3)
        _ = haptics.contacts(9, at: 500)
        #expect(haptics.contacts(9, at: 3) == .contact)
    }

    @Test("reset starts the window again")
    func resetClearsTheWindow() {
        var haptics = WristHaptics(minimumInterval: 5, burstThreshold: 3)
        #expect(haptics.contacts(9, at: 0) == .contact)
        #expect(haptics.contacts(9, at: 1) == nil)
        haptics.reset()
        #expect(haptics.lastCueTime == nil)
        #expect(haptics.contacts(9, at: 1) == .contact)
    }

    /// A threshold of one is a legitimate setting for a slow trajectory, and it must not mean
    /// "every reading", including the readings with nothing in them.
    @Test("a reading with no contacts is never a burst, whatever the threshold")
    func zeroIsNeverABurst() {
        var haptics = WristHaptics(minimumInterval: 0, burstThreshold: 1)
        #expect(haptics.contacts(0, at: 1) == nil)
        #expect(haptics.contacts(1, at: 2) == .contact)
    }
}
