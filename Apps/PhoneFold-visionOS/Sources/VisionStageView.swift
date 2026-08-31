import SwiftUI

/// The protein in a volume, with its transport on an ornament.
///
/// PLAN.md: "Ornament-based transport rather than an overlay, so the stage stays clean." An
/// overlay would sit inside the volume and be part of the object; an ornament hangs outside it
/// and belongs to the window, which is what keeps the protein looking like a protein.
struct VisionStageView: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @State private var diagnostic = ""

    var body: some View {
        FoldCanvas(player: player, diagnostic: $diagnostic)
            .ornament(attachmentAnchor: .scene(.bottom)) {
                VisionTransport()
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .glassBackgroundEffect()
            }
    }
}

/// The immersive version: the same stage with nothing around it.
struct VisionImmersiveView: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player
    @State private var diagnostic = ""

    var body: some View {
        FoldCanvas(player: player, diagnostic: $diagnostic)
    }
}
