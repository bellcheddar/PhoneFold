#if os(iOS)
import UIKit
import SwiftUI
import os

/// Puts the fold on a projector.
///
/// PLAN.md Phase 4: "Dedicated external display scene (`UIScene` role
/// `.windowExternalDisplayNonInteractive`): on connection, render a clean full-bleed stage with no
/// controls, larger type, protein name and confidence readout. The phone becomes the control
/// surface. This is what makes it work in a lecture theatre."
///
/// **The fold is not restarted, moved or duplicated when a display connects.** It lives in
/// `PhoneFoldModel`, above both scenes, so a display arriving mid-fold builds a second window onto
/// the same running player and a display leaving destroys that window and nothing else. The
/// alternative - handing the fold to whichever scene is frontmost - is what makes AirPlay in a
/// lecture theatre restart the animation at the worst possible moment.
///
/// **A second renderer, not a mirror.** The external window hosts its own `FoldCanvas`, which
/// means its own RealityKit view drawing at the display's resolution and aspect ratio rather than
/// a scaled copy of a phone screen with a letterbox. If the room mirrors the phone instead of
/// using this scene - AirPlay's "Mirror" rather than an app that supports a separate display -
/// nothing here runs and the phone's own stage appears on the wall, letterboxed. That is the
/// fallback, and it is the system's rather than the app's.
/// The explicit Objective-C name matters: the scene manifest names this class as a string, and
/// a Swift class otherwise carries a mangled runtime name that no plist entry will match.
@objc(ExternalDisplaySceneDelegate)
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    /// Logged rather than silent, because this feature is invisible when it fails. A projector
    /// that shows nothing looks exactly like a projector that was never asked, and the only way
    /// to tell them apart from outside the app is whether the scene was ever offered.
    static let log = Logger(subsystem: "com.mdeller.phonefold", category: "ExternalDisplay")

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        Self.log.notice("external display scene connecting: \(scene.session.role.rawValue)")
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(
            rootView: PresentationView(player: PhoneFoldModel.shared.player))
        // Nothing on this screen can be tapped - the scene role is non-interactive - so the
        // window is shown rather than made key. Taking key status away from the phone would
        // leave the control surface unable to receive a keyboard.
        window.isHidden = false
        self.window = window
        PhoneFoldModel.shared.isOnExternalDisplay = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        PhoneFoldModel.shared.isOnExternalDisplay = false
    }
}

/// The one thing a SwiftUI-lifecycle app cannot express: which delegate handles which scene role.
///
/// `App` has no hook for `configurationForConnecting`, so the external display scene needs a
/// `UIApplicationDelegate` to route it. Every other role is answered with exactly what UIKit
/// would have built by default - a configuration named for the role, no delegate class - so
/// SwiftUI's own scene handling is untouched.
final class PhoneFoldAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        ExternalDisplaySceneDelegate.log.notice(
            "scene configuration requested for role \(session.role.rawValue)")
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}
#endif
