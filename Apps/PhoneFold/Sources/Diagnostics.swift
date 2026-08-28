import Foundation

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
}
