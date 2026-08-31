import SwiftUI
import FoldEngine
import FoldSync

/// The control window: what to fold, and where to put it.
///
/// A plain window rather than an ornament, because these are decisions made occasionally and
/// then left alone, while the ornament carries what is touched while watching.
struct VisionControlView: View {
    @ObservedObject private var library = PhoneFoldModel.shared.library
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @ObservedObject private var runner = PhoneFoldModel.shared.runner
    @ObservedObject private var model = PhoneFoldModel.shared
    @ObservedObject private var together = PhoneFoldModel.shared.together

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersion = ImmersiveSession.State.closed
    /// The gallery entry this device started, so it can say what it is playing.
    @State private var started: TrajectoryLibrary.Entry?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PhoneFold")
                .font(.largeTitle.weight(.semibold))

            // The disclosure travels to every surface. A protein at room scale is the most
            // convincing this app ever looks, which is exactly when it matters most that it
            // says what it is not.
            if let disclosure = player.disclosure {
                Text(disclosure)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Open the volume") {
                    openWindow(id: PhoneFoldVisionApp.volume)
                }
                Button(immersion == .open ? "Leave the concert hall"
                                          : "Enter the concert hall") {
                    Task { await toggleImmersion() }
                }
                // Offered only when there is something to offer: while a request is in flight
                // the answer is not known, and a second press would ask again for a room that
                // may be about to appear.
                .disabled(immersion.isSettling)
            }

            // PLAN.md Phase 5c: "SharePlay: two or more people in the same fold. This is the
            // teaching mode." What travels is what to fold, never the fold - see FoldTogether.
            HStack(spacing: 10) {
                Button(model.together.state.isSharing ? "Stop sharing" : "Fold together") {
                    if model.together.state.isSharing {
                        model.together.leave()
                    } else if let payload = handoffPayload {
                        model.share(payload)
                    }
                }
                .disabled(model.together.state.isSettling || handoffPayload == nil)

                if model.together.state.isSharing {
                    Text("\(model.together.state.participants) in the room")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Said rather than swallowed: the commonest reason this does nothing is that
                // there is no FaceTime call, and a button that silently fails is a broken one.
                if let problem = model.together.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }

            // Only while there is a room to be inside. An ornament would have been the tidier
            // home for this, and an ImmersiveSpace has no window to hang one from: the first
            // build put it there, it compiled, it ran, and the control simply was not in the
            // room. The window stays open in the shared space beside it, so it goes here.
            if immersion == .open {
                WalkIntoTheCoreControls()
            }

            Text("Gallery").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(library.entries) { entry in
                        Button {
                            start(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text(entry.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(24)
        // visionOS closes the space when the headset comes off or another immersive app takes
        // over, and tells nobody directly. Without this the button would still offer to leave a
        // room that has already gone.
        .onChange(of: model.requestedHandoff) { _, requested in
            guard let requested else { return }
            model.requestedHandoff = nil
            adopt(requested)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, immersion == .open {
                immersion = ImmersiveSession.afterSystemDismissal()
            }
        }
        .task {
            // PLAN's 5c gate asks that "the renderer runs in the Simulator from the sample
            // provider", and there is no way to press a button in the visionOS simulator from
            // outside - `simctl` has no input injection for any platform. This starts the first
            // gallery entry and opens whichever scene was asked for, so the gate can see the
            // protein actually drawing rather than only the app launching.
            //
            //     SIMCTL_CHILD_PHONEFOLD_VISION_AUTOSTART=immersive \
            //     SIMCTL_CHILD_PHONEFOLD_VISION_WALK_IN=1 xcrun simctl launch <udid> <id>
            //
            // `1` still means the volume, which is what it meant when only the volume existed.
            let requested = ProcessInfo.processInfo.environment["PHONEFOLD_VISION_AUTOSTART"]
            guard let requested, let first = library.entries.first else { return }
            start(first)
            switch requested {
            case "immersive": await toggleImmersion()
            case "1", "volume": openWindow(id: PhoneFoldVisionApp.volume)
            default: break
            }
        }
    }

    private func start(_ entry: TrajectoryLibrary.Entry) {
        guard let provider = try? library.provider(for: entry) else { return }
        started = entry
        player.play(provider)
    }

    /// What this device would tell the room about the fold it is playing.
    ///
    /// The gallery only, on this surface: the visionOS control window has no accession field
    /// and no generative seed of its own, so naming one would be describing a fold this app
    /// cannot start.
    private var handoffPayload: FoldHandoff? {
        guard let started else { return nil }
        return FoldHandoff(subject: player.title, galleryID: started.id,
                           engine: runner.engine, styleID: player.styleID,
                           progress: player.progress)
    }

    /// Somebody else in the room started a fold.
    private func adopt(_ fold: FoldHandoff) {
        player.styleID = fold.styleID
        guard let galleryID = fold.galleryID,
              let entry = library.entries.first(where: { $0.id == galleryID }) else { return }
        start(entry)
    }

    /// Open or close the immersive space, through the state machine `FoldSync` tests.
    ///
    /// The result is read rather than assumed: `openImmersiveSpace` returns `.error` or
    /// `.userCancelled` as readily as `.opened`, and a flag set optimistically leaves a button
    /// offering to leave a room that is not there.
    private func toggleImmersion() async {
        if immersion.canClose {
            immersion = .closing
            await dismissImmersiveSpace()
            immersion = .closed
            return
        }
        guard immersion.canOpen else { return }
        immersion = .opening
        let result: ImmersiveSession.OpenResult =
            switch await openImmersiveSpace(id: PhoneFoldVisionApp.immersive) {
            case .opened: .opened
            case .userCancelled: .userCancelled
            case .error: .error
            @unknown default: .error
            }
        immersion = ImmersiveSession.afterOpening(result)
    }
}
