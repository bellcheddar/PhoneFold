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

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersion = ImmersiveSession.State.closed
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, immersion == .open {
                immersion = ImmersiveSession.afterSystemDismissal()
            }
        }
        .task {
            // PLAN's 5c gate asks that "the renderer runs in the Simulator from the sample
            // provider", and there is no way to press a button in the visionOS simulator from
            // outside. This opens the volume on the first gallery entry so the gate can see the
            // protein actually drawing rather than only the app launching.
            guard ProcessInfo.processInfo.environment["PHONEFOLD_VISION_AUTOSTART"] == "1",
                  let first = library.entries.first else { return }
            start(first)
            openWindow(id: PhoneFoldVisionApp.volume)
        }
    }

    private func start(_ entry: TrajectoryLibrary.Entry) {
        guard let provider = try? library.provider(for: entry) else { return }
        player.play(provider)
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
