import Foundation

/// Whether the concert hall is open, and how it got that way.
///
/// PLAN.md Phase 5c's machine gate: "immersive space lifecycle unit-tested". The lifecycle is a
/// state machine and lives here so it can be tested; the SwiftUI call that drives it stays in
/// the app, because testing `openImmersiveSpace` would be testing SwiftUI.
///
/// **The whole point is that opening can fail and the system can close it behind your back.**
/// `openImmersiveSpace` returns `.error` or `.userCancelled` as readily as `.opened`, and
/// visionOS closes a space when the user takes off the headset, presses the Digital Crown, or
/// opens someone else's immersive app. A flag set optimistically leaves a button saying "leave
/// the concert hall" for a room that is not there, and the next press dismisses nothing.
public enum ImmersiveSession {

    public enum State: Sendable, Equatable {
        case closed
        /// Asked for, not yet answered. The button must not offer to open it twice.
        case opening
        case open
        /// Asked to close, waiting. Also not a moment to accept another request.
        case closing

        /// Whether a request to open should be sent at all.
        public var canOpen: Bool { self == .closed }
        /// Whether a request to close should be sent at all.
        public var canClose: Bool { self == .open }
        /// Whether the interface should be waiting rather than offering anything.
        public var isSettling: Bool { self == .opening || self == .closing }
    }

    /// What `openImmersiveSpace` answered, without SwiftUI's type.
    public enum OpenResult: Sendable, Equatable {
        case opened
        case userCancelled
        case error
    }

    /// The state after an open request is answered.
    ///
    /// Only `.opened` becomes open. Both of the others go back to closed, because a space that
    /// failed to open is exactly as absent as one never asked for, and pretending otherwise
    /// leaves the only visible affordance pointing the wrong way.
    public static func afterOpening(_ result: OpenResult) -> State {
        switch result {
        case .opened: .open
        case .userCancelled, .error: .closed
        }
    }

    /// The state after the system closed the space without being asked.
    ///
    /// visionOS does this whenever the headset comes off or another immersive app takes over,
    /// and it arrives as a scene-phase change rather than as a reply to anything. Treating it
    /// as anything other than closed is how the app and the room come to disagree.
    public static func afterSystemDismissal() -> State { .closed }
}
