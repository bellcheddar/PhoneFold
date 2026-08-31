import Foundation
import SwiftUI
import Combine
import FoldCore
import FoldRender
import FoldSync

/// The one fold the app is playing, owned above any scene.
///
/// **Shared because there can be two windows.** PLAN.md Phase 4 asks for a dedicated external
/// display scene: "on connection, render a clean full-bleed stage with no controls... The phone
/// becomes the control surface." Two scenes showing one fold means the fold cannot belong to
/// either of them, and a `@StateObject` inside the stage view is owned by that view.
///
/// **`shared` on the phone, one per window on the Mac, and the difference is deliberate.** On
/// iOS there is genuinely one fold: the external display shows *that* protein rather than
/// another, and the scene delegate that builds the external window has no environment to read
/// from, so it needs somewhere to reach. On macOS a second window that showed the same protein
/// would not be multi-window in any useful sense - PLAN.md Phase 5a wants two proteins side by
/// side - so PhoneFold Studio gives each window its own.
@MainActor
final class PhoneFoldModel: ObservableObject {
    static let shared = PhoneFoldModel()

    let library = TrajectoryLibrary()
    let player = FoldPlayer()
    let runner = FoldRunner()

    /// Whether a dedicated external display scene is showing this fold.
    ///
    /// The phone's own stage reads it so it can say where the picture went: without that, a
    /// presenter who has just connected a projector has no confirmation on the device in their
    /// hand that anything reached it.
    @Published var isOnExternalDisplay = false

    /// The Lock Screen banner. Driven from here rather than from a view, because a fold runs
    /// whether or not anything is on screen - which is the entire point of a Live Activity -
    /// and a `.onChange` in `StageView` would stop reporting the moment the app was backgrounded
    /// and the view stopped updating.
    let activity = FoldActivityController()

    private var observers: Set<AnyCancellable> = []

    /// The Watch, when there is one. PLAN.md Phase 5b: the wrist is a remote, so the phone is
    /// the host and the only source of truth.
    ///
    /// **`canImport` here, and `os(iOS)` for ActivityKit, and the difference is real.**
    /// WatchConnectivity does not exist on macOS at all, so `canImport` is false and the guard
    /// works. ActivityKit *does* import on macOS and then marks every symbol unavailable, which
    /// is why that one needs an explicit platform test. Reaching for the same idiom in both
    /// places is how the second one took eight compile errors to notice.
    private var watchLink: RemoteLink?
    #if canImport(WatchConnectivity)
    private var watchTransport: WatchConnectivityTransport?
    #endif

    /// A fold the wrist asked for, which only `StageView` can actually start: it owns the
    /// gallery selection and the accession field, and a model reaching into those would be two
    /// things deciding what is playing.
    @Published var requestedGalleryID: String?

    /// The last state sent to the wrist, for the same rate limit the Live Activity uses.
    private var lastPublishedToWatch: FoldRemote.State?

    init() {
        observeForActivity()
    }

    /// Mirror the run into the Live Activity.
    ///
    /// Two sources, because a run has two halves: the runner while the model computes, then the
    /// player while the piece plays. The controller rate-limits, so subscribing to a sixty-a-
    /// second progress publisher here is deliberate rather than careless.
    private func observeForActivity() {
        runner.$state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .fetching(let accession):
                    activity.begin(protein: accession, engine: runner.engine.displayName)
                    activity.update(FoldActivitySnapshot(phase: .fetching, progress: 0))
                case .folding(let progress):
                    if progress <= 0 {
                        // The runner's own subject, not the player's title: the player has no
                        // provider yet at progress zero and would answer "PhoneFold".
                        activity.begin(protein: runner.subject,
                                       engine: runner.engine.displayName)
                    }
                    activity.update(FoldActivitySnapshot(phase: .folding, progress: progress))
                case .failed:
                    activity.end()
                case .idle:
                    break
                }
            }
            .store(in: &observers)

        player.$progress
            .sink { [weak self] progress in
                guard let self, player.isPlaying else { return }
                let sample = player.history.samples.last
                activity.update(FoldActivitySnapshot(
                    phase: .playing,
                    progress: progress,
                    // A single-recycle fold reports nothing rather than "recycle 1", which
                    // would be a number that never changes taking up a line.
                    recycle: (sample?.recycle).flatMap { $0 > 0 ? $0 : nil },
                    meanConfidence: sample.map { Double($0.meanConfidence) },
                    confidenceLabel: player.confidenceSource.displayName))
            }
            .store(in: &observers)

        player.$isPlaying
            .sink { [weak self] isPlaying in
                // Ended rather than left stale: a banner that says a fold is playing after the
                // music has stopped is worse than no banner.
                if !isPlaying { self?.activity.end() }
            }
            .store(in: &observers)
    }
}
