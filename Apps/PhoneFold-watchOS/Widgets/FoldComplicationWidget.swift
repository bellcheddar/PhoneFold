import WidgetKit
import SwiftUI
import FoldSync

/// The watch face complication.
///
/// PLAN.md Phase 5b: "current or last fold's mean pLDDT as a progress ring, tap to open the
/// remote."
///
/// **The bundle identifier ends `.widget`, never `.complication`.** `.complication` is reserved
/// in Apple's App ID namespace and is rejected at any depth, with an error that names the
/// identifier and not the reason.
/// `TimelineEntry` asks only for a `date`, which the entry already has. The conformance is
/// declared here rather than in `FoldSync` so that module stays free of WidgetKit: the timeline
/// logic is what the phase gate tests, and it should not need a widget framework to be tested.
extension FoldComplication.Entry: @retroactive TimelineEntry {}

struct FoldComplicationProvider: TimelineProvider {

    func placeholder(in context: Context) -> FoldComplication.Entry {
        FoldComplication.Entry(date: Date(), title: "Ubiquitin", progress: 0.72,
                               meanConfidence: 91)
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (FoldComplication.Entry) -> Void) {
        completion(FoldComplicationStore.load().map {
            FoldComplication.timeline(from: $0)[0]
        } ?? placeholder(in: context))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<FoldComplication.Entry>) -> Void) {
        let entries = FoldComplication.timeline(from: FoldComplicationStore.load())
        // `.atEnd`, so WidgetKit asks again once the stale entry is showing rather than leaving
        // "no recent fold" on the face for ever after a quiet afternoon.
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct FoldComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FoldComplication.Entry

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.inlineText)
        case .accessoryCorner:
            Text(entry.shortText)
                .widgetCurvesContent()
                .widgetLabel { ProgressView(value: entry.ringFraction) }
        default:
            ZStack {
                // An accessory widget is tinted by the face, so the ring cannot carry meaning
                // by colour: it carries it by how far round it goes, and the number says which
                // quantity that is.
                ProgressView(value: entry.ringFraction) {
                    Text(entry.shortText)
                        .font(.system(size: 14, weight: .medium))
                        .minimumScaleFactor(0.6)
                }
                .progressViewStyle(.circular)
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }
}

struct FoldComplicationWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FoldComplication", provider: FoldComplicationProvider()) {
            FoldComplicationView(entry: $0)
        }
        .configurationDisplayName("Fold")
        .description("The last fold's confidence, and how far through it is.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct PhoneFoldWatchWidgets: WidgetBundle {
    var body: some Widget { FoldComplicationWidget() }
}
