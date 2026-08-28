import SwiftUI
import simd
import FoldCore
import FoldRender

/// The Aurora Stage: a deep indigo ground, the protein, and the readouts beneath it.
struct StageView: View {
    @StateObject private var library = TrajectoryLibrary()
    @StateObject private var player = FoldPlayer()
    @State private var selection: TrajectoryLibrary.Entry?

    var body: some View {
        ZStack {
            // PLAN.md section 2: deep indigo to near-black, and the body must paint it or
            // the stage borrows whatever the host window is.
            LinearGradient(colors: [Color(hex: 0x181432), Color(hex: 0x0B0A1F)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                FoldCanvas(mesh: player.mesh, flashes: player.flashes,
                           colourMode: player.colourMode,
                           residues: player.provider?.residues ?? [],
                           residueCount: player.provider?.residueCount ?? 0,
                           residueConfidence: player.frame?.pLDDT ?? [])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FoldHUD(history: player.history, meter: player.meter,
                        confidenceSource: player.confidenceSource,
                        progress: player.progress)
                    // Without priority the RealityView above, which takes all the space it
                    // is offered, squeezes the panel until the charts collapse to zero
                    // height and simply vanish.
                    .layoutPriority(1)
                gallery
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if selection == nil, let first = library.entries.first { start(first) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.title)
                    .font(.system(.title2, design: .default).weight(.semibold))
                    .foregroundStyle(.white)
                if player.isGenerated {
                    // A generated protein has never existed. The app says so rather than
                    // letting it be mistaken for a prediction.
                    Text("Generated — this protein has never existed")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0xFCB900))
                }
            }
            Spacer()
            Picker("Colour", selection: $player.colourMode) {
                ForEach(ColourMode.allCases, id: \.self) { mode in
                    Text(mode.shortName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var gallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(library.entries) { entry in
                    Button { start(entry) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName).font(.caption.weight(.medium))
                            Text(entry.subtitle).font(.system(size: 10))
                                .foregroundStyle(Color(hex: 0x6B7C93))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection?.id == entry.id
                                      ? Color(hex: 0xFF3D9A).opacity(0.28)
                                      : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 62)
        .padding(.bottom, 8)
    }

    private func start(_ entry: TrajectoryLibrary.Entry) {
        selection = entry
        do {
            player.play(try library.provider(for: entry))
        } catch {
            print("could not load \(entry.displayName): \(error)")
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
