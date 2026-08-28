import SwiftUI

@main
struct PhoneFoldApp: App {
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
