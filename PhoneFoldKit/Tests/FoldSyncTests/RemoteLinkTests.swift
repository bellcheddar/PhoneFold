import Testing
import Foundation
import Synchronization
@testable import FoldSync

/// PLAN.md Phase 5b's machine gate: "connectivity handshake unit-tested with a mock session".
///
/// This is the mock session. `WCSession` is a system-owned singleton that will not activate
/// without a real pairing, so a design that talked to it directly could never meet this gate:
/// the protocol exists for that reason and not for tidiness.
@Suite("The phone and the Watch, over a mock session")
struct RemoteLinkTests {

    final class MockTransport: FoldRemote.Transport, @unchecked Sendable {
        private struct Log {
            var commands: [FoldRemote.Command] = []
            var cues: [FoldRemote.Cue] = []
            var states: [FoldRemote.State] = []
            var reachable = true
        }
        private let log = Mutex(Log())

        var isReachable: Bool { log.withLock { $0.reachable } }
        func setReachable(_ value: Bool) { log.withLock { $0.reachable = value } }

        func send(_ command: FoldRemote.Command) {
            log.withLock { $0.commands.append(command) }
        }
        func send(_ cue: FoldRemote.Cue) {
            log.withLock { $0.cues.append(cue) }
        }
        func update(_ state: FoldRemote.State) {
            log.withLock { $0.states.append(state) }
        }

        var commands: [FoldRemote.Command] { log.withLock { $0.commands } }
        var cues: [FoldRemote.Cue] { log.withLock { $0.cues } }
        var states: [FoldRemote.State] { log.withLock { $0.states } }
    }

    static func state(_ progress: Double, playing: Bool = true) -> FoldRemote.State {
        FoldRemote.State(title: "Trp-cage TC5b", isPlaying: playing, progress: progress,
                         meanConfidence: 88, styleID: "jazz")
    }

    // MARK: - The handshake

    /// The rule the whole link rests on: the phone is the source of truth, and whenever the
    /// link becomes reachable it sends its whole state. A Watch that was relaunched has no idea
    /// what happened while it was away and must never guess.
    @Test("becoming reachable makes the host re-send its state unprompted")
    func handshakeOnReconnect() {
        let transport = MockTransport()
        let host = RemoteLink(role: .host, transport: transport)
        host.publish(Self.state(0.3))
        #expect(transport.states.count == 1)

        transport.setReachable(false)
        host.reachabilityChanged(to: false)
        // Published while away: dropped, not queued. A minute-old snapshot delivered on
        // reconnection would show a fold that has already finished.
        host.publish(Self.state(0.6))
        #expect(transport.states.count == 1, "nothing is sent while unreachable")

        transport.setReachable(true)
        host.reachabilityChanged(to: true)
        #expect(transport.states.count == 2, "the handshake re-sends on reconnection")
        #expect(transport.states.last?.progress == 0.6, "and it sends the *current* state")
    }

    /// The system reports reachability repeatedly, not only on change.
    @Test("a repeated reachable report does not re-send")
    func onlyOnTransition() {
        let transport = MockTransport()
        let host = RemoteLink(role: .host, transport: transport)
        host.publish(Self.state(0.5))
        host.reachabilityChanged(to: true)
        let after = transport.states.count
        host.reachabilityChanged(to: true)
        host.reachabilityChanged(to: true)
        #expect(transport.states.count == after, "only a transition re-sends")
    }

    @Test("a host with nothing to say sends nothing on reconnection")
    func nothingToResend() {
        let transport = MockTransport()
        let host = RemoteLink(role: .host, transport: transport)
        host.reachabilityChanged(to: true)
        #expect(transport.states.isEmpty)
    }

    // MARK: - Which end does what

    @Test("commands go from the wrist and state comes from the phone")
    func rolesAreOneDirectional() {
        let hostTransport = MockTransport()
        let remoteTransport = MockTransport()
        let received = Mutex<[FoldRemote.Command]>([])

        let host = RemoteLink(role: .host, transport: hostTransport,
                              onCommand: { command in received.withLock { $0.append(command) } })
        let remote = RemoteLink(role: .remote, transport: remoteTransport)

        remote.send(.pause)
        #expect(remoteTransport.commands == [.pause])
        // A host publishing is the only way state moves; a remote publishing does nothing.
        remote.publish(Self.state(0.9))
        #expect(remoteTransport.states.isEmpty, "a remote is not a source of truth")
        // And a host does not send commands.
        host.send(.play)
        #expect(hostTransport.commands.isEmpty)

        host.received(payload: FoldRemote.Command.pause.payload)
        #expect(received.withLock { $0 } == [.pause])
    }

    /// A Watch telling the phone what the phone is doing is a loop waiting to happen.
    @Test("a host ignores state and a remote ignores commands")
    func wrongDirectionIsIgnored() {
        let transport = MockTransport()
        let stateSeen = Mutex(0)
        let commandSeen = Mutex(0)

        let host = RemoteLink(role: .host, transport: transport,
                              onCommand: { _ in commandSeen.withLock { $0 += 1 } },
                              onState: { _ in stateSeen.withLock { $0 += 1 } })
        host.received(payload: Self.state(0.4).payload)
        #expect(stateSeen.withLock { $0 } == 0, "a host does not accept state")

        let remote = RemoteLink(role: .remote, transport: transport,
                                onCommand: { _ in commandSeen.withLock { $0 += 1 } },
                                onState: { _ in stateSeen.withLock { $0 += 1 } })
        remote.received(payload: FoldRemote.Command.play.payload)
        #expect(commandSeen.withLock { $0 } == 0, "a remote does not accept commands")

        remote.received(payload: Self.state(0.4).payload)
        #expect(stateSeen.withLock { $0 } == 1)
        #expect(remote.state?.progress == 0.4)
    }

    // MARK: - The wire

    @Test("every command survives the dictionary WatchConnectivity carries")
    func commandsRoundTrip() {
        let commands: [FoldRemote.Command] = [
            .play, .pause, .scrub(0.42), .style("surf"),
            .colourMode("hydrophobicity"), .fold(galleryID: "gfp"),
        ]
        for command in commands {
            #expect(FoldRemote.Command.from(payload: command.payload) == command,
                    "\(command) did not survive")
        }
    }

    @Test("state survives the trip, with and without a confidence")
    func stateRoundTrips() {
        let full = Self.state(0.7)
        #expect(FoldRemote.State.from(payload: full.payload) == full)
        var noConfidence = full
        noConfidence.meanConfidence = nil
        #expect(FoldRemote.State.from(payload: noConfidence.payload) == noConfidence)
    }

    /// A Watch newer than the phone sends commands the phone has no case for. Treating an
    /// unknown command as a default would make an unfamiliar button do something arbitrary.
    @Test("an unknown command is ignored, never defaulted")
    func unknownCommand() {
        #expect(FoldRemote.Command.from(payload: ["command": "teleport"]) == nil)
        #expect(FoldRemote.Command.from(payload: [:]) == nil)
        #expect(FoldRemote.Command.from(payload: ["command": "scrub"]) == nil,
                "a scrub with no value is not a scrub")
        #expect(FoldRemote.Command.from(payload: ["command": "style"]) == nil)
    }

    /// The Crown overshoots at both ends of its travel. Refusing those messages would make the
    /// timeline stick rather than stop.
    @Test("a scrub past either end is clamped, not refused")
    func scrubIsClamped() {
        #expect(FoldRemote.Command.from(payload: ["command": "scrub", "value": 1.4])
                == .scrub(1))
        #expect(FoldRemote.Command.from(payload: ["command": "scrub", "value": -0.3])
                == .scrub(0))
    }

    // MARK: - Cues

    /// The rule that makes three payload kinds safe on two delegate callbacks: each decoder
    /// refuses the other two rather than guessing. Without it a state would arrive on the
    /// wrist as a buzz, or a scrub as one.
    @Test("a cue, a command and a state cannot be mistaken for each other")
    func payloadKindsAreDistinct() {
        for cue in FoldRemote.Cue.allCases {
            #expect(FoldRemote.Cue.from(payload: cue.payload) == cue)
            #expect(FoldRemote.Command.from(payload: cue.payload) == nil)
            #expect(FoldRemote.State.from(payload: cue.payload) == nil)
        }
        #expect(FoldRemote.Cue.from(payload: Self.state(0.5).payload) == nil)
        #expect(FoldRemote.Cue.from(payload: FoldRemote.Command.pause.payload) == nil)
        #expect(FoldRemote.Cue.from(payload: ["cue": "explode"]) == nil)
    }

    @Test("cues go from the phone to the wrist and never the other way")
    func cuesAreHostToRemote() {
        let hostTransport = MockTransport()
        let remoteTransport = MockTransport()
        let host = RemoteLink(role: .host, transport: hostTransport)
        let remote = RemoteLink(role: .remote, transport: remoteTransport)

        host.cue(.contact)
        #expect(hostTransport.cues == [.contact])
        remote.cue(.contact)
        #expect(remoteTransport.cues.isEmpty, "a remote does not mark moments")
    }

    /// Unlike the state, a cue is a thing that happened at a moment. There is nothing to catch
    /// up on, and a buzz on reconnection would be for a contact that formed a minute ago.
    @Test("a cue is dropped when the wrist is away and is not re-sent on reconnection")
    func cuesAreNotResent() {
        let transport = MockTransport()
        let host = RemoteLink(role: .host, transport: transport)
        transport.setReachable(false)
        host.reachabilityChanged(to: false)
        host.cue(.contact)
        #expect(transport.cues.isEmpty)

        transport.setReachable(true)
        host.reachabilityChanged(to: true)
        #expect(transport.cues.isEmpty, "the handshake re-sends state, never a moment")
    }

    @Test("the wrist feels a cue and does not mistake it for a state")
    func remoteReceivesCue() {
        let transport = MockTransport()
        let felt = Mutex<[FoldRemote.Cue]>([])
        let stateSeen = Mutex(0)
        let remote = RemoteLink(role: .remote, transport: transport,
                                onState: { _ in stateSeen.withLock { $0 += 1 } },
                                onCue: { cue in felt.withLock { $0.append(cue) } })
        remote.received(payload: FoldRemote.Cue.finished.payload)
        #expect(felt.withLock { $0 } == [.finished])
        #expect(stateSeen.withLock { $0 } == 0)
        #expect(remote.state == nil, "a cue is not a state and must not become one")
    }

    @Test("a host ignores a cue arriving from the wrist")
    func hostIgnoresCue() {
        let transport = MockTransport()
        let commandSeen = Mutex(0)
        let host = RemoteLink(role: .host, transport: transport,
                              onCommand: { _ in commandSeen.withLock { $0 += 1 } })
        host.received(payload: FoldRemote.Cue.began.payload)
        #expect(commandSeen.withLock { $0 } == 0)
    }

    // MARK: - What is worth sending

    /// A fold publishes sixty states a second and the wrist can use about one.
    @Test("progress below a whole per cent is not worth a message")
    func progressIsFiltered() {
        let first = Self.state(0.500)
        #expect(first.isWorthSending(after: nil), "the first state always goes")
        #expect(!Self.state(0.5005).isWorthSending(after: first))
        #expect(Self.state(0.52).isWorthSending(after: first))
    }

    /// And the other half: a style change is one message and must never be filtered as a
    /// small change, because its progress did not move at all.
    @Test("anything that is not progress goes immediately")
    func nonProgressChangesAlwaysSend() {
        let first = Self.state(0.5)
        var restyled = first
        restyled.styleID = "surf"
        #expect(restyled.isWorthSending(after: first))

        var paused = first
        paused.isPlaying = false
        #expect(paused.isWorthSending(after: first))

        var renamed = first
        renamed.title = "Ubiquitin"
        #expect(renamed.isWorthSending(after: first))
    }

    @Test("a state missing a required field is refused rather than half-built")
    func incompleteState() {
        var payload = Self.state(0.5).payload
        payload.removeValue(forKey: "progress")
        #expect(FoldRemote.State.from(payload: payload) == nil)
    }
}
