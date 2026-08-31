import Foundation

/// Two or more people in the same fold.
///
/// PLAN.md Phase 5c: "**SharePlay:** two or more people in the same fold. This is the teaching
/// mode, and the reason a department might buy it."
///
/// **Nobody streams a trajectory.** A fold is megabytes of coordinates and it does not need to
/// travel: every device already has the engine, and a fold is a deterministic function of the
/// protein, the engine and the seed - which is exactly the payload Handoff was already built to
/// carry, for exactly the same reason. So a session sends *what to fold*, and every headset in
/// the room computes the same protein at its own resolution. The Phase 5a design pays for
/// itself twice.
///
/// The state machine lives here, with `ImmersiveSession`, and for the same reason: joining can
/// fail, and the system can end a session behind your back when the FaceTime call ends. A flag
/// set optimistically leaves a button offering to leave a room that has already emptied.
public enum SharePlaySession {

    /// The activity two people join. Declared here so the app and any future extension agree.
    public static let activityIdentifier = "com.mdeller.phonefold.together"

    public enum State: Sendable, Equatable {
        /// No FaceTime call, or the platform has no SharePlay at all.
        case unavailable
        /// A call is up and nothing has been started.
        case idle
        /// Offered, waiting for the other end. `GroupActivity.activate()` returns before
        /// anyone has joined.
        case waiting
        /// At least this device is in a session.
        case joined(participants: Int)

        public var isSharing: Bool {
            if case .joined = self { return true }
            return false
        }
        /// Whether an offer should be made at all.
        public var canStart: Bool { self == .idle }
        /// Whether the interface should be waiting rather than offering anything.
        public var isSettling: Bool { self == .waiting }

        /// How many people are in it, including this device.
        public var participants: Int {
            if case .joined(let count) = self { return count }
            return 0
        }
    }

    /// The state after the system reports how many people are in the session.
    ///
    /// **Zero participants is not a session.** `GroupSession` reports its active participants
    /// and the count drops to nothing when the last person leaves; treating that as "still
    /// sharing" leaves the app offering to leave a room that has emptied. One participant is
    /// a session: it is this device, waiting for someone.
    public static func afterParticipantChange(_ count: Int, isCallActive: Bool) -> State {
        guard isCallActive else { return .unavailable }
        return count > 0 ? .joined(participants: count) : .idle
    }

    /// The state after the session ended, for any reason.
    ///
    /// The call ending, the other person leaving, the app being backgrounded: all the same
    /// answer. The reason is not something the interface can act on differently.
    public static func afterEnding(isCallActive: Bool) -> State {
        isCallActive ? .idle : .unavailable
    }
}

/// What a session says, once it is up.
///
/// **The fold rides as encoded bytes rather than as a typed payload**, because `FoldHandoff`
/// lives in `FoldEngine` and `FoldSync` must not depend on it: the Watch links against
/// `FoldSync` and has no business carrying an inference engine to receive a message it will
/// never send. The app owns both and does the encoding, which is one line at each end.
public enum SharePlayMessage: Codable, Sendable, Equatable {
    /// A new fold: `FoldHandoff`, JSON-encoded.
    case fold(Data)
    /// A transport or presentation change, in the vocabulary the Watch already speaks.
    ///
    /// Reused rather than reinvented. A third vocabulary for the same six verbs would be a
    /// third place to add a seventh.
    case command(FoldRemote.Command)
}
