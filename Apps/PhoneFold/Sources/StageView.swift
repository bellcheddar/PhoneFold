import SwiftUI
import simd
import FoldCore
import FoldRender
import FoldEngine

/// The Aurora Stage: a deep indigo ground, the protein, and the readouts beneath it.
struct StageView: View {
    @StateObject private var library = TrajectoryLibrary()
    @StateObject private var player = FoldPlayer()
    @StateObject private var runner = FoldRunner()
    @State private var selection: TrajectoryLibrary.Entry?
    @State private var meshDiagnostic = ""

    /// Genie 2 generates rather than folds toward a reference, and its Core ML path is not
    /// wired to run live yet. Saying so is better than offering a control that does nothing.
    private var unavailableEngines: [FoldingEngine: String] {
        [.generative: "Genie 2 runs through Core ML and is not wired to run live yet"]
    }

    var body: some View {
        ZStack {
            // PLAN.md section 2: deep indigo to near-black, and the body must paint it or
            // the stage borrows whatever the host window is.
            LinearGradient(colors: [Color(hex: 0x181432), Color(hex: 0x0B0A1F)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                // Its own row. Sharing the header with the title and the colour control left
                // the buttons a few points wide on a phone, and SwiftUI rendered their labels
                // one letter per line.
                EnginePicker(engine: $runner.engine, unavailable: unavailableEngines)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                FoldCanvas(player: player, diagnostic: $meshDiagnostic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if case .folding(let fraction) = runner.state {
                            FoldingProgressView(progress: fraction, engine: runner.engine)
                        }
                    }
                FoldHUD(history: player.history, meter: player.meter,
                        confidenceSource: player.confidenceSource,
                        progress: player.progress,
                        playhead: player.scrubbedProgress,
                        scrubbed: player.scrubbedSample,
                        onScrub: { player.scrub(to: $0) },
                        onScrubEnd: { player.endScrub() })
                    // Without priority the RealityView above, which takes all the space it
                    // is offered, squeezes the panel until the charts collapse to zero
                    // height and simply vanish.
                    .layoutPriority(1)
                gallery
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if selection == nil, let opening = openingEntry { start(opening) }
        }
        .onChange(of: runner.engine) { _, _ in
            if let selection { start(selection) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.title)
                    .font(.system(.title2, design: .default).weight(.semibold))
                    .foregroundStyle(.white)
                // On-screen, because simctl's console capture returns nothing for this app:
                // `print` is not a usable diagnostic channel here, and both of the render
                // bugs that took longest to find were found by putting counts on the glass.
                // Off unless asked for, so the stage stays a stage.
                //
                // Not `#if DEBUG`: it was, and the app Marc runs is a Release build, so the
                // overlay added to diagnose the stuck drag could never appear in the one
                // place it was needed. Env-gated is already opt-in enough.
                if Diagnostics.isEnabled {
                    Text(player.diagnostic + "  " + meshDiagnostic)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xFCB900))
                }
                // Whatever this trajectory's claim is, stated. A generated protein has never
                // existed; a simulation toward a known structure did not predict it. Both are
                // things a viewer would otherwise assume wrongly, so the disclosure comes from
                // the provenance rather than from a flag this view decides.
                if let disclosure = player.disclosure {
                    Text(disclosure)
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

    /// Which trajectory to open with.
    ///
    /// `PHONEFOLD_TRAJECTORY` names one by its file stem, so a particular protein can be put
    /// on screen without tapping the gallery. That matters more than it sounds: the app can be
    /// looked at on a Simulator while the Mac is locked, and a screenshot of a specific
    /// protein is often the only way to judge whether a change to the geometry worked - a
    /// twenty-residue trp-cage with one sheet residue says nothing about how strands look.
    private var openingEntry: TrajectoryLibrary.Entry? {
        if let wanted = ProcessInfo.processInfo.environment["PHONEFOLD_TRAJECTORY"],
           let match = library.entries.first(where: {
               $0.url.deletingPathExtension().lastPathComponent == wanted
           }) {
            return match
        }
        return library.entries.first
    }

    /// Fold the chosen protein with the chosen engine, on this device.
    ///
    /// The reference structure is the bundled trajectory's **final frame**, which for the
    /// gallery is ESMFold's own prediction of that protein - so the simulation runs toward a
    /// known structure without needing the network. An accession typed by the user is fetched
    /// from AlphaFold instead; either way the engine is folding toward an answer it was given,
    /// which is what its disclosure says.
    private func start(_ entry: TrajectoryLibrary.Entry) {
        selection = entry
        do {
            let provider = try library.provider(for: entry)
            guard runner.engine.needsReferenceStructure,
                  let final = provider.readouts.last else {
                // Nothing live to run: play the bundled trajectory as it stands.
                player.play(provider)
                return
            }
            let reference = ReferenceStructure(
                accession: provider.metadata.accession ?? entry.id,
                name: provider.metadata.name,
                sequence: provider.metadata.sequence,
                caPositions: final.caPositions.map {
                    SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z))
                },
                pLDDT: final.confidence)
            runner.run(reference: reference, engine: runner.engine, into: player)
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
