import SwiftUI
import FoldRender

/// The transport, small enough to hang off the bottom of a volume.
///
/// Only what a person watching a fold reaches for. Everything else - exports, the mutation
/// duet, the accession field - belongs in the control window, because an ornament that grows
/// becomes the overlay PLAN asked it not to be.
struct VisionTransport: View {
    @ObservedObject private var player = PhoneFoldModel.shared.player

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if player.isPaused { player.resume() } else { player.pause() }
            } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(player.isPaused ? "Play" : "Pause")

            Button {
                player.isSoundOn.toggle()
            } label: {
                Image(systemName: player.isSoundOn
                      ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .accessibilityLabel(player.isSoundOn ? "Sound on" : "Sound off")

            Picker("Colour", selection: $player.colourMode) {
                ForEach(ColourMode.allCases, id: \.self) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
        }
    }
}
