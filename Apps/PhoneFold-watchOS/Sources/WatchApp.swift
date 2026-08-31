import SwiftUI
import FoldCore
import FoldSync

/// PhoneFold on the wrist: the conductor.
///
/// PLAN.md Phase 5b: "It runs no inference and should never try to." Nothing here folds
/// anything. The phone owns the fold; this sends commands and displays what it is told.
///
/// **Three screens, and that is a ceiling rather than a starting point.** PLAN: "Keep the UI to
/// three screens maximum. Watch apps die of ambition." Now Playing, the two pickers, and Fold of
/// the Day. Anything else belongs on the phone.
@main
struct PhoneFoldWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
    }
}

/// What the wrist knows, which is only ever what the phone last said.
@MainActor
final class WatchModel: ObservableObject {

    @Published private(set) var state: FoldRemote.State?
    @Published private(set) var isReachable = false

    private var link: RemoteLink?
    private var transport: WatchConnectivityTransport?

    init() {
        guard let transport = WatchConnectivityTransport() else { return }
        let link = RemoteLink(role: .remote, transport: transport,
                              onState: { [weak self] state in
                                  Task { @MainActor in self?.apply(state) }
                              })
        transport.attach(link)
        self.transport = transport
        self.link = link
        refreshReachability()
    }

    private func apply(_ state: FoldRemote.State) {
        self.state = state
        refreshReachability()
        // Leave it where the complication can find it. That is a separate process WidgetKit
        // wakes on its own schedule, long after this app has gone, so it cannot be told - it
        // has to be able to look.
        FoldComplicationStore.save(state)
    }

    func refreshReachability() {
        isReachable = transport?.isReachable ?? false
    }

    func send(_ command: FoldRemote.Command) {
        link?.send(command)
        // **Not applied locally.** The wrist shows what the phone says, and nothing else. A
        // button that flips its own state optimistically will disagree with the phone the
        // moment a command does not arrive, and the disagreement is invisible.
        refreshReachability()
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        TabView {
            NowPlayingView()
            VoicingView()
            FoldOfTheDayView()
        }
        .tabViewStyle(.verticalPage)
    }
}
