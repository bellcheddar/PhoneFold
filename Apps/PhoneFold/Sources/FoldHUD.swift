import SwiftUI
import Charts
import FoldCore
import FoldRender

/// The folding-progress panel.
///
/// Marc's Phase 2 addition: **use metrics to show the progress of folding**. Everything shown
/// is derived from frames that already exist, so the panel costs a few floats per frame.
///
/// What is deliberately **not** here, and why, so it does not look like an oversight:
/// TM-score and RMSD need a reference structure, which a *generated* protein does not have;
/// hydrogen bonds and total energy need more than a CA trace, and the live engine emits CA
/// only. Those belong to the named gallery, once PathDiffusion pathways exist.
struct FoldHUD: View {
    let history: FoldHistory
    let meter: ComputeMeter
    let confidenceSource: ConfidenceSource
    let progress: Double
    /// Where the scrubber is, or nil when the display is following the fold.
    let playhead: Double?
    /// The frame under the scrubber, when there is one. The counters follow the stage.
    let scrubbed: HistorySample?
    /// Called with 0...1 through the trajectory as the finger moves.
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void

    private var samples: [HistorySample] { history.samples }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            counters
            if samples.count > 2 {
                HStack(spacing: 12) {
                    // The label above the plot, not over it. Overlaid at the top-left it sat
                    // directly on the radius-of-gyration line, and a trace with a word
                    // printed through it is harder to read than either alone.
                    labelled("Structure") { structureChart }
                    labelled("Radius of gyration") { radiusChart }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 54, maxHeight: 58)
            }
            timeline
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Turn a trace into a scrubber.
    ///
    /// A plain overlay rather than `chartOverlay` with the chart proxy. Both traces have an x
    /// domain of exactly 0...1 and no axis, so the fraction across the view is the position in
    /// the trajectory, and going through the proxy's plot frame only added a conversion that
    /// put the playhead somewhere other than under the finger. See `Scrubbing`.
    ///
    /// `minimumDistance: 0` so a tap lands too: on a trace 58 points tall, requiring a drag
    /// before responding makes it feel dead.
    private var scrubSurface: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged {
                            onScrub(Scrubbing.progress(atX: $0.location.x,
                                                       width: geometry.size.width))
                        }
                        .onEnded { _ in onScrubEnd() }
                )
        }
    }

    /// The line showing where the scrubber is, drawn in both traces.
    @ChartContentBuilder
    private var playheadMark: some ChartContent {
        if let playhead {
            RuleMark(x: .value("t", playhead))
                .foregroundStyle(.white.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    // MARK: - Counters

    /// The counter strip, laid out for whatever width it is given.
    ///
    /// **`ViewThatFits` over a plain row, and this was re-established the hard way.** A scroll
    /// view was tried here and made things worse: it has no intrinsic width to contribute, so
    /// the enclosing row sized itself to the meter alone, and the readings drew from outside the
    /// row's own bounds - "RG" appeared half off the left edge of the screen while its container
    /// measured a correctly padded 362 points. Neither `.layoutPriority` nor
    /// `.defaultScrollAnchor(.leading)` moved it, because the frame was right and only the
    /// content's position was wrong.
    ///
    /// The original arrangement is correct and is restored: one row when it fits, the meter
    /// dropped to a second line when it does not, and nothing truncated either way. A reading
    /// cut in half - "H/E/C 45/1" - is worse than no reading, because it looks like a layout
    /// fault and cannot be trusted.
    ///
    /// The overflow at accessibility text sizes that prompted the scroll view had a different
    /// cause, found later and fixed at its source: three `fixedSize` labels that drop to
    /// icon-only (`AdaptiveLabelStyle`), and a `RealityView` handing its own intrinsic width to
    /// every sibling (see `StageView`).
    private var counters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                countersRow
                Spacer(minLength: 12)
                computeMeter
            }
            VStack(alignment: .leading, spacing: 6) {
                countersRow
                computeMeter
            }
        }
    }

    /// The five readings.
    ///
    /// **This row was making the whole app wider than the phone.** `fixedSize(horizontal: true)`
    /// is right for the numbers themselves - without it "7.5 Å" wraps mid-value and reads as a
    /// layout fault rather than a reading - but applied to the row it made the row
    /// unshrinkable, and at the largest accessibility text size five counters demanded 465.67
    /// points on a 402-point screen. A VStack takes the widest ideal any child reports, so the
    /// entire control column grew to match and was then centred, and the layout bled off both
    /// edges at once while looking perfect at the default size. Measured with `.measured(_:)`
    /// after three rounds of fixing rows that turned out to be passengers.
    ///
    /// Scrolling keeps the numbers unwrapped and lets the row give back the width.
    private var countersRow: some View {
        HStack(alignment: .top, spacing: 14) {
            if let now = scrubbed ?? history.latest {
                counter("Rg", String(format: "%.1f Å", now.radiusOfGyration))
                counter("Compact", String(format: "%.2f", now.compactness),
                        tint: now.compactness < 1.25 ? Color(hex: 0x22E5FF) : Color(hex: 0xFCB900))
                counter("Contacts", "\(now.contactCount)")
                counter(confidenceSource.displayName,
                        String(format: "%.0f", now.meanConfidence))
                counter("H/E/C", String(format: "%.0f/%.0f/%.0f",
                                        now.helixFraction * 100,
                                        now.sheetFraction * 100,
                                        now.coilFraction * 100))
            }
        }
        // Every counter on one line: without this the values wrap mid-number and "7.5 Å"
        // becomes two lines, which reads as a layout fault rather than a reading.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func counter(_ label: String, _ value: String,
                         tint: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .scaledFont(8, weight: .semibold, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(Color(hex: 0x6B7C93))
            Text(value)
                .scaledFont(14, design: .monospaced, relativeTo: .subheadline)
                .foregroundStyle(tint)
        }
    }

    /// Frame cost against the 60 fps budget.
    ///
    /// Labelled as a frame measurement, not a hardware utilisation reading: iOS exposes no
    /// public GPU or ANE utilisation API, and inventing a percentage would be worse than
    /// showing the real number the app can measure.
    private var computeMeter: some View {
        // Leading, not trailing: in the stacked layout a right-aligned label floated away
        // from the number it belongs to.
        VStack(alignment: .leading, spacing: 3) {
            Text(meter.label.uppercased())
                .scaledFont(8, weight: .semibold, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(Color(hex: 0x6B7C93))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(String(format: "%.1f ms", meter.averageFrameCost))
                    .scaledFont(13, design: .monospaced, relativeTo: .footnote)
                    .foregroundStyle(.white)
                GeometryReader { geometry in
                    let fraction = min(max(meter.budgetFraction, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(meter.budgetFraction < 0.8
                                  ? Color(hex: 0x22E5FF) : Color(hex: 0xFF3D9A))
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(width: 64, height: 6)
            }
        }
    }

    // MARK: - Traces

    /// Helix, sheet and coil as fractions of the chain. Secondary structure forming is the
    /// visual headline, and this is it as a number.
    private var structureChart: some View {
        Chart {
            ForEach(samples, id: \.frameIndex) { sample in
                AreaMark(x: .value("t", sample.progress),
                         y: .value("Helix", sample.helixFraction),
                         stacking: .standard)
                    .foregroundStyle(Color(hex: 0xFF3D9A))
                AreaMark(x: .value("t", sample.progress),
                         y: .value("Sheet", sample.sheetFraction),
                         stacking: .standard)
                    .foregroundStyle(Color(hex: 0x22E5FF))
                AreaMark(x: .value("t", sample.progress),
                         y: .value("Coil", sample.coilFraction),
                         stacking: .standard)
                    .foregroundStyle(Color(hex: 0x6B7C93).opacity(0.55))
            }
            playheadMark
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay { scrubSurface }
    }

    /// Radius of gyration: compaction is the fold happening.
    ///
    /// The recycle boundaries are marked, and they are the whole reason this trace is
    /// readable. The trunk re-enters from a coarser state at each recycle, so the structure
    /// genuinely re-expands and Rg steps back up - on trp-cage from about 6.7 to 7.2 A at
    /// readouts 8, 16 and 24 of 32. Unmarked, that reads as three unexplained periodic peaks
    /// and looks like a broken chart. PLAN.md asks for the boundaries on the timeline for
    /// exactly this reason.
    private var radiusChart: some View {
        Chart {
            ForEach(history.recycleBoundaries, id: \.frameIndex) { boundary in
                RuleMark(x: .value("t", boundary.progress))
                    .foregroundStyle(Color(hex: 0xFCB900).opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 1) {
                        Text("recycle \(boundary.recycle)")
                            .scaledFont(7, weight: .medium, design: .monospaced, relativeTo: .caption)
                            .foregroundStyle(Color(hex: 0xFCB900).opacity(0.7))
                    }
            }
            ForEach(samples, id: \.frameIndex) { sample in
                LineMark(x: .value("t", sample.progress),
                         y: .value("Rg", sample.radiusOfGyration))
                    .foregroundStyle(Color(hex: 0x22E5FF))
                    .interpolationMethod(.monotone)
            }
            playheadMark
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: Double(history.range(\.radiusOfGyration).lowerBound)
                     ... Double(history.range(\.radiusOfGyration).upperBound))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay { scrubSurface }
    }

    /// A trace with its name above it.
    private func labelled<Content: View>(_ text: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            traceLabel(text)
            content()
        }
    }

    private func traceLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(8, weight: .semibold, design: .monospaced, relativeTo: .caption)
            .foregroundStyle(Color(hex: 0x6B7C93))
            .padding(.leading, 2)
    }

    // MARK: - Timeline

    /// Progress, with a tick for every frame on which a contact formed. Those ticks are the
    /// note onsets the Phase 3 score will play.
    private var timeline: some View {
        GeometryReader { geometry in
            let width = Swift.max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 3)
                Capsule().fill(Color(hex: 0x22E5FF))
                    .frame(width: width * min(max(progress, 0), 1), height: 3)
                ForEach(history.contactEvents, id: \.frameIndex) { event in
                    Capsule()
                        .fill(Color(hex: 0xFCB900).opacity(0.75))
                        .frame(width: 1.5, height: 9)
                        .offset(x: width * min(max(event.progress, 0), 1) - 0.75)
                }
                if let playhead {
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .offset(x: width * min(max(playhead, 0), 1) - 4.5)
                }
            }
            .frame(height: 10)
            // The bar is three points tall; the target is not. A hairline is fine to look at
            // and impossible to hit, so the whole strip takes the gesture.
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged {
                        onScrub(Scrubbing.progress(atX: $0.location.x, width: width))
                    }
                    .onEnded { _ in onScrubEnd() }
            )
        }
        .frame(height: 10)
    }
}
