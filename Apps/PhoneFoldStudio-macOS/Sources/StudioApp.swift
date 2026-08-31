import SwiftUI
import AppKit
import FoldCore

/// PhoneFold Studio: the same stage, on a Mac, with a menu bar and more than one window.
///
/// PLAN.md Phase 5a: "Native SwiftUI for macOS, **not** Catalyst. Multi-window, full menu bar,
/// keyboard shortcuts."
///
/// **The stage is shared with the phone rather than copied.** This target compiles
/// `Apps/PhoneFold/Sources` and adds its own entry point, so `StageView` has exactly one
/// definition. A second copy would be free to drift from the first with nothing to notice it
/// had - and the whole reason `PhoneFoldKit` is platform-clean is so that a surface is a
/// presentation layer rather than a fork.
///
/// The name is not a consistency slip. The App Store name is PhoneFold; the Mac app is PhoneFold
/// Studio. A protein folding on a phone is the origin story, and the Mac is the workstation that
/// grew out of it.
@main
struct PhoneFoldStudioApp: App {
    var body: some Scene {
        WindowGroup("PhoneFold Studio", id: Self.stageWindow) {
            StudioWindow()
        }
        .defaultSize(width: 1440, height: 900)
        .commands { StudioCommands() }
    }

    /// Named so `openWindow` can ask for another one by identifier rather than by guessing.
    static let stageWindow = "stage"
}

/// One window, and the fold that belongs to it.
///
/// The `@StateObject` is what makes multi-window mean something here: each window owns its own
/// `PhoneFoldModel`, so two windows are two proteins folding side by side rather than two views
/// of one. The phone deliberately does the opposite - see `PhoneFoldModel`.
struct StudioWindow: View {
    @StateObject private var model = PhoneFoldModel()

    var body: some View {
        StageView(model: model)
            .frame(minWidth: 900, minHeight: 640)
    }
}

/// The menu bar.
///
/// **What is here is what a Mac user will reach for without looking.** Every one of these is
/// already a control on the stage; the menu exists because on a Mac a feature that has no menu
/// item and no key equivalent is a feature that a keyboard user cannot find. The stage's own
/// controls stay - this is a second route to them, not a replacement.
struct StudioCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replaces the stock "New Item", which would otherwise sit in the File menu doing
        // nothing. A new window is a second fold, which is the whole point of multi-window here:
        // two proteins side by side.
        CommandGroup(replacing: .newItem) {
            Button("New Fold Window") {
                openWindow(id: PhoneFoldStudioApp.stageWindow)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About PhoneFold Studio") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .applicationName: "PhoneFold Studio",
                    .credits: NSAttributedString(
                        string: Onboarding.disclaimer,
                        attributes: [.font: NSFont.systemFont(ofSize: 11)]),
                ])
            }
        }

        // PLAN.md: "Marc will be asked about this and the app should answer first." A Mac user
        // looking for what the app claims looks in the menu bar, so the disclosure is reachable
        // from there as well as from the stage's own About.
        CommandGroup(after: .help) {
            Button("What PhoneFold Is Not") {
                let alert = NSAlert()
                alert.messageText = "What PhoneFold is not"
                alert.informativeText = Onboarding.disclaimer
                alert.runModal()
            }
        }
    }
}
