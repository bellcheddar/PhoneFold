import Testing
@testable import FoldSync

/// PLAN.md Phase 5c's machine gate: "immersive space lifecycle unit-tested".
@Suite("Immersive space lifecycle")
struct ImmersiveSessionTests {

    /// The failure this exists to prevent: a button that says "leave the concert hall" for a
    /// room that never opened, whose next press dismisses nothing.
    @Test("only an actual open counts as open")
    func onlyOpenedIsOpen() {
        #expect(ImmersiveSession.afterOpening(.opened) == .open)
        #expect(ImmersiveSession.afterOpening(.userCancelled) == .closed)
        #expect(ImmersiveSession.afterOpening(.error) == .closed)
    }

    /// visionOS closes the space when the headset comes off or another immersive app takes
    /// over, and says so through a scene-phase change rather than a reply.
    @Test("a dismissal the app did not ask for still leaves it closed")
    func systemDismissal() {
        #expect(ImmersiveSession.afterSystemDismissal() == .closed)
    }

    @Test("neither request is offered twice while one is in flight")
    func settlingStatesOfferNothing() {
        for state: ImmersiveSession.State in [.opening, .closing] {
            #expect(!state.canOpen, "\(state) must not offer to open")
            #expect(!state.canClose, "\(state) must not offer to close")
            #expect(state.isSettling)
        }
    }

    @Test("closed offers opening, open offers closing, and never the reverse")
    func settledStatesOfferOneThing() {
        #expect(ImmersiveSession.State.closed.canOpen)
        #expect(!ImmersiveSession.State.closed.canClose)
        #expect(ImmersiveSession.State.open.canClose)
        #expect(!ImmersiveSession.State.open.canOpen)
        #expect(!ImmersiveSession.State.closed.isSettling)
        #expect(!ImmersiveSession.State.open.isSettling)
    }

    /// A whole round trip, including the one that fails, because the interesting property is
    /// that a failed open leaves the app exactly where it started rather than one step along.
    @Test("a failed open leaves the app able to try again")
    func failedOpenIsRecoverable() {
        var state = ImmersiveSession.State.closed
        #expect(state.canOpen)
        state = .opening
        state = ImmersiveSession.afterOpening(.error)
        #expect(state == .closed)
        #expect(state.canOpen, "a failed open must not lock the door")

        state = .opening
        state = ImmersiveSession.afterOpening(.opened)
        #expect(state == .open)
        state = .closing
        state = ImmersiveSession.afterSystemDismissal()
        #expect(state == .closed)
    }
}
