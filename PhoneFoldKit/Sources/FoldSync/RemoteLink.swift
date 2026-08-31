import Foundation
import Synchronization

/// The two ends of the phone-and-Watch link, and the handshake between them.
///
/// PLAN.md Phase 5b's machine gate: "connectivity handshake unit-tested with a mock session".
///
/// **The handshake exists because reachability is not a state, it is an event that keeps
/// happening.** A Watch app is launched, backgrounded, relaunched, and moves in and out of range
/// dozens of times in a session. Whichever side comes back has no idea what happened while it
/// was away, so the rule is simple and one-directional: **the phone is the source of truth, and
/// whenever the link becomes reachable the phone sends its whole state.** The Watch never
/// guesses and never keeps a state it was not told.
public final class RemoteLink: Sendable {

    /// Which end of the link this is.
    public enum Role: Sendable, Equatable {
        /// The phone: owns the fold, answers commands, publishes state.
        case host
        /// The Watch: sends commands, displays what it is told.
        case remote
    }

    private struct Storage {
        var state: FoldRemote.State?
        var wasReachable = false
    }

    public let role: Role
    private let transport: any FoldRemote.Transport
    private let storage = Mutex(Storage())

    /// Called on the host when the wrist asks for something.
    private let onCommand: (@Sendable (FoldRemote.Command) -> Void)?
    /// Called on the remote when the phone says what it is doing.
    private let onState: (@Sendable (FoldRemote.State) -> Void)?
    /// Called on the remote when the phone marks a moment worth feeling.
    private let onCue: (@Sendable (FoldRemote.Cue) -> Void)?

    public init(role: Role, transport: any FoldRemote.Transport,
                onCommand: (@Sendable (FoldRemote.Command) -> Void)? = nil,
                onState: (@Sendable (FoldRemote.State) -> Void)? = nil,
                onCue: (@Sendable (FoldRemote.Cue) -> Void)? = nil) {
        self.role = role
        self.transport = transport
        self.onCommand = onCommand
        self.onState = onState
        self.onCue = onCue
    }

    /// The last state the host published, or the remote was told.
    public var state: FoldRemote.State? { storage.withLock { $0.state } }

    // MARK: - The host side

    /// Publish what the fold is doing. Only the host does this.
    ///
    /// **Dropped when unreachable rather than queued.** A state is a snapshot of now; delivering
    /// a minute-old one when the Watch comes back would show a fold that has already finished.
    /// The handshake re-sends the current state on reconnection, which is what makes dropping
    /// safe.
    public func publish(_ state: FoldRemote.State) {
        guard role == .host else { return }
        storage.withLock { $0.state = state }
        guard transport.isReachable else { return }
        transport.update(state)
    }

    /// Mark a moment for the wrist to feel. Only the host does this.
    ///
    /// **Dropped when unreachable, and never re-sent.** A cue is a thing that happened at a
    /// moment; unlike the state there is nothing to catch up on, and a buzz delivered when the
    /// Watch comes back would be for a contact that formed a minute ago. The handshake
    /// deliberately re-sends state and deliberately does not re-send this.
    public func cue(_ cue: FoldRemote.Cue) {
        guard role == .host, transport.isReachable else { return }
        transport.send(cue)
    }

    // MARK: - The remote side

    /// Ask the phone for something. Only the remote does this.
    public func send(_ command: FoldRemote.Command) {
        guard role == .remote else { return }
        transport.send(command)
    }

    // MARK: - The handshake

    /// Tell the link that reachability changed.
    ///
    /// Called by the real transport when `WCSession` says so, and by a test directly. The host
    /// re-publishes on every **transition** into reachable, not on every report: the system
    /// delivers reachability repeatedly and re-sending the same state each time would fill the
    /// channel with duplicates of something that has not changed.
    public func reachabilityChanged(to reachable: Bool) {
        let shouldResend = storage.withLock { storage -> Bool in
            defer { storage.wasReachable = reachable }
            return reachable && !storage.wasReachable
        }
        guard shouldResend, role == .host, let state = storage.withLock({ $0.state }) else {
            return
        }
        transport.update(state)
    }

    /// Something arrived from the other end.
    public func received(payload: [String: Any]) {
        switch role {
        case .host:
            // A host takes commands and ignores state: a Watch telling the phone what the
            // phone is doing is a loop waiting to happen.
            guard let command = FoldRemote.Command.from(payload: payload) else { return }
            onCommand?(command)
        case .remote:
            // A cue first, and it is tested that a state cannot be read as one: all three
            // kinds arrive through the same two delegate callbacks, and each decoder is
            // written to refuse the others rather than to guess.
            if let cue = FoldRemote.Cue.from(payload: payload) {
                onCue?(cue)
                return
            }
            guard let state = FoldRemote.State.from(payload: payload) else { return }
            storage.withLock { $0.state = state }
            onState?(state)
        }
    }
}
