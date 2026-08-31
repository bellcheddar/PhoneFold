import Foundation
import Combine
import FoldCore
import FoldEngine
import FoldSync
#if canImport(GroupActivities)
import GroupActivities
#endif

/// PLAN.md Phase 5c's teaching mode: two or more people in the same fold.
///
/// **Nobody streams a trajectory.** A fold is megabytes of coordinates and none of it needs to
/// travel: every device already has the engines, and a fold is a deterministic function of the
/// protein, the engine and the seed. That is precisely the payload `FoldHandoff` was built to
/// carry for Phase 5a - "a description of what to fold, not the fold itself" - so the Phase 5a
/// design pays for itself a second time and there is one definition of what a fold *is*.
///
/// `canImport` rather than a platform test, and the difference is real: `GroupActivities` does
/// not exist on watchOS at all, so `canImport` is false there and the guard works. Contrast
/// `ActivityKit`, which *does* import on macOS and then marks every symbol unavailable.
@MainActor
final class FoldTogether: ObservableObject {

    @Published private(set) var state = SharePlaySession.State.unavailable
    /// What went wrong, when something did, said in words rather than swallowed.
    @Published private(set) var problem: String?

    /// Called when the far end sends a fold, so the app can start it.
    var onFold: ((FoldHandoff) -> Void)?
    /// Called when the far end sends a transport change.
    var onCommand: ((FoldRemote.Command) -> Void)?

    #if canImport(GroupActivities)
    private var session: GroupSession<Activity>?
    private var messenger: GroupSessionMessenger?
    private var tasks: Set<Task<Void, Never>> = []
    private var observers: Set<AnyCancellable> = []

    /// The activity itself.
    ///
    /// It carries the fold rather than being empty, so that someone joining late is joining
    /// *this* protein rather than an empty room they then have to be told about.
    struct Activity: GroupActivity {
        static let activityIdentifier = SharePlaySession.activityIdentifier
        var fold: FoldHandoff

        var metadata: GroupActivityMetadata {
            var metadata = GroupActivityMetadata()
            metadata.title = fold.subject
            metadata.subtitle = "Folding on \(fold.engine.displayName)"
            metadata.type = .generic
            return metadata
        }
    }

    init() {
        listen()
    }

    /// Watch for sessions this device is invited into.
    ///
    /// Started at launch rather than when a button is pressed: an invitation can arrive from
    /// the other end at any moment, and an app that only listens while its own share sheet is
    /// open can only ever be the one who started it.
    private func listen() {
        let task = Task { [weak self] in
            for await session in Activity.sessions() {
                await self?.join(session)
            }
        }
        tasks.insert(task)
    }

    /// Offer this fold to everyone on the call.
    func share(_ fold: FoldHandoff) async {
        problem = nil
        state = .waiting
        do {
            _ = try await Activity(fold: fold).activate()
        } catch {
            // Said, not swallowed. The commonest cause is no FaceTime call, and a button that
            // silently does nothing is indistinguishable from a broken one.
            problem = "\(error.localizedDescription)"
            state = .idle
        }
    }

    func leave() {
        session?.leave()
        session = nil
        messenger = nil
        state = .idle
    }

    private func join(_ session: GroupSession<Activity>) async {
        self.session = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger

        // Whoever joins gets the fold that is already running, from the activity itself, so a
        // latecomer is not looking at an empty stage waiting for the next message.
        onFold?(session.activity.fold)

        session.$activeParticipants
            .sink { [weak self] participants in
                self?.state = SharePlaySession.afterParticipantChange(
                    participants.count, isCallActive: true)
            }
            .store(in: &observers)

        session.$state
            .sink { [weak self] sessionState in
                if case .invalidated = sessionState {
                    self?.state = SharePlaySession.afterEnding(isCallActive: false)
                    self?.session = nil
                    self?.messenger = nil
                }
            }
            .store(in: &observers)

        let task = Task { [weak self] in
            for await (message, _) in messenger.messages(of: SharePlayMessage.self) {
                await self?.receive(message)
            }
        }
        tasks.insert(task)
        session.join()
    }

    private func receive(_ message: SharePlayMessage) {
        switch message {
        case .fold(let data):
            guard let fold = try? JSONDecoder().decode(FoldHandoff.self, from: data) else {
                return
            }
            onFold?(fold)
        case .command(let command):
            onCommand?(command)
        }
    }

    /// Tell the room something.
    ///
    /// **Failures are ignored on purpose.** A dropped transport message is one the presser will
    /// press again; an alert about it would be the app explaining its own plumbing in the
    /// middle of a lecture.
    func send(_ message: SharePlayMessage) {
        guard let messenger else { return }
        Task { try? await messenger.send(message) }
    }

    func send(_ fold: FoldHandoff) {
        guard let data = try? JSONEncoder().encode(fold) else { return }
        send(.fold(data))
    }

    deinit {
        for task in tasks { task.cancel() }
    }
    #else
    /// watchOS has no `GroupActivities` at all, and no business in a teaching session anyway:
    /// the wrist is a remote, and a remote is one person's.
    init() {}
    func share(_ fold: FoldHandoff) async {}
    func leave() {}
    func send(_ message: SharePlayMessage) {}
    func send(_ fold: FoldHandoff) {}
    #endif
}
