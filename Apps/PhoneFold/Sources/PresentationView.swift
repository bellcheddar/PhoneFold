import SwiftUI
import FoldCore
import FoldRender

/// What an external display shows: the fold, and nothing that can be tapped.
///
/// PLAN.md Phase 4: "on connection, render a clean full-bleed stage with no controls, larger
/// type, protein name and confidence readout. The phone becomes the control surface. This is
/// what makes it work in a lecture theatre."
///
/// **No controls at all, not disabled ones.** The scene role is
/// `windowExternalDisplayNonInteractive`: nothing on that screen can receive a touch, so a
/// control there is a picture of a control. Everything a person might reach for stays on the
/// phone.
struct PresentationView: View {
    @ObservedObject var player: FoldPlayer

    /// Type sizes for a room rather than a hand.
    ///
    /// Scaled from the display's own height rather than fixed, because "the external display"
    /// is a 1080p projector, a 4K television, or a lecture theatre's own scaler, and a caption
    /// legible on one is unreadable on another.
    private func scale(_ points: CGFloat, in height: CGFloat) -> CGFloat {
        points * max(height / 1080, 0.6)
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x181432), Color(hex: 0x0B0A1F)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                FoldCanvas(player: player, diagnostic: .constant(""))
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: scale(10, in: height)) {
                            Text(player.title)
                                .font(.system(size: scale(52, in: height), weight: .semibold))
                                .foregroundStyle(.white)
                            if let disclosure = player.disclosure {
                                // The provenance stays on the big screen too. A room full of
                                // people is exactly where "this is not a folding pathway" has
                                // to be legible.
                                Text(disclosure)
                                    .font(.system(size: scale(22, in: height)))
                                    .foregroundStyle(Color(hex: 0xFCB900))
                            }
                        }
                        Spacer(minLength: scale(40, in: height))
                        readout(height: height)
                    }
                    .padding(scale(56, in: height))
                }
            }
        }
        // Never dimmed, never asleep: this is a lecture.
        .persistentSystemOverlays(.hidden)
    }

    /// The numbers, large enough to read from the back.
    private func readout(height: CGFloat) -> some View {
        let sample = player.scrubbedSample ?? player.history.samples.last
        return HStack(alignment: .bottom, spacing: scale(44, in: height)) {
            if let sample {
                figure("\(Int(sample.meanConfidence.rounded()))",
                       label: player.confidenceSource.displayName, height: height)
                figure(String(format: "%.1f", sample.radiusOfGyration),
                       label: "Rg, Å", height: height)
                figure("\(sample.contactCount)", label: "Contacts", height: height)
            }
        }
    }

    private func figure(_ value: String, label: String, height: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: scale(4, in: height)) {
            Text(value)
                .font(.system(size: scale(46, in: height), weight: .medium,
                              design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: scale(17, in: height)))
                .textCase(.uppercase)
                .foregroundStyle(Color(hex: 0x6B7C93))
        }
    }
}
