import SwiftUI
import simd
import FoldCore
import FoldRender
import FoldEngine
import FoldAudio
import FoldCapture
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The Aurora Stage: a deep indigo ground, the protein, and the readouts beneath it.
struct StageView: View {
    // Observed rather than owned. The fold belongs to a `PhoneFoldModel` held above this view:
    // on iOS the shared one, because an external display scene shows the same fold; on macOS
    // one per window, because two windows showing the same protein is not multi-window. Either
    // way a `@StateObject` here would tie the fold's lifetime to this view's.
    @ObservedObject private var model: PhoneFoldModel
    @ObservedObject private var library: TrajectoryLibrary
    @ObservedObject private var player: FoldPlayer
    @ObservedObject private var runner: FoldRunner

    init(model: PhoneFoldModel) {
        self.model = model
        library = model.library
        player = model.player
        runner = model.runner
    }
    @State private var selection: TrajectoryLibrary.Entry?
    @State private var meshDiagnostic = ""
    @State private var accession = ""
    /// Genie 2's seed. Starts at 1 again: it started at 3 while seeds 1 and 2 diverged,
    /// which they no longer do. See `FoldRunner.generate` and `Genie2Sampler.sample`.
    @State private var generationSeed: UInt64 = 1
    /// What the last export did, shown under the controls rather than in an alert: a
    /// modal for "saved it" interrupts a fold that is still playing.
    @State private var mutation = ""
    @State private var midiMessage = ""
    @State private var midiDocument = MIDIDocument(data: Data())
    @State private var isExportingMIDI = false
    @State private var isShowingAbout = false
    @StateObject private var film = FilmExportController()
    @State private var isShowingOnboarding = !Onboarding.hasBeenSeen
    /// What to listen for, by trajectory. Empty is not a failure - the gallery still works.
    private let listeningNotes = ListeningNotes.bundled()

    /// All three engines run. Kept as a hook because an engine can still become unavailable -
    /// a missing model in the bundle, say - and a disabled control with a reason beats one
    /// that silently does nothing.
    private var unavailableEngines: [FoldingEngine: String] { [:] }

    var body: some View {
        ZStack {
            if Diagnostics.isEnabled {
                GeometryReader { window in
                    Color.clear.onAppear {
                        #if os(iOS)
                        let screen = UIScreen.main.bounds.width
                        let scale = UIScreen.main.scale
                        Diagnostics.log.notice(
                            "zstack \(window.size.width) screen \(screen) scale \(scale)")
                        #else
                        Diagnostics.log.notice("zstack \(window.size.width)")
                        #endif
                    }
                }
            }
            // PLAN.md section 2: deep indigo to near-black, and the body must paint it or
            // the stage borrows whatever the host window is.
            LinearGradient(colors: [Color(hex: 0x181432), Color(hex: 0x0B0A1F)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .fileExporter(isPresented: $isExportingMIDI, document: midiDocument,
                              contentType: .midi,
                              defaultFilename: (selection?.id ?? "phonefold")
                                  + "-" + player.styleID) { result in
                    switch result {
                    case .success(let url): midiMessage = "Saved \(url.lastPathComponent)"
                    case .failure(let error):
                        midiMessage = "Could not save: \(error.localizedDescription)"
                    }
                }

            VStack(spacing: 0) {
                header
                    .measured("header")
                // Its own row. Sharing the header with the title and the colour control left
                // the buttons a few points wide on a phone, and SwiftUI rendered their labels
                // one letter per line.
                EnginePicker(engine: $runner.engine, unavailable: unavailableEngines)
                    .measured("engine")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                // Its own row again, below the engine: the two are separate choices - what
                // computes the fold, and what the fold sounds like - and putting them on one
                // line read as one control with eight options.
                ScoreControls(isSoundOn: $player.isSoundOn,
                              styles: player.orderedStyles,
                              styleID: $player.styleID,
                              diagnostic: midiMessage.isEmpty ? player.audioDiagnostic
                                                              : midiMessage,
                              onExportMIDI: exportMIDI)
                    .measured("score")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                // Only for the structure-based engine: a morph has no contact energies for a
                // substitution to perturb, so the field would do nothing there.
                if runner.engine == .structureBased {
                    DuetControls(mutation: $mutation, divergence: player.duetDivergence,
                                 isBusy: runner.state.isBusy, onFold: foldDuet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                }
                ExportControls(preset: $film.preset, state: film.state,
                               canExport: player.exportProvider != nil,
                               onExport: exportFilm, onCancel: film.cancel)
                    .measured("export")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                // The accession field is meaningless for Genie 2 - it invents a protein and
                // has nothing to look up - so that row becomes a re-roll instead. Showing a
                // disabled text field there would be asking for an input the engine cannot use.
                Group {
                    if runner.engine.needsReferenceStructure {
                        AccessionField(accession: $accession, state: runner.state) {
                            runner.fetchAndRun(accession: accession, engine: runner.engine,
                                               into: player)
                            selection = nil
                        }
                    } else {
                        GenerateControls(seed: $generationSeed, state: runner.state) {
                            generationSeed &+= 1
                            runner.generate(seed: generationSeed, into: player)
                        }
                    }
                }
                .measured("accession-or-generate")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 6)
                // **In an overlay on `Color.clear`, and that is load-bearing.** A `RealityView`
                // reports an intrinsic width of its own - measured at 451.33 points on a
                // 402-point phone - and as a direct child of this stack it handed that ideal to
                // every sibling: the header, the HUD and the gallery all laid out at 451.33 and
                // lost their side padding off both edges, while the stack itself still measured
                // 402. Proved by substitution: replacing this one view with `Color.clear` put
                // every row back to exactly 402.
                //
                // `Color.clear` has no intrinsic size and takes whatever it is offered, and an
                // overlay never influences what it is drawn on, so the canvas now fits the
                // stage instead of the stage fitting the canvas.
                Color.clear
                    .measured("canvas")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        FoldCanvas(player: player, diagnostic: $meshDiagnostic)
                    }
                    .overlay {
                        switch runner.state {
                        case .folding(let fraction):
                            FoldingProgressView(progress: fraction, engine: runner.engine)
                        case .fetching(let which):
                            FoldingProgressView(progress: 0, engine: runner.engine,
                                                caption: "Fetching \(which) from AlphaFold")
                        case .idle, .failed:
                            EmptyView()
                        }
                    }
                    // Where the picture went. A presenter who has just plugged in a projector
                    // has no way to tell from the phone whether anything reached it - the phone
                    // looks identical either way - so the control surface says so itself.
                    .overlay(alignment: .topTrailing) {
                        if model.isOnExternalDisplay {
                            Label("On display", systemImage: "tv")
                                .scaledFont(11, weight: .medium, relativeTo: .caption)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.black.opacity(0.45)))
                                .foregroundStyle(Color(hex: 0x8FB4FF))
                                .padding(12)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: model.isOnExternalDisplay)
                FoldHUD(history: player.history, meter: player.meter,
                        confidenceSource: player.confidenceSource,
                        progress: player.progress,
                        playhead: player.scrubbedProgress,
                        scrubbed: player.scrubbedSample,
                        onScrub: { player.scrub(to: $0) },
                        onScrubEnd: { player.endScrub() })
                    .measured("hud")
                    // Without priority the RealityView above, which takes all the space it
                    // is offered, squeezes the panel until the charts collapse to zero
                    // height and simply vanish.
                    .layoutPriority(1)
                gallery
                    .measured("gallery")
            }
            .background(
                Diagnostics.isEnabled
                    ? AnyView(GeometryReader { column in
                        Color.clear.onAppear {
                            Diagnostics.log.notice("column \(column.size.width)")
                        }
                    })
                    : AnyView(Color.clear))
            // **The stage caps Dynamic Type at accessibility 3, and the sheets do not.**
            //
            // Measured across every content size after the width was fixed: the control column
            // lays out at exactly 402 points, the screen's width, at every size up to
            // accessibility-extra-large. Above that it fits horizontally but not vertically -
            // the controls alone are taller than the phone, so SwiftUI centres the column and
            // the title is pushed up under the Dynamic Island, and there is no room left for
            // the protein at all.
            //
            // PhoneFold is a stage, and the picture is the point. Text large enough to leave no
            // room for the fold has not made the app accessible, it has removed the thing the
            // app is for. Capping here keeps every control legible at three accessibility sizes
            // and keeps the protein on screen. The reading matter - the onboarding cards and
            // About, which are text and nothing else - is presented as a sheet and is
            // deliberately not capped.
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        }
        .preferredColorScheme(.dark)
        .task {
            // `PHONEFOLD_ENGINE` picks the engine at launch, which is the only way to reach
            // the picker's other options without tapping a simulator.
            let override = ProcessInfo.processInfo.environment["PHONEFOLD_ENGINE"]
                .flatMap(FoldingEngine.init(rawValue:))
            if let override { runner.engine = override }
            // `PHONEFOLD_ACCESSION` folds a downloaded structure straight from launch, which
            // is the only way to exercise the fetch path without typing into a simulator.
            if let wanted = ProcessInfo.processInfo.environment["PHONEFOLD_ACCESSION"],
               !wanted.isEmpty {
                accession = wanted
                runner.fetchAndRun(accession: wanted, engine: runner.engine, into: player)
            } else if selection == nil, let opening = openingEntry {
                start(opening)
            }
        }
        .onChange(of: runner.engine) { previous, current in
            // Only when the engine actually changes, and never for the launch override, which
            // sets the engine and then starts a run itself. Without the guard the override
            // started two runs, the first was cancelled by the second, and the cancelled one's
            // error replaced the healthy state with "cancelled".
            guard previous != current else { return }
            if runner.engine.needsReferenceStructure {
                if let selection { start(selection) }
            } else {
                runner.generate(seed: generationSeed, into: player)
            }
        }
    }

    /// The title, the colour control and About.
    ///
    /// **`ViewThatFits` rather than one row.** At an accessibility text size the title, a
    /// four-segment picker and the info button together are wider than a phone, and SwiftUI's
    /// response to that is to clip - measured: the title rendered as "Phon..." with its left
    /// edge off-screen, and the picker's right edge off the other side. Given a second
    /// arrangement it picks the one that fits instead, which puts the colour control on its own
    /// line exactly when it needs one and leaves the compact layout alone otherwise.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                titleBlock
                Spacer()
                colourPicker
                aboutButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    titleBlock
                    Spacer()
                    aboutButton
                }
                colourPicker
            }
        }
        // Accepts the offered width. In a VStack every child is proposed the same width and the
        // stack takes the widest reported ideal, so one child that asks for more makes the
        // whole column wider than the phone - and the column is then centred, which is why the
        // layout bled off *both* edges at the largest accessibility size rather than just the
        // right.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var titleBlock: some View {
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
                    // Wrapped, and that is not cosmetic. The diagnostic is one long
                    // unbroken monospaced line, and an unwrapped `Text` reports its full
                    // length as its ideal width - which made the whole control column wider
                    // than the phone and pushed every row off both edges. A debug overlay that
                    // breaks the layout it exists to diagnose is worse than no overlay: it
                    // sent this session chasing a clipping bug that only existed while the
                    // overlay was on.
                    Text(player.diagnostic + "  " + meshDiagnostic)
                        .scaledFont(10, design: .monospaced, relativeTo: .caption)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
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
                // What to listen for, once there is something to listen to.
                if let note = selection.flatMap({ listeningNotes[$0.id] }) {
                    Text(note.note)
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x8A93A8))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
    }

    private var colourPicker: some View {
        Picker("Colour", selection: $player.colourMode) {
            ForEach(ColourMode.allCases, id: \.self) { mode in
                Text(mode.shortName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 380)
    }

    private var aboutButton: some View {
        Button { isShowingAbout = true } label: {
            Image(systemName: "info.circle")
                .scaledFont(16, relativeTo: .body)
                .foregroundStyle(Color(hex: 0x6B7C93))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About PhoneFold")
    }

    private var gallery: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(library.entries) { entry in
                    Button { start(entry) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName).font(.caption.weight(.medium))
                            // The headline where the length used to be. A gallery of thirteen
                            // proteins all captioned "N residues" tells the visitor nothing
                            // about which one to press; "It never resolves - and that is
                            // correct" does.
                            Text(listeningNotes[entry.id]?.headline ?? entry.subtitle)
                                .scaledFont(10, relativeTo: .caption)
                                .foregroundStyle(Color(hex: 0x6B7C93))
                                .lineLimit(1)
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
        // **`maxWidth` as well as `height`, and the width is the load-bearing half.** A
        // horizontal scroll view reports its *content's* width as its ideal, and thirteen
        // gallery cards are far wider than a phone. In a VStack the stack takes the widest
        // ideal any child reports, so this one row made the entire control column 465.67 points
        // on a 402-point screen - and the column was then centred, which is why the layout bled
        // off *both* edges at the largest accessibility text size while looking fine at the
        // default. Measured with `.measured(_:)`: every other row came back at 425.67, which is
        // 465.67 less its own padding, so every one of them was a passenger.
        .frame(maxWidth: .infinity)
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
    /// Offer the piece that was played as a standard MIDI file.
    ///
    /// **One code path for every platform.** The first version used `NSSavePanel` on the Mac
    /// and wrote into the temporary directory on iOS - which on iOS is a place the user cannot
    /// reach, so the button would have appeared to work and delivered nothing. `fileExporter`
    /// is a save panel on the Mac and a document picker on iOS, and there is nothing to keep
    /// in step.
    private func exportMIDI() {
        guard let data = player.midiExport() else {
            midiMessage = "Nothing to export yet - play a fold first."
            return
        }
        midiDocument = MIDIDocument(data: data)
        isExportingMIDI = true
    }

    /// Fold the wild type and a mutant together.
    private func foldDuet() {
        guard let entry = selection,
              let style = player.orderedStyles.first(where: { $0.id == player.styleID })
                  ?? player.orderedStyles.first else { return }
        do {
            let provider = try library.provider(for: entry)
            guard let final = provider.readouts.last else { return }
            let reference = ReferenceStructure(
                accession: provider.metadata.accession ?? entry.id,
                name: provider.metadata.name,
                sequence: provider.metadata.sequence,
                caPositions: final.caPositions.map {
                    SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z))
                },
                pLDDT: final.confidence)
            runner.runDuet(reference: reference, mutationText: mutation, style: style,
                           into: player)
        } catch {
            print("could not start the duet: \(error)")
        }
    }

    /// Render the fold that is on screen as a film and put it in Photos.
    private func exportFilm() {
        guard let provider = player.exportProvider,
              let style = player.orderedStyles.first(where: { $0.id == player.styleID })
                  ?? player.orderedStyles.first else { return }
        film.export(provider: provider, style: style, colourMode: player.colourMode,
                    name: selection?.id ?? provider.metadata.name)
    }

    private func start(_ entry: TrajectoryLibrary.Entry) {
        selection = entry
        do {
            let provider = try library.provider(for: entry)
            guard runner.engine.needsReferenceStructure else {
                // Genie 2 invents a protein; the gallery selection is irrelevant to it.
                runner.generate(seed: generationSeed, into: player)
                return
            }
            guard let final = provider.readouts.last else {
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
            // A plain fold is not a duet: anything prepared for one must go, or the next run
            // would play the previous comparison over a single protein.
            player.clearDuet()
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
