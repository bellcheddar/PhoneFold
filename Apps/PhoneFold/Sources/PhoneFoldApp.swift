import SwiftUI

@main
struct PhoneFoldApp: App {
    // Only to route the external display scene to its delegate: SwiftUI's `App` has no hook for
    // `configurationForConnecting`. See ExternalDisplay.swift.
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PhoneFoldAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            StageView()
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1440, height: 900)
        #endif
    }
}
