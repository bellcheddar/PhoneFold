import SwiftUI
import os

/// A system font at a fixed point size that still honours Dynamic Type.
///
/// PLAN.md Phase 4 asks for Dynamic Type, and the stage was built out of `.system(size:)` -
/// thirty-nine of them - which is the one SwiftUI font constructor that does *not* scale. A user
/// who has set their text larger got the same twelve points as everyone else.
///
/// **A scaled unit rather than a scaled size.** `@ScaledMetric` scales a number, so scaling a
/// single 1-point unit and multiplying gives one property that works for every size in a view,
/// instead of one `@ScaledMetric` per distinct point size. `relativeTo` still matters and is not
/// defaulted away at the call sites that need it: iOS grows caption text and body text by
/// different factors, and anchoring a 12-point control label to `.body` makes it grow like a
/// paragraph.
private struct ScaledFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    @ScaledMetric private var unit: CGFloat

    init(size: CGFloat, weight: Font.Weight, design: Font.Design,
         relativeTo style: Font.TextStyle) {
        self.size = size
        self.weight = weight
        self.design = design
        _unit = ScaledMetric(wrappedValue: 1, relativeTo: style)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size * unit, weight: weight, design: design))
    }
}

extension View {
    /// `.font(.system(size:weight:design:))`, but it scales.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

/// A row of controls that scrolls rather than squeezing.
///
/// **The recurring failure in this app's layout, now in one place.** SwiftUI's answer to an
/// `HStack` of labelled capsules wider than the screen is to compress each label until the text
/// wraps, so the row degrades into a column of single letters rather than overflowing visibly.
/// It has happened three times: the engine picker sharing the header, the five style capsules on
/// an iPhone, and every control row at once under an accessibility text size, where the content
/// grew wide enough to bleed off both edges.
///
/// Scrolling is the fix for all three, and it is better than the alternatives. Wrapping to a
/// second line pushes the stage off the bottom of a phone. Shrinking the text is the thing
/// Dynamic Type exists to prevent. A menu hides choices that are meant to be one tap away while
/// the music is playing.
struct ControlRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: spacing) { content }
                // Room for the capsules' shadows and the focus ring, which a scroll view clips
                // to its bounds.
                .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        // **Always shows its first item.** These rows carry live values - the readings update
        // every frame - and a scroll view whose content changes width can settle somewhere
        // other than the start, which put the "RG" label half off the left edge of the screen
        // while its container measured a correctly padded 362 points. The frame was right and
        // the scroll offset was not.
        .defaultScrollAnchor(.leading)
        // **Takes the width it is offered rather than the width it wants.** Without this a
        // scroll view reports its *content* width as its ideal width, that ideal travels up
        // through every enclosing stack, and the whole control column ends up wider than the
        // phone - which SwiftUI then centres, so the layout bleeds off both edges at once and
        // the title's left half is off-screen. Measured at the largest accessibility size.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


extension View {
    /// Log this view's laid-out width when diagnostics are on.
    ///
    /// For finding which child of a stack is the one asking for more room than there is. A
    /// stack takes the widest ideal its children report, so an overflowing column says nothing
    /// about *which* child overflowed it - and three rounds of plausible fixes to the wrong
    /// child produced pixel-identical screenshots.
    /// **Reports every change, not just the first layout.** It used `onAppear`, which fires
    /// once - so a row that is empty when the view first appears and full once the fold has
    /// produced readouts reported its empty width for ever. That sent a real investigation
    /// after a counters row "measured at 0 points", which was simply the size it had before
    /// there was anything to count.
    func measured(_ name: String) -> some View {
        background(
            Diagnostics.isEnabled
                ? AnyView(GeometryReader { proxy in
                    Color.clear
                        .onAppear { Diagnostics.log.notice("\(name) \(proxy.size.width)") }
                        .onChange(of: proxy.size.width) { _, width in
                            Diagnostics.log.notice("\(name) \(width)")
                        }
                })
                : AnyView(Color.clear))
    }
}

/// A label that keeps its text until the text stops fitting, then shows only its icon.
///
/// **The last thing making this app wider than the phone.** "Sound", "MIDI" and "Export film"
/// are `fixedSize` so their labels never wrap mid-word, which is right - but at the largest
/// accessibility text size those three plus the route picker needed 425.67 points of a
/// 402-point screen on their own, and nothing that cannot shrink can be squeezed. Measured
/// across every content size: the stage laid out at 402 points up to accessibility-extra-large,
/// 405 at the next size, and 465.67 at the largest.
///
/// Dropping to the icon is better than the alternatives at that size. Wrapping puts a two-line
/// button in a row of one-line ones. Scrolling would take the sound toggle off-screen, and it is
/// the control most likely to be wanted in a hurry. Every one of these already carries an
/// `accessibilityLabel`, so nothing is lost to VoiceOver - and a user at this text size is far
/// more likely to be using it.
struct AdaptiveLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}

extension LabelStyle where Self == AdaptiveLabelStyle {
    static var adaptive: AdaptiveLabelStyle { AdaptiveLabelStyle() }
}
