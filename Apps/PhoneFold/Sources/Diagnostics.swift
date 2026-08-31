import Foundation
import os

/// The on-glass diagnostic channel.
///
/// `simctl launch --console-pty` returns nothing for this app, every time it was tried, so
/// `print` cannot be read back from a Simulator run. Both of the render bugs that cost the
/// most - the Release blank screen, and the backbone that drew in cleanly capped pieces -
/// were found by putting buffer counts on the screen and screenshotting them. The channel
/// stays, and stays off, so it costs nothing to reach for next time.
///
///     xcrun simctl launch --setenv PHONEFOLD_DIAGNOSTICS=1 <udid> com.mdeller.phonefold
enum Diagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["PHONEFOLD_DIAGNOSTICS"] == "1"

    /// For diagnostics that are numbers rather than pictures.
    ///
    /// The on-glass channel above is for things you have to *see* - a mesh drawing in pieces.
    /// A measured width is just a number, and putting it in a `@State` from inside a
    /// `GeometryReader`'s `onAppear` mutates state during a layout pass: measured, it took the
    /// app down before it drew anything. `Logger` writes from wherever it is called.
    static let log = Logger(subsystem: "com.mdeller.phonefold", category: "Layout")
}
