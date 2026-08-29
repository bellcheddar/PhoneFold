import Foundation

/// The arithmetic behind dragging a trace to a moment in the fold.
///
/// Small enough to look obvious and worth having outside the view anyway: the first version
/// lived inside a SwiftUI `chartOverlay`, mapped through the chart proxy's plot frame, and
/// put the playhead somewhere other than under the finger. Nothing about that was checkable
/// without driving a real cursor around a real desktop. Here it is arithmetic, and arithmetic
/// can be tested.
public enum Scrubbing {

    /// Where along a trace a touch landed, as 0...1.
    ///
    /// Both traces are drawn with an x domain of exactly 0...1 and no axis, so the fraction
    /// across the view *is* the position in the trajectory; no chart-space conversion is
    /// needed, and not needing one is why this is reliable.
    public static func progress(atX x: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return Swift.min(Swift.max(x / width, 0), 1)
    }

    /// The played frame nearest a scrub position.
    ///
    /// `progresses` is in trajectory order, so this is a binary search rather than a scan:
    /// a 314-residue fold stores upwards of seven hundred frames and this runs on every
    /// movement of a finger.
    public static func nearestIndex(toProgress target: Double,
                                    in progresses: [Double]) -> Int? {
        guard !progresses.isEmpty else { return nil }
        var low = 0
        var high = progresses.count - 1
        while low < high {
            let mid = (low + high) / 2
            if progresses[mid] < target { low = mid + 1 } else { high = mid }
        }
        // `low` is the first entry at or after the target; its predecessor may be closer.
        if low > 0, abs(progresses[low - 1] - target) <= abs(progresses[low] - target) {
            return low - 1
        }
        return low
    }
}
