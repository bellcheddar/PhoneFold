import Foundation
import SwiftUI
import Combine
import FoldCore
import FoldRender
import FoldEngine
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

    /// PLAN.md Phase 5c's teaching mode. See `FoldTogether`.
    let together = FoldTogether()

    /// A fold somebody else in the session is playing, for the same reason and by the same
    /// route as `requestedGalleryID`: the view owns the selection, so the model asks.
    @Published var requestedHandoff: FoldHandoff?

    /// What this device is playing, as the other end would need it. Kept by the stage, which
    /// owns the selection, so the Handoff advertisement and the SharePlay offer describe the
    /// same fold rather than two guesses at it.
    @Published var currentHandoff: FoldHandoff?

    /// True while a change arrived from somewhere else, so it is not sent straight back.
    private var isApplyingRemoteChange = false

    /// The last state sent to the wrist, for the same rate limit the Live Activity uses.
    private var lastPublishedToWatch: FoldRemote.State?

    /// Which moments of the fold the wrist is told to feel. See `WristHaptics`.
    private var haptics = WristHaptics()
    /// The last history sample the haptics have already considered, so a reading is never
    /// counted twice: `history` republishes the whole buffer ten times a second.
    private var lastHapticFrame: Int?
    /// So the arrival cue fires once rather than on every publication after the fold ends.
    private var hasSentArrival = false
    /// `@Published` republishes on every set, not only on a change, so the start of a fold is
    /// detected as a transition rather than as a value.
    private var wasPlayingForHaptics = false

    /// Ends a scrub the wrist started but never finished. See `handle(_:)`.
    private var scrubTimeout: Task<Void, Never>?

    init() {
        observeForActivity()
        connectWatch()
        connectSharePlay()
    }

    // MARK: - The room

    private func connectSharePlay() {
        together.onFold = { [weak self] fold in
            Task { @MainActor in self?.requestedHandoff = fold }
        }
        together.onCommand = { [weak self] command in
            Task { @MainActor in
                guard let self else { return }
                // Applied, not echoed. Two devices bouncing the same pause off each other is
                // the classic way a shared session locks up.
                self.isApplyingRemoteChange = true
                self.handle(command)
                self.isApplyingRemoteChange = false
            }
        }
        observeForSharePlay()
    }

    /// Send the choices that are choices.
    ///
    /// **Style and colour mode and the transport, and nothing else.** Progress is deliberately
    /// not synchronised: every device computes its own fold from the same protein, engine and
    /// seed, so they agree on *what* but not on exactly where they are in it - two headsets
    /// fold at different speeds. Frame-locking them is a real design question about what
    /// "together" should mean in a lecture, and it needs a headset and Marc's judgement rather
    /// than a guess. It is in `BLOCKERS.md`.
    private func observeForSharePlay() {
        player.$styleID
            .sink { [weak self] id in self?.broadcast(.style(id)) }
            .store(in: &observers)
        player.$colourMode
            .sink { [weak self] mode in self?.broadcast(.colourMode(mode.rawValue)) }
            .store(in: &observers)
        player.$isPlaying
            .sink { [weak self] isPlaying in self?.broadcast(isPlaying ? .play : .pause) }
            .store(in: &observers)
    }

    private func broadcast(_ command: FoldRemote.Command) {
        guard together.state.isSharing, !isApplyingRemoteChange else { return }
        together.send(.command(command))
    }

    /// Offer whatever this device is playing to everyone on the call.
    func shareCurrentFold() {
        guard let fold = currentHandoff else { return }
        share(fold)
    }

    /// Offer the fold this device is playing to everyone on the call.
    func share(_ fold: FoldHandoff) {
        Task { await together.share(fold) }
        together.send(fold)
    }

    // MARK: - The wrist

    /// Bring up the phone's half of the link.
    ///
    /// **This was the missing half.** `watchLink` and `watchTransport` were declared with the
    /// comment above them and never constructed, so the phone never activated its session:
    /// the Watch app came up, showed "not reachable" for ever, its buttons sent commands into
    /// a session with no host, and the complication had nothing to store because the state it
    /// stores only ever arrives from the phone. Every part of 5b existed except the line that
    /// starts it.
    private func connectWatch() {
        #if canImport(WatchConnectivity)
        guard let transport = WatchConnectivityTransport() else { return }
        let link = RemoteLink(role: .host, transport: transport,
                              onCommand: { [weak self] command in
                                  // Off the WatchConnectivity delegate queue and onto the main
                                  // actor, because everything a command touches - the player,
                                  // the gallery selection - lives there.
                                  Task { @MainActor in self?.handle(command) }
                              })
        transport.attach(link)
        watchTransport = transport
        watchLink = link
        observeForWatch()
        #endif
    }

    /// Do what the wrist asked.
    private func handle(_ command: FoldRemote.Command) {
        switch command {
        case .play: player.resume()
        case .pause: player.pause()
        case .scrub(let value):
            player.scrub(to: value)
            armScrubTimeout()
        case .style(let id):
            // Ignored rather than defaulted if the phone has no such style, for the same
            // reason an unknown command is ignored: a Watch newer than the phone.
            guard player.styles[id] != nil else { return }
            player.styleID = id
        case .colourMode(let mode):
            guard let mode = ColourMode(rawValue: mode) else { return }
            player.colourMode = mode
        case .fold(let id):
            // Not started here: `StageView` owns the gallery selection and the accession
            // field, and a model reaching into those would be two things deciding what plays.
            requestedGalleryID = id
        }
    }

    /// Hand the stage back to the live fold when the Crown stops.
    ///
    /// **A timeout on the phone rather than an "I have finished scrubbing" message from the
    /// wrist**, because that message can be lost: `sendMessage` is dropped outright when the
    /// other device is not reachable, and a Watch that goes out of range mid-scrub would leave
    /// the phone holding one frozen frame with no way back short of relaunching. A timeout
    /// cannot be lost. The same argument is why `StageCamera` closes an abandoned drag on its
    /// own clock rather than trusting `onEnded`.
    private func armScrubTimeout() {
        scrubTimeout?.cancel()
        scrubTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.player.endScrub() }
        }
    }

    /// Tell the wrist what the fold is doing.
    ///
    /// Subscribed to the sixty-a-second publishers deliberately, and filtered by
    /// `isWorthSending` rather than by a timer: a style change has to go immediately and a
    /// progress tick of a thousandth never has to go at all.
    private func observeForWatch() {
        Publishers.Merge4(
            player.$progress.map { _ in () },
            player.$isPlaying.map { _ in () },
            player.$styleID.map { _ in () },
            player.$colourMode.map { _ in () }
        )
        .sink { [weak self] in self?.publishToWatch() }
        .store(in: &observers)

        // The moments, from the same history the HUD reads. Ten publications a second, and
        // `WristHaptics` decides which of them are worth a buzz.
        player.$history
            .sink { [weak self] history in self?.markMoments(in: history) }
            .store(in: &observers)

        player.$isPlaying
            .sink { [weak self] isPlaying in
                guard let self, isPlaying, !wasPlayingForHaptics else {
                    self?.wasPlayingForHaptics = isPlaying
                    return
                }
                wasPlayingForHaptics = true
                haptics.reset()
                lastHapticFrame = nil
                hasSentArrival = false
                watchLink?.cue(haptics.began(at: Date.timeIntervalSinceReferenceDate))
            }
            .store(in: &observers)
    }

    /// Tell the wrist about the moment the newest frame is, if it is one.
    ///
    /// **`history.latest`, never `history.samples.last`.** The retained series is decimated as
    /// a fold lengthens - the stride doubles each time the buffer fills - so a count taken
    /// from it would quietly represent fewer and fewer frames as the fold went on, and the
    /// burst threshold would be measuring something different at the end than at the start.
    /// `latest` is the newest frame whether or not the decimation gate kept it.
    ///
    /// The threshold is therefore per frame, which is what `newContacts` is: contacts formed
    /// between one frame and the one before it.
    private func markMoments(in history: FoldHistory) {
        guard let watchLink, let newest = history.latest else { return }
        guard newest.frameIndex != lastHapticFrame else { return }
        lastHapticFrame = newest.frameIndex
        let now = Date.timeIntervalSinceReferenceDate
        if let cue = haptics.contacts(newest.newContacts, at: now) { watchLink.cue(cue) }
        if newest.progress >= 0.999, !hasSentArrival {
            hasSentArrival = true
            watchLink.cue(haptics.finished(at: now))
        }
    }

    private func publishToWatch() {
        guard let watchLink else { return }
        let sample = player.history.samples.last
        let state = FoldRemote.State(
            title: player.title,
            isPlaying: player.isPlaying,
            progress: player.progress,
            meanConfidence: sample.map { Double($0.meanConfidence) },
            confidenceLabel: player.confidenceSource.displayName,
            styleID: player.styleID,
            colourMode: player.colourMode.rawValue,
            // Sent rather than known: the Watch depends on neither FoldAudio nor FoldRender,
            // so the only way it can offer the right five styles is to be told them.
            styles: player.styles.mapValues(\.name),
            colourModes: Dictionary(uniqueKeysWithValues:
                ColourMode.allCases.map { ($0.rawValue, $0.displayName) }))
        guard state.isWorthSending(after: lastPublishedToWatch) else { return }
        lastPublishedToWatch = state
        watchLink.publish(state)
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
