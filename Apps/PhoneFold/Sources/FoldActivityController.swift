import Foundation
import Synchronization
import os
import FoldCore
#if os(iOS)
import ActivityKit
#endif

/// Starts, updates and ends the Live Activity for one run.
///
/// **Rate-limited, because ActivityKit is.** Playback publishes a frame sixty times a second and
/// the system budgets Live Activity updates well below that; pushing every frame gets updates
/// dropped and the banner freezes at whatever got through. So an update goes out only when the
/// progress has moved by a whole percent or the phase has changed, which is also about the most
/// a person reading a Lock Screen can perceive.
///
/// **Not `@MainActor`, and that is forced rather than chosen.** `ActivityKit.Activity` is a plain
/// non-Sendable class whose `update` and `end` are nonisolated and async. Held in a main-actor
/// property, it can never be passed to them - "sending main actor-isolated 'activity' to
/// nonisolated instance method 'update' risks causing data races" - and no amount of hopping
/// through `Task { }` helps, because the value itself carries the isolation. The activity
/// therefore lives outside any actor, behind a `Mutex` that makes the safety real rather than
/// asserted.
///
/// **The platform guard is `os(iOS)` and not `canImport(ActivityKit)`, which was measured.**
/// ActivityKit imports perfectly well on macOS - the module is there - and then every symbol in
/// it is marked unavailable, so `canImport` compiles the block and the build fails on eight
/// separate lines with "'Activity' is unavailable in macOS". `canImport` answers a question about
/// the module, not about the platform.
final class FoldActivityController: Sendable {

    /// Logged rather than silent, for the same reason the external display scene is: a Live
    /// Activity that never starts looks exactly like one the user dismissed, and from outside
    /// the app there is no way to tell whether it was ever requested.
    static let log = Logger(subsystem: "com.mdeller.phonefold", category: "LiveActivity")

    #if os(iOS)
    private struct Running {
        var activity: Activity<FoldActivityAttributes>?
        var lastPublished: FoldActivitySnapshot?
    }

    private let running = Mutex(Running())

    func begin(protein: String, engine: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.log.notice("live activities are not enabled; no banner for \(protein)")
            return
        }
        end()
        let state = FoldActivitySnapshot(phase: .folding, progress: 0)
        // Requested *inside* the lock rather than outside it. `Activity` is non-Sendable, so a
        // value created out here belongs to this task's isolation region and storing it into
        // the mutex is "'inout sending' parameter cannot be task-isolated at end of function".
        // Created in the closure, it is born in the mutex's region and never leaves it except
        // as a deliberate hand-off below.
        running.withLock { current in
            current.activity = try? Activity.request(
                attributes: FoldActivityAttributes(proteinName: protein, engineName: engine),
                content: ActivityContent(state: state, staleDate: nil))
            current.lastPublished = state
            // Hoisted out of the log call: the interpolation is an escaping autoclosure and
            // cannot capture the `inout` closure parameter.
            let started = current.activity != nil
            Self.log.notice("live activity for \(protein) on \(engine): \(started)")
        }
    }

    func update(_ state: FoldActivitySnapshot) {
        let target: Activity<FoldActivityAttributes>? = running.withLock { current in
            guard let activity = current.activity,
                  state.isWorthPublishing(after: current.lastPublished)
            else { return nil }
            current.lastPublished = state
            return activity
        }
        guard let target else { return }
        // A stale date twenty seconds out, so a run that dies without ending its activity - a
        // crash, a jetsam - shows as stale rather than as a fold that is still going.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20))
        Task { await target.update(content) }
    }

    func end() {
        let target = running.withLock { current -> Activity<FoldActivityAttributes>? in
            defer { current = Running() }
            return current.activity
        }
        guard let target else { return }
        Task { await target.end(nil, dismissalPolicy: .immediate) }
    }
    #else
    func begin(protein: String, engine: String) {}
    func update(_ state: FoldActivitySnapshot) {}
    func end() {}
    #endif
}
