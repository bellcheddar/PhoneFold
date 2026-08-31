import Foundation

/// When the wrist should buzz, and when it should stay still.
///
/// PLAN.md Phase 5b: "Wrist haptics of the fold, the phone keeping the audio."
///
/// **The phone decides, not the Watch.** The Watch is told the fold's *state* through
/// `updateApplicationContext`, which the system coalesces on purpose - only the newest survives
/// - so a stream of moments cannot arrive that way at all: a hundred contacts forming would be
/// delivered as one state saying "some contacts have formed by now". Events therefore travel as
/// messages, and the choice of which moments deserve one is made on the side that can see every
/// frame.
///
/// **And the rate limit has to be on the sending side.** A fold forms contacts several times a
/// second and `WKInterfaceDevice.play` queues rather than drops: an unfiltered stream arrives as
/// one continuous buzz that outlasts the fold, which is not a rhythm, it is a fault. Filtering
/// on the Watch would still have paid for every message.
///
/// A value type with a clock passed in, so all of this is testable without a wrist.
public struct WristHaptics: Sendable, Equatable {

    /// The shortest gap between two buzzes.
    ///
    /// A third of a second. Taptic transients below about a fifth of a second run together into
    /// one long buzz rather than reading as separate events, and the fold's own rhythm - the
    /// thing the haptics are for - is exactly what that would destroy.
    public var minimumInterval: TimeInterval

    /// How many contacts forming in one reading count as a moment worth feeling.
    ///
    /// Ones and twos happen continuously through a fold and mean very little; a burst is the
    /// core packing, which is the moment worth putting on someone's wrist.
    public var burstThreshold: Int

    /// When the last cue was sent, on the caller's clock.
    public private(set) var lastCueTime: TimeInterval?

    public init(minimumInterval: TimeInterval = 0.35, burstThreshold: Int = 3) {
        self.minimumInterval = minimumInterval
        self.burstThreshold = burstThreshold
    }

    /// The fold started.
    ///
    /// Never rate limited, and it resets the clock: it is the first thing that happens, and if
    /// the previous fold's last buzz could suppress it the wrist would silently miss the start
    /// of every fold played back to back.
    public mutating func began(at time: TimeInterval) -> FoldRemote.Cue {
        lastCueTime = time
        return .began
    }

    /// A reading's worth of newly formed contacts.
    ///
    /// A clock that has gone backwards - a scrub, or a new run on a clock that restarts - is
    /// treated as a fresh window rather than as an enormous gap, so the wrist is never locked
    /// out waiting for a time that has already passed.
    public mutating func contacts(_ count: Int, at time: TimeInterval) -> FoldRemote.Cue? {
        guard count >= burstThreshold else { return nil }
        if let last = lastCueTime, time >= last, time - last < minimumInterval {
            // **Suppressed without touching the clock.** Moving it here would restart the
            // window on every rejected event, and a fold that forms contacts continuously
            // would then never buzz at all - the failure that looks like the feature is off.
            return nil
        }
        lastCueTime = time
        return .contact
    }

    /// The fold arrived.
    ///
    /// **Never rate limited either, and this is the case that matters.** The heaviest burst of
    /// contacts in a fold is the one immediately before it arrives, so the interval is almost
    /// always still open when the fold finishes: rate limiting this would swallow precisely the
    /// cue the whole feature exists for, and only on the folds that end most emphatically.
    public mutating func finished(at time: TimeInterval) -> FoldRemote.Cue {
        lastCueTime = time
        return .finished
    }

    /// Start again: a new fold, or a scrub backwards.
    ///
    /// Called on any clock that has gone backwards as well as on a new run. A monotonic
    /// assumption is not safe here - the caller's clock is whatever the app had to hand, and a
    /// `lastCueTime` in the future would lock the wrist out until it caught up.
    public mutating func reset() {
        lastCueTime = nil
    }
}
