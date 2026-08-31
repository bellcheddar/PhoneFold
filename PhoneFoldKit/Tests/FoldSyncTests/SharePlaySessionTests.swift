import Testing
import Foundation
@testable import FoldSync

/// PLAN.md Phase 5c: "SharePlay: two or more people in the same fold."
///
/// Two devices are the only way to see whether it *works*. What can be settled here is the
/// state machine, which has the same failure mode as the immersive space: the system ends a
/// session behind your back, and a flag set optimistically leaves the app offering to leave a
/// room that has emptied.
@Suite("Two people in the same fold")
struct SharePlaySessionTests {

    @Test("no call means nothing to offer, whatever the participant count says")
    func noCall() {
        #expect(SharePlaySession.afterParticipantChange(3, isCallActive: false) == .unavailable)
        #expect(SharePlaySession.afterEnding(isCallActive: false) == .unavailable)
    }

    /// The one that matters. The count drops to nothing when the last person leaves, and
    /// treating that as "still sharing" leaves a button offering to leave an empty room.
    @Test("nobody in the session is not a session")
    func emptySessionIsIdle() {
        #expect(SharePlaySession.afterParticipantChange(0, isCallActive: true) == .idle)
    }

    @Test("one participant is a session, because it is you waiting for someone")
    func oneIsASession() {
        let state = SharePlaySession.afterParticipantChange(1, isCallActive: true)
        #expect(state == .joined(participants: 1))
        #expect(state.isSharing)
        #expect(state.participants == 1)
    }

    @Test("the interface offers exactly one thing at a time")
    func affordances() {
        #expect(SharePlaySession.State.idle.canStart)
        #expect(!SharePlaySession.State.unavailable.canStart)
        #expect(!SharePlaySession.State.waiting.canStart, "one offer at a time")
        #expect(SharePlaySession.State.waiting.isSettling)
        #expect(!SharePlaySession.State.joined(participants: 2).canStart)
        #expect(SharePlaySession.State.joined(participants: 2).isSharing)
        #expect(!SharePlaySession.State.idle.isSharing)
    }

    @Test("a session that ends during a live call goes back to being offerable")
    func endingDuringACall() {
        #expect(SharePlaySession.afterEnding(isCallActive: true) == .idle)
    }

    // MARK: - The wire

    @Test("both kinds of message survive the trip and cannot be confused")
    func messagesRoundTrip() throws {
        let payload = Data("{\"subject\":\"ubiquitin\"}".utf8)
        let messages: [SharePlayMessage] = [
            .fold(payload), .command(.pause), .command(.scrub(0.4)),
            .command(.style("surf")), .command(.fold(galleryID: "gfp")),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(SharePlayMessage.self, from: data) == message)
        }
    }

    /// The two cases carry the same word in different senses - a `.fold` message is a new
    /// protein, a `.command(.fold(galleryID:))` is the wrist asking for one - and they must
    /// not decode into each other.
    @Test("a fold payload and a fold command stay distinct")
    func foldIsNotFoldCommand() throws {
        let payload = SharePlayMessage.fold(Data("x".utf8))
        let command = SharePlayMessage.command(.fold(galleryID: "x"))
        #expect(payload != command)
        let encoded = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(SharePlayMessage.self, from: encoded) != command)
    }
}
