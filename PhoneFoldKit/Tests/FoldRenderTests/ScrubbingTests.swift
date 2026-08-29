import Testing
import Foundation
@testable import FoldRender

@Suite("Scrubbing")
struct ScrubbingTests {

    @Test("A touch maps to the fraction across the trace")
    func fractionAcrossTheTrace() {
        #expect(Scrubbing.progress(atX: 0, width: 200) == 0)
        #expect(Scrubbing.progress(atX: 100, width: 200) == 0.5)
        #expect(Scrubbing.progress(atX: 200, width: 200) == 1)
    }

    @Test("Dragging past either end holds, rather than running off")
    func clampsAtTheEnds() {
        #expect(Scrubbing.progress(atX: -40, width: 200) == 0)
        #expect(Scrubbing.progress(atX: 999, width: 200) == 1)
        // A view can be laid out at zero width for a frame; that must not divide by nothing.
        #expect(Scrubbing.progress(atX: 10, width: 0) == 0)
    }

    @Test("The nearest played frame is the one picked")
    func picksTheNearestFrame() {
        let progresses = (0..<11).map { Double($0) / 10 }
        #expect(Scrubbing.nearestIndex(toProgress: 0.0, in: progresses) == 0)
        #expect(Scrubbing.nearestIndex(toProgress: 1.0, in: progresses) == 10)
        #expect(Scrubbing.nearestIndex(toProgress: 0.44, in: progresses) == 4)
        #expect(Scrubbing.nearestIndex(toProgress: 0.46, in: progresses) == 5)
        // Exactly between two frames: either is equally near, and it must be deterministic.
        #expect(Scrubbing.nearestIndex(toProgress: 0.45, in: progresses) == 4)
        #expect(Scrubbing.nearestIndex(toProgress: 5.0, in: progresses) == 10)
        #expect(Scrubbing.nearestIndex(toProgress: -1, in: progresses) == 0)
        #expect(Scrubbing.nearestIndex(toProgress: 0.5, in: []) == nil)
    }

    /// The binary search must agree with the obvious linear scan, for every position.
    @Test("The search agrees with a linear scan over an uneven trajectory")
    func agreesWithLinearScan() {
        // Uneven on purpose: playback stores whatever frames were delivered, and the last
        // frame is published out of cadence so the final reading is the real one.
        var progresses: [Double] = []
        var t = 0.0
        var step = 0.001
        while t < 1 { progresses.append(t); t += step; step *= 1.05 }
        progresses.append(1)

        for i in 0...500 {
            let target = Double(i) / 500
            let found = Scrubbing.nearestIndex(toProgress: target, in: progresses)!
            let scanned = progresses.indices.min {
                abs(progresses[$0] - target) < abs(progresses[$1] - target)
            }!
            #expect(abs(progresses[found] - target) == abs(progresses[scanned] - target),
                    "at \(target): binary search chose \(progresses[found]), scan \(progresses[scanned])")
        }
    }
}
