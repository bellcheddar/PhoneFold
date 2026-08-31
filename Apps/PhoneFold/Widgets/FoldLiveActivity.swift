import WidgetKit
import SwiftUI
import ActivityKit
import FoldCore

/// The Lock Screen banner and the Dynamic Island for a fold in progress.
///
/// **Three numbers and no chrome.** The Lock Screen has to be readable at a glance from a metre
/// away with a phone face-up on a desk, which is the actual situation: a fold takes tens of
/// seconds and the phone is not in the user's hand while it runs. So: what is folding, how far
/// through, and how confident - and nothing that needs reading twice.
struct FoldLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FoldActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color(red: 0.06, green: 0.05, blue: 0.12))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.proteinName, systemImage: "atom")
                        .font(.caption).foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let confidence = context.state.meanConfidence {
                        Text("\(context.state.confidenceLabel) \(Int(confidence.rounded()))")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(tint(for: confidence))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.progress)
                            .tint(Color(red: 0.56, green: 0.71, blue: 1))
                        Text(detail(context.state, engine: context.attributes.engineName))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "atom").foregroundStyle(Color(red: 0.56, green: 0.71, blue: 1))
            } compactTrailing: {
                // The percentage rather than a ring: at compact size a ring at 40% and one at
                // 55% are the same picture, and the number is the thing being waited on.
                Text("\(Int((context.state.progress * 100).rounded()))%")
                    .font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: "atom").foregroundStyle(Color(red: 0.56, green: 0.71, blue: 1))
            }
            .keylineTint(Color(red: 0.56, green: 0.71, blue: 1))
        }
    }

    @ViewBuilder
    private func lockScreen(
        _ context: ActivityViewContext<FoldActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.attributes.proteinName)
                    .font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                if let confidence = context.state.meanConfidence {
                    Text("\(context.state.confidenceLabel) \(Int(confidence.rounded()))")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(tint(for: confidence))
                }
            }
            ProgressView(value: context.state.progress)
                .tint(Color(red: 0.56, green: 0.71, blue: 1))
            Text(detail(context.state, engine: context.attributes.engineName))
                .font(.caption)
                .foregroundStyle(Color(red: 0.72, green: 0.75, blue: 0.82))
        }
        .padding(14)
    }

    /// The line under the bar: what is happening, on which engine, and which recycle.
    private func detail(_ state: FoldActivitySnapshot,
                        engine: String) -> String {
        var parts = ["\(state.phase.verb) · \(engine)"]
        if let recycle = state.recycle { parts.append("recycle \(recycle + 1)") }
        return parts.joined(separator: "  ·  ")
    }

    /// The same three bands the app's own confidence colouring uses, so a glance at the Lock
    /// Screen and a glance at the stage mean the same thing.
    private func tint(for confidence: Double) -> Color {
        switch confidence {
        case ..<50: Color(red: 1, green: 0.55, blue: 0.35)
        case ..<70: Color(red: 0.99, green: 0.73, blue: 0)
        default: Color(red: 0.35, green: 0.85, blue: 0.62)
        }
    }
}

@main
struct PhoneFoldWidgets: WidgetBundle {
    var body: some Widget { FoldLiveActivity() }
}
