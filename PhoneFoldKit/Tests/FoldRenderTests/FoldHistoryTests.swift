import Testing
import Foundation
@testable import FoldRender

@Suite("Fold history and compute meter")
struct FoldHistoryTests {

    static func sample(_ index: Int, raw: Bool = false, contacts: Int = 0,
                       rg: Float = 12) -> HistorySample {
        HistorySample(frameIndex: index, progress: Double(index) / 1000,
                      radiusOfGyration: rg, compactness: rg / 11.4,
                      contactCount: 10, meanConfidence: 80,
                      helixFraction: 0.4, sheetFraction: 0.2, coilFraction: 0.4,
                      newContacts: contacts, isRawFrame: raw)
    }

    /// A 300-residue fold at 60 fps produces thousands of frames and a chart has hundreds of
    /// pixels. Unbounded growth buys nothing visible.
    @Test("history stays bounded however long the fold runs")
    func bounded() {
        var history = FoldHistory(capacity: 64)
        for i in 0..<10_000 { history.append(Self.sample(i)) }
        #expect(history.samples.count <= 64)
        #expect(history.stride > 1, "decimation should have kicked in")
    }

    @Test("the most recent sample is never decimated away")
    func keepsLatest() {
        var history = FoldHistory(capacity: 16)
        for i in 0..<500 { history.append(Self.sample(i)) }
        #expect(history.latest?.frameIndex == 499,
                "the newest point is what the readouts are showing")
    }

    /// Raw readouts are the real data. Dropping one to a decimation stride would hide an
    /// actual model output behind interpolated frames.
    @Test("raw model readouts are always kept")
    func rawFramesAlwaysKept() {
        var history = FoldHistory(capacity: 512)
        for i in 0..<200 {
            history.append(Self.sample(i, raw: i % 25 == 0))
        }
        let rawIndices = history.samples.filter(\.isRawFrame).map(\.frameIndex)
        #expect(rawIndices == stride(from: 0, to: 200, by: 25).map { $0 },
                "a raw readout was dropped: \(rawIndices)")
    }

    @Test("samples stay in order after decimation")
    func ordered() {
        var history = FoldHistory(capacity: 32)
        for i in 0..<2000 { history.append(Self.sample(i)) }
        let indices = history.samples.map(\.frameIndex)
        #expect(indices == indices.sorted())
        #expect(Set(indices).count == indices.count, "decimation duplicated a sample")
    }

    /// A flat trace must not collapse to zero height, or the chart draws a line on the axis.
    @Test("a flat trace still gets a usable range")
    func flatRange() {
        var history = FoldHistory()
        for i in 0..<20 { history.append(Self.sample(i, rg: 12)) }
        let range = history.range(\.radiusOfGyration)
        #expect(range.upperBound > range.lowerBound)
        #expect(range.contains(12))
    }

    @Test("a varying trace gets a padded range covering every value")
    func paddedRange() {
        var history = FoldHistory()
        for i in 0..<50 { history.append(Self.sample(i, rg: Float(i) * 0.5 + 5)) }
        let range = history.range(\.radiusOfGyration)
        for sample in history.samples {
            #expect(range.contains(sample.radiusOfGyration))
        }
    }

    @Test("contact events are picked out for the timeline rail")
    func contactEvents() {
        var history = FoldHistory(capacity: 500)
        for i in 0..<100 { history.append(Self.sample(i, contacts: i % 10 == 0 ? 3 : 0)) }
        #expect(history.contactEvents.allSatisfy { $0.newContacts > 0 })
        #expect(history.contactEvents.count == 10)
    }

    @Test("reset clears everything, including the decimation stride")
    func reset() {
        var history = FoldHistory(capacity: 16)
        for i in 0..<500 { history.append(Self.sample(i)) }
        history.reset()
        #expect(history.samples.isEmpty)
        #expect(history.stride == 1)
        #expect(history.latest == nil)
    }
}

@Suite("Compute meter")
struct ComputeMeterTests {

    /// The meter must not imply a hardware utilisation reading, because there is no public
    /// API for one and the app is currently replaying rather than inferring.
    @Test("the label says what is actually being measured")
    func honestLabel() {
        var meter = ComputeMeter()
        #expect(meter.label == "Playback · frame")
        #expect(meter.label.contains("frame"), "it measures frame cost, not utilisation")

        meter.configure(workload: .generating, unit: .gpu)
        #expect(meter.label == "Generating · GPU · frame")
        // And it never claims the Neural Engine unless told: the ANE cannot compile Genie 2.
        #expect(meter.unit == .gpu)
    }

    @Test("frame cost averages over a window and yields a budget fraction")
    func budget() {
        var meter = ComputeMeter()
        for _ in 0..<30 { meter.record(frameCostMilliseconds: 8.35) }
        #expect(abs(meter.averageFrameCost - 8.35) < 1e-6)
        // 8.35 ms is half of the 16.7 ms budget for 60 fps.
        #expect(abs(meter.budgetFraction - 0.5) < 0.01)
    }

    @Test("the window slides rather than growing without bound")
    func slidingWindow() {
        var meter = ComputeMeter()
        for _ in 0..<200 { meter.record(frameCostMilliseconds: 100) }
        for _ in 0..<60 { meter.record(frameCostMilliseconds: 1) }
        #expect(abs(meter.averageFrameCost - 1) < 0.01,
                "old samples should have aged out")
    }

    @Test("nonsense measurements are ignored rather than poisoning the average")
    func rejectsNonsense() {
        var meter = ComputeMeter()
        meter.record(frameCostMilliseconds: 10)
        meter.record(frameCostMilliseconds: .nan)
        meter.record(frameCostMilliseconds: -5)
        meter.record(frameCostMilliseconds: .infinity)
        #expect(meter.averageFrameCost == 10)
        #expect(meter.budgetFraction.isFinite)
    }

    @Test("an empty meter reports zero rather than dividing by nothing")
    func empty() {
        let meter = ComputeMeter()
        #expect(meter.averageFrameCost == 0)
        #expect(meter.budgetFraction == 0)
    }
}
