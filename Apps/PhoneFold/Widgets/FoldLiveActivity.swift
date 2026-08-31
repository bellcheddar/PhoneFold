import WidgetKit
import SwiftUI
import ActivityKit
import FoldCore

/// The Lock Screen banner, the Dynamic Island, and the Smart Stack card on the wrist.
///
/// **Three numbers and no chrome.** The Lock Screen has to be readable at a glance from a metre
/// away with a phone face-up on a desk, which is the actual situation: a fold takes tens of
/// seconds and the phone is not in the user's hand while it runs. So: what is folding, how far
/// through, and how confident - and nothing that needs reading twice.
struct FoldLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FoldActivityAttributes.self) { context in
            FoldActivityBanner(context: context)
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
                            .foregroundStyle(FoldActivityBanner.tint(for: confidence))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: context.state.progress)
                            .tint(Color(red: 0.56, green: 0.71, blue: 1))
                        Text(FoldActivityBanner.detail(context.state,
                                                       engine: context.attributes.engineName))
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
        // PLAN.md Phase 5b: "Live Activity mirrored on the wrist."
        //
        // **The mirroring is the system's; the layout is the app's.** watchOS puts a running
        // Live Activity in the Smart Stack whether or not anything is declared here, so the
        // feature appears to work with this line absent - it just appears as the Lock Screen
        // banner squeezed onto a watch face. Declaring `.small` is what buys a design meant
        // for a wrist, and it is worth saying which half is being added, because the half
        // that was already free is the half that makes the omission invisible.
        //
        // `.medium` is deliberately not listed. It is the iPhone banner, which is what the
        // unannotated body already is; naming it too would claim two designs where there is
        // one.
        .supplementalActivityFamilies([.small])
    }
}

/// The banner, in whichever size it was asked for.
///
/// A view rather than a method on the widget: `activityFamily` arrives in the environment, and
/// a `@ViewBuilder` method on a `WidgetConfiguration` has no environment to read it from.
struct FoldActivityBanner: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<FoldActivityAttributes>

    var body: some View {
        switch family {
        case .small: wrist
        default: lockScreen
        }
    }

    /// The wrist: a Smart Stack card about two lines tall.
    ///
    /// **Two things and no third.** The Lock Screen gets a metre of distance and a glance of a
    /// second or two; a Smart Stack card is read in less than that, at arm's length, often
    /// while the arm is still moving. What is folding, and how far through. The confidence and
    /// the engine belong to the phone and stay there - and the wrist has its own complication
    /// for the confidence already, which is a different question asked at a different time.
    private var wrist: some View {
        HStack(spacing: 10) {
            Gauge(value: context.state.progress) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int((context.state.progress * 100).rounded()))")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Color(red: 0.56, green: 0.71, blue: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.proteinName)
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Text(context.state.phase.verb)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.attributes.proteinName)
                    .font(.headline).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
                if let confidence = context.state.meanConfidence {
                    Text("\(context.state.confidenceLabel) \(Int(confidence.rounded()))")
                        .font(.subheadline).monospacedDigit()
                        .foregroundStyle(Self.tint(for: confidence))
                }
            }
            ProgressView(value: context.state.progress)
                .tint(Color(red: 0.56, green: 0.71, blue: 1))
            Text(Self.detail(context.state, engine: context.attributes.engineName))
                .font(.caption)
                .foregroundStyle(Color(red: 0.72, green: 0.75, blue: 0.82))
        }
        .padding(14)
    }

    /// The line under the bar: what is happening, on which engine, and which recycle.
    static func detail(_ state: FoldActivitySnapshot, engine: String) -> String {
        var parts = ["\(state.phase.verb) · \(engine)"]
        if let recycle = state.recycle { parts.append("recycle \(recycle + 1)") }
        return parts.joined(separator: "  ·  ")
    }

    /// The same three bands the app's own confidence colouring uses, so a glance at the Lock
    /// Screen and a glance at the stage mean the same thing.
    static func tint(for confidence: Double) -> Color {
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
