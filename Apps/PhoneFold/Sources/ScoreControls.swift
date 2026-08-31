import SwiftUI
import UniformTypeIdentifiers
import FoldAudio

/// The score's own row: sound on or off, which style, and where the MIDI goes.
///
/// Styles are laid out like the engine picker, which is the same kind of choice - a small,
/// exclusive set the user changes while watching - and a second visual idiom for the same
/// gesture would only ask them to learn it twice.
struct ScoreControls: View {
    @Binding var isSoundOn: Bool
    /// The styles that shipped in the bundle, in a stable order.
    let styles: [StyleProfile]
    @Binding var styleID: String
    /// What the music is doing, or why it is not.
    let diagnostic: String
    let onExportMIDI: (() -> Void)?

    private var selected: StyleProfile? {
        styles.first { $0.id == styleID } ?? styles.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    isSoundOn.toggle()
                } label: {
                    Label(isSoundOn ? "Sound" : "Silent",
                          systemImage: isSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isSoundOn
                                                   ? Color(hex: 0x2B5CE6)
                                                   : Color.white.opacity(0.08)))
                        .foregroundStyle(isSoundOn ? .white : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)

                ForEach(styles) { style in
                    Button {
                        styleID = style.id
                    } label: {
                        Text(style.name)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(styleID == style.id
                                               ? Color(hex: 0x2B5CE6)
                                               : Color.white.opacity(0.08)))
                            .foregroundStyle(isSoundOn ? .white : Color.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    // Not hidden when the sound is off: a control that vanishes takes its
                    // meaning with it, and the style is still what the piece would be.
                    .disabled(!isSoundOn)
                }

                Spacer(minLength: 0)

                if let onExportMIDI {
                    Button(action: onExportMIDI) {
                        Label("MIDI", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSoundOn)
                }
            }

            // The style's own description, on the same footing as the engine's: what this
            // sounds like, and the reference behind it where there is one.
            Text(diagnostic.isEmpty ? (selected?.summary ?? "No style profiles are bundled.")
                                    : diagnostic)
                .font(.system(size: 10))
                .foregroundStyle(Color(hex: 0x6B7C93))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where the music came from, in the app's own words.
///
/// PLAN.md asks for the Tay et al. citation to appear in About, because the pitch layer is
/// their approach and a paper that shaped the work is named rather than absorbed.
enum ScoreCredits {

    static let pitchLayer = """
        The pitch each residue sings is an amino-acid property mapping after Tay, Khoo and \
        Loh, Heliyon 2021, 7(9):e07933, doi:10.1016/j.heliyon.2021.e07933, whose \
        Fantasy-Impromptu approach uses arginine, lysine, aspartate and glutamate as \
        octave-shift triggers. Everything above that layer - every onset, every chord change, \
        the tempo and the cadence - comes from the trajectory rather than the sequence.
        """

    static let disorder = """
        An intrinsically disordered region never resolves, so it stays a detuned wash for the \
        whole piece. A trained ear can hear a bad prediction.
        """

    static let synthesis = """
        Every voice is synthesised on the device. Nothing is sampled and no sound bank is \
        bundled, so what you hear was computed from the fold rather than played back.
        """
}

/// The exported MIDI, wrapped so `fileExporter` can write it.
///
/// A `FileDocument` rather than a URL because the same declaration then serves a save panel on
/// the Mac and a document picker on iOS. Writing to a URL of the app's own choosing would work
/// on one and be unreachable on the other.
struct MIDIDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.midi] }
    static var writableContentTypes: [UTType] { [.midi] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// What the app is, what it claims, and whose work it stands on.
///
/// PLAN.md asks for the Tay et al. citation to appear here, and this is also the only place
/// with room to say the two things a viewer would otherwise get wrong: that the music comes
/// from the trajectory rather than the sequence, and that a disordered region never resolves.
struct AboutView: View {
    let style: StyleProfile?
    /// Whatever this trajectory's own claim is - generated, simulated, predicted.
    let disclosure: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PhoneFold")
                        .font(.system(.title, design: .default).weight(.semibold))
                    Text("A protein folds on the Neural Engine, and the fold is the score.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let disclosure {
                    section("This trajectory", disclosure)
                }
                if let style {
                    section("The style", "\(style.name). \(style.summary)")
                }
                section("The pitch layer", ScoreCredits.pitchLayer)
                section("Confidence", ScoreCredits.disorder)
                section("The sound", ScoreCredits.synthesis)

                Text("2026 Marc C. Deller")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .padding(16)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The export row: a preset, a button, and what it is doing.
///
/// Its own row under the score's, because an export is a different kind of act from choosing a
/// style - it takes a minute, it writes to the photo library, and it can fail for reasons the
/// user has to go to Settings to fix.
struct ExportControls: View {
    @Binding var preset: FilmExportController.Preset
    let state: FilmExportController.State
    let canExport: Bool
    let onExport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(FilmExportController.Preset.allCases) { candidate in
                    Button {
                        preset = candidate
                    } label: {
                        Text(candidate.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(preset == candidate
                                               ? Color(hex: 0x2B5CE6)
                                               : Color.white.opacity(0.08)))
                            .foregroundStyle(state.isBusy ? Color.white.opacity(0.35) : .white)
                    }
                    .buttonStyle(.plain)
                    // A preset changed mid-render would not apply to the render in flight, so
                    // offering it would be offering a control that does nothing.
                    .disabled(state.isBusy)
                }

                Spacer(minLength: 0)

                Button(action: state.isBusy ? onCancel : onExport) {
                    Label(state.isBusy ? "Cancel" : "Export film",
                          systemImage: state.isBusy ? "xmark" : "film")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(state.isBusy
                                                   ? Color.white.opacity(0.14)
                                                   : Color(hex: 0x2B5CE6)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(!canExport && !state.isBusy)
            }

            // A determinate bar rather than a spinner: a render is minutes long and a spinner
            // says only that something is happening, which is the one thing the user can
            // already see.
            if case .rendering(let fraction) = state {
                ProgressView(value: fraction)
                    .tint(Color(hex: 0x2B5CE6))
            }
            if !state.message.isEmpty {
                Text(state.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: 0x6B7C93))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
