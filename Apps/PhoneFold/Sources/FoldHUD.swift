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
                    structureChart
                    radiusChart
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

    private var counters: some View {
        HStack(alignment: .top, spacing: 0) {
            // Scrolls rather than stretching. `fixedSize` on the row keeps every value on
            // one line but makes the row wider than the screen, which pushes the whole
            // layout sideways and takes the charts off-view with it.
            ScrollView(.horizontal, showsIndicators: false) {
                countersRow
            }
            Spacer(minLength: 10)
            computeMeter
        }
    }

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
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x6B7C93))
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(tint)
        }
    }

    /// Frame cost against the 60 fps budget.
    ///
    /// Labelled as a frame measurement, not a hardware utilisation reading: iOS exposes no
    /// public GPU or ANE utilisation API, and inventing a percentage would be worse than
    /// showing the real number the app can measure.
    private var computeMeter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(meter.label.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x6B7C93))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(String(format: "%.1f ms", meter.averageFrameCost))
                    .font(.system(size: 13, design: .monospaced))
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
        .overlay(alignment: .topLeading) { traceLabel("Structure") }
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
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
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
        .overlay(alignment: .topLeading) { traceLabel("Radius of gyration") }
    }

    private func traceLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
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
