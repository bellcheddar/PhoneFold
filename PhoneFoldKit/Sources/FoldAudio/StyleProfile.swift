import Foundation
import FoldCore

/// Which musical line a note belongs to.
///
/// One voice per row of PLAN.md's sonification table that produces sound, so the mapping can be
/// read against the table directly rather than through a layer of indirection.
public enum Voice: String, Sendable, Codable, CaseIterable, Hashable {
    /// A contact forming. The event that carries the fold.
    case contact
    /// Helix content: a sustained pad.
    case pad
    /// Sheet content: a staccato interlocking figure.
    case rhythm
    /// Coil content: arpeggiation between chord tones.
    case arpeggio
    /// Long-range hydrophobic contacts, and the harmonic floor.
    case bass
}

/// How a voice is synthesised.
///
/// **Synthesis parameters rather than an instrument name.** PLAN.md specified a bundled
/// SoundFont and flagged an unlicensed one as a halt; Marc chose to synthesise instead, which
/// removes the licence question entirely and leaves nothing to redistribute. What a style file
/// therefore describes is a timbre, not a patch number - and it stays declarative and tunable
/// without a recompile, which was the point of putting styles in JSON.
public struct VoiceSpec: Sendable, Codable, Hashable {

    public enum Waveform: String, Sendable, Codable, CaseIterable {
        case sine, triangle, sawtooth, square
        /// Two-operator FM, for bells and plucks that additive shapes do poorly.
        case fm
    }

    public var waveform: Waveform
    /// Amplitudes of successive harmonics, first entry the fundamental. Empty means the bare
    /// waveform. Additive stacking is what gives a pad its body without a sample behind it.
    public var harmonics: [Double]
    /// Seconds. A pad wants a long attack; a pluck wants none.
    public var attack: Double
    public var decay: Double
    /// 0...1, the level held while a note sustains.
    public var sustain: Double
    public var release: Double
    /// Cents of detune between stacked copies. Small amounts thicken; large amounts are the
    /// "murky and out of tune" that low confidence is supposed to sound like.
    public var detuneCents: Double
    /// FM only: the modulator's frequency as a multiple of the carrier's, and how hard it
    /// pushes. Ignored for the other waveforms.
    public var fmRatio: Double
    public var fmIndex: Double
    /// Waveshaping, 0 clean. Rock's "distortion depth" and Surf's grit; a soft saturation
    /// rather than a hard clip, so it adds harmonics without adding a rectangle.
    public var drive: Double
    /// Amplitude modulation: rate in hertz and depth 0...1. Surf's tremolo picking, and the
    /// only way a style can ask for a sound that moves while it is held.
    public var tremoloHz: Double
    public var tremoloDepth: Double
    /// Linear gain for this voice in the mix, before any dynamics.
    public var gain: Double

    public init(waveform: Waveform = .sine, harmonics: [Double] = [], attack: Double = 0.01,
                decay: Double = 0.1, sustain: Double = 0.7, release: Double = 0.3,
                detuneCents: Double = 0, fmRatio: Double = 2, fmIndex: Double = 1,
                drive: Double = 0, tremoloHz: Double = 0, tremoloDepth: Double = 0,
                gain: Double = 0.5) {
        self.waveform = waveform
        self.harmonics = harmonics
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
        self.detuneCents = detuneCents
        self.fmRatio = fmRatio
        self.fmIndex = fmIndex
        self.drive = drive
        self.tremoloHz = tremoloHz
        self.tremoloDepth = tremoloDepth
        self.gain = gain
    }

    /// Decoded with defaults, so a style file written before these existed still loads.
    ///
    /// Without this, adding a field to the schema silently breaks every style already on disk -
    /// including the ones a user has edited - which is the opposite of what putting styles in
    /// JSON was for.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waveform = try c.decodeIfPresent(Waveform.self, forKey: .waveform) ?? .sine
        harmonics = try c.decodeIfPresent([Double].self, forKey: .harmonics) ?? []
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? 0.01
        decay = try c.decodeIfPresent(Double.self, forKey: .decay) ?? 0.1
        sustain = try c.decodeIfPresent(Double.self, forKey: .sustain) ?? 0.7
        release = try c.decodeIfPresent(Double.self, forKey: .release) ?? 0.3
        detuneCents = try c.decodeIfPresent(Double.self, forKey: .detuneCents) ?? 0
        fmRatio = try c.decodeIfPresent(Double.self, forKey: .fmRatio) ?? 2
        fmIndex = try c.decodeIfPresent(Double.self, forKey: .fmIndex) ?? 1
        drive = try c.decodeIfPresent(Double.self, forKey: .drive) ?? 0
        tremoloHz = try c.decodeIfPresent(Double.self, forKey: .tremoloHz) ?? 0
        tremoloDepth = try c.decodeIfPresent(Double.self, forKey: .tremoloDepth) ?? 0
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0.5
    }
}

/// A complete musical style: key, tempo, voicings, timbres and the rules that pick between them.
///
/// Declarative and loaded from JSON, as PLAN.md requires, so a style can be retuned without a
/// recompile. Everything here is *musical* vocabulary; nothing in it knows about proteins. The
/// mapping from trajectory to music lives in `Sonifier`, which reads this.
public struct StyleProfile: Sendable, Codable, Hashable, Identifiable {

    public var id: String
    public var name: String
    /// One line for the About screen, and for anything that has to say what this sounds like.
    public var summary: String

    /// MIDI pitch of the tonic.
    public var root: UInt8
    public var mode: MusicalMode

    /// Beats per minute at the slowest and fastest. Radius of gyration drives the position
    /// between them: PLAN.md asks compaction to produce an accelerando, so a compact structure
    /// sits at the fast end.
    public var tempoSlow: Double
    public var tempoFast: Double
    /// 0 is straight, 0.5 is a triplet feel.
    public var swing: Double

    /// Chords as stacks of scale degrees above a root degree. Fantasy's fourths are `[0, 3, 6]`
    /// - a fourth is three scale steps - and a rootless seventh voicing is `[2, 4, 6]`.
    public var voicings: [[Int]]
    /// Which degrees a piece may sit on, in the order it prefers them. The last is the tonic it
    /// cadences to.
    public var progression: [Int]

    /// Keyed by `Voice.rawValue`, not by `Voice`.
    ///
    /// Swift encodes a dictionary whose keys are not `String` or `Int` as a flat *array* of
    /// alternating keys and values, so `[Voice: VoiceSpec]` would produce JSON no one could
    /// read or hand-edit - which defeats the purpose of putting styles in JSON at all.
    public var voices: [String: VoiceSpec]

    /// Residues that shift the pitch layer by an octave when they appear.
    ///
    /// Fantasy's is `R K D E`, the charged residues, following Tay et al. (Heliyon 2021,
    /// 7(9):e07933, doi:10.1016/j.heliyon.2021.e07933), whose approach PLAN.md asks for as the
    /// pitch layer beneath the trajectory events. Other styles may leave it empty.
    public var octaveShiftResidues: [String]

    public init(id: String, name: String, summary: String, root: UInt8, mode: MusicalMode,
                tempoSlow: Double, tempoFast: Double, swing: Double,
                voicings: [[Int]], progression: [Int], voices: [String: VoiceSpec],
                octaveShiftResidues: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.root = root
        self.mode = mode
        self.tempoSlow = tempoSlow
        self.tempoFast = tempoFast
        self.swing = swing
        self.voicings = voicings
        self.progression = progression
        self.voices = voices
        self.octaveShiftResidues = octaveShiftResidues
    }

    public var scale: MusicalScale { MusicalScale(root: root, mode: mode) }

    /// The timbre for a voice. Every profile is validated to have all of them, so this is
    /// total for any profile that came through `StyleLibrary`.
    public func spec(_ voice: Voice) -> VoiceSpec { voices[voice.rawValue] ?? VoiceSpec() }

    /// Does this profile describe a playable piece of music?
    ///
    /// Checked on load rather than trusted, because a style file is data a person edits by hand
    /// and a missing voice or an inverted tempo range fails as silence or a division by zero
    /// somewhere far from the mistake.
    public enum Invalid: Error, CustomStringConvertible, Equatable {
        case missingVoice(Voice)
        case emptyProgression
        case emptyVoicings
        case tempoRangeInverted(slow: Double, fast: Double)
        case tempoOutOfRange(Double)

        public var description: String {
            switch self {
            case .missingVoice(let voice): "The style has no \(voice.rawValue) voice."
            case .emptyProgression: "The style has no chord progression."
            case .emptyVoicings: "The style has no voicings."
            case .tempoRangeInverted(let slow, let fast):
                "The style's slow tempo (\(slow)) is above its fast tempo (\(fast))."
            case .tempoOutOfRange(let bpm): "\(bpm) BPM is not a usable tempo."
            }
        }
    }

    public func validate() throws {
        for voice in Voice.allCases where voices[voice.rawValue] == nil {
            throw Invalid.missingVoice(voice)
        }
        guard !progression.isEmpty else { throw Invalid.emptyProgression }
        guard !voicings.isEmpty else { throw Invalid.emptyVoicings }
        guard tempoSlow <= tempoFast else {
            throw Invalid.tempoRangeInverted(slow: tempoSlow, fast: tempoFast)
        }
        for bpm in [tempoSlow, tempoFast] where bpm < 20 || bpm > 300 {
            throw Invalid.tempoOutOfRange(bpm)
        }
    }

    /// Tempo for a given compaction, 0 unfolded and 1 fully compact.
    ///
    /// PLAN.md: "Radius of gyration - tempo and register. Compaction drives an accelerando."
    public func tempo(compaction: Double) -> Double {
        let t = Swift.min(Swift.max(compaction, 0), 1)
        return tempoSlow + (tempoFast - tempoSlow) * t
    }
}

/// Loads style profiles from JSON.
public enum StyleLibrary {

    public enum Failure: Error, CustomStringConvertible {
        case notFound(String)
        case invalid(String, StyleProfile.Invalid)

        public var description: String {
            switch self {
            case .notFound(let id): "No style named \(id)."
            case .invalid(let id, let reason): "The \(id) style is not playable: \(reason)"
            }
        }
    }

    /// Decode and validate a profile. Validation is not optional: a style file is hand-edited
    /// data, and an invalid one should say so here rather than fail as silence during a fold.
    public static func profile(from data: Data) throws -> StyleProfile {
        let profile = try JSONDecoder().decode(StyleProfile.self, from: data)
        do { try profile.validate() } catch let reason as StyleProfile.Invalid {
            throw Failure.invalid(profile.id, reason)
        }
        return profile
    }

    /// The styles that ship in the app bundle.
    ///
    /// `Styles` is a folder reference in the Xcode project, so the directory survives into the
    /// bundle and this finds them by subdirectory rather than by a flattened name.
    public static func bundled(in bundle: Bundle = .main) throws -> [String: StyleProfile] {
        guard let directory = bundle.url(forResource: "Styles", withExtension: nil) else {
            return [:]
        }
        return try profiles(in: directory)
    }

    /// Every `.json` in a directory, by id, skipping nothing silently.
    public static func profiles(in directory: URL) throws -> [String: StyleProfile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [String: StyleProfile] = [:]
        for url in urls where url.pathExtension == "json" {
            let profile = try Self.profile(from: try Data(contentsOf: url))
            loaded[profile.id] = profile
        }
        return loaded
    }
}
