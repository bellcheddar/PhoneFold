import Foundation
import SwiftUI

/// The one fold the app is playing, owned above any scene.
///
/// **Shared because there can be two windows.** PLAN.md Phase 4 asks for a dedicated external
/// display scene: "on connection, render a clean full-bleed stage with no controls... The phone
/// becomes the control surface." Two scenes showing one fold means the fold cannot belong to
/// either of them, and a `@StateObject` inside the stage view is owned by that view.
///
/// A singleton rather than an injected graph, because there is genuinely one: PhoneFold plays
/// one protein at a time, and the external display shows *that* protein rather than another.
/// The scene delegate that builds the external window has no environment to read from, so it
/// needs somewhere to reach.
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

    private init() {}
}
