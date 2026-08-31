import SwiftUI
import FoldCore

/// PhoneFold on Vision Pro: the theatre.
///
/// PLAN.md Phase 5c. Two places the protein can be, and they are genuinely different rather
/// than one being a bigger version of the other:
///
/// - **A volume**, which sits on a desk in the shared space beside other windows, so a fold can
///   run during a meeting without taking the room.
/// - **An immersive space**, the concert hall, which takes the room deliberately.
///
/// The stage itself is the phone's, compiled here with its own entry point, exactly as
/// PhoneFold Studio does. What changes is the chrome: PLAN asks for "ornament-based transport
/// rather than an overlay, so the stage stays clean", and a control column borrowed from a
/// phone would be the opposite of that.
@main
struct PhoneFoldVisionApp: App {

    static let volume = "volume"
    static let immersive = "immersive"

    var body: some Scene {
        WindowGroup {
            VisionControlView()
        }
        .defaultSize(width: 460, height: 620)

        // A volume, not a window: the protein is an object with a size in the room rather than
        // a picture on a pane, and it is the difference between something on your desk and
        // something behind glass.
        WindowGroup(id: Self.volume) {
            VisionStageView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 0.6, height: 0.6, depth: 0.6, in: .meters)

        ImmersiveSpace(id: Self.immersive) {
            VisionImmersiveView()
        }
        // Mixed rather than full: PLAN wants the protein "at room scale, folding around you",
        // and passthrough keeps the room there to be at the scale of.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
