import Foundation

/// A standard MIDI file written from a score, and read back from one.
///
/// PLAN.md Phase 3: "Parallel MIDI event log written as the music plays, for export and for the
/// Mac's CoreMIDI out", with an exit gate of "MIDI export parses correctly and round-trips".
///
/// **Format 1, with a real tempo map.** The accelerando is the whole point of the radius-of-
/// gyration mapping, so a file that baked one tempo in would export a different piece from the
/// one that played. Musical positions are therefore in ticks, which are tempo-independent, and
/// every change of tempo is a set-tempo event on the conductor track - which is what a DAW
/// expects and what makes the imported piece speed up the way the fold did.
///
/// The parser exists because the gate asks the export to round-trip, and a writer checked only
/// against its own reader is a weak test - so the reader is written from the specification's
/// byte layout rather than from the writer, and the tests pin the actual bytes as well.
public enum MIDIFile {

    /// Ticks per quarter note.
    ///
    /// 480 is the usual choice and divides cleanly by the smallest note the score writes: a
    /// contact flurry is semiquavers, 120 ticks, and a texture voice can place four to a beat.
    /// A coarser division would quantise the flurry onto the beat and lose the run.
    public static let ticksPerQuarter = 480

    /// One channel per voice, so a DAW can give each its own instrument. Channel 9 is skipped:
    /// it is General MIDI's drum channel and anything landing there would be played as
    /// percussion whatever the note said.
    public static func channel(for voice: Voice) -> UInt8 {
        UInt8(voice.slot)
    }

    // MARK: - Writing

    /// Variable-length quantity, seven bits at a time, high bit set on all but the last.
    static func variableLength(_ value: Int) -> [UInt8] {
        var v = Swift.max(value, 0)
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8((v & 0x7F) | 0x80), at: 0)
            v >>= 7
        }
        return bytes
    }

    static func bigEndian(_ value: Int, bytes count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8((value >> (8 * $0)) & 0xFF) }
    }

    static func chunk(_ name: String, _ body: [UInt8]) -> [UInt8] {
        Array(name.utf8) + bigEndian(body.count, bytes: 4) + body
    }

    /// One event on its way into a track, before delta times are worked out.
    struct Event {
        var tick: Int
        /// Orders events landing on the same tick. Note-offs first, so a repeated note is
        /// released before it is struck again rather than being cut off by its own predecessor.
        var priority: Int
        var bytes: [UInt8]
    }

    static func track(named name: String, events: [Event]) -> [UInt8] {
        var body: [UInt8] = [0x00, 0xFF, 0x03] + variableLength(name.utf8.count) + Array(name.utf8)
        var previous = 0
        for event in events.sorted(by: {
            $0.tick != $1.tick ? $0.tick < $1.tick : $0.priority < $1.priority
        }) {
            body += variableLength(event.tick - previous)
            body += event.bytes
            previous = event.tick
        }
        body += [0x00, 0xFF, 0x2F, 0x00]        // end of track
        return chunk("MTrk", body)
    }

    /// One note on its way into a track, before overlaps are resolved.
    struct PendingNote {
        var voice: Voice
        var pitch: UInt8
        var velocity: UInt8
        var start: Int
        var end: Int
    }

    /// Cut short any note still sounding when the same pitch is struck again on its channel.
    ///
    /// **MIDI cannot express two of the same pitch overlapping on one channel**, and the score
    /// asks for exactly that: the pad sustains four beats and a new one starts every beat, so
    /// the same chord tone overlaps itself four deep. A note-on for a pitch already sounding is
    /// ambiguous - a reader has no way to tell which of the two a later note-off ends - and
    /// measured on a real ubiquitin fold it lost 10 of 71 notes on the round trip.
    ///
    /// Truncating the earlier note at the later one's onset is what a DAW does and what makes
    /// the file unambiguous. The synthesiser is unaffected: it gives every note its own voice,
    /// so what is heard still has the overlap. Only the exported file, which has to be a file
    /// another program can read, does not.
    static func resolveOverlaps(_ notes: [PendingNote]) -> [PendingNote] {
        var byKey: [Int: [Int]] = [:]
        for (index, note) in notes.enumerated() {
            byKey[Int(channel(for: note.voice)) << 8 | Int(note.pitch), default: []].append(index)
        }
        var resolved = notes
        for indices in byKey.values {
            let ordered = indices.sorted { resolved[$0].start < resolved[$1].start }
            for (position, index) in ordered.enumerated() where position + 1 < ordered.count {
                let next = resolved[ordered[position + 1]].start
                if resolved[index].end > next { resolved[index].end = next }
            }
        }
        // A note truncated to nothing is dropped rather than written as a zero-length event,
        // which some readers show as a note and others as nothing. This happens only where two
        // notes of the same pitch begin on the same tick of the same channel - the same
        // musical instant twice - which MIDI has no way to tell apart however it is written.
        // The synthesiser gives each its own voice and both are heard.
        return resolved.filter { $0.end > $0.start }
    }

    /// Write a whole score as a format 1 file.
    public static func encode(_ score: [ScoreMoment], style: StyleProfile) -> Data {
        // Conductor track: the tempo map, and the piece's name.
        var conductor: [Event] = []
        var pending: [PendingNote] = []

        var tick = 0
        var lastTempo = -1.0
        for moment in score {
            if abs(moment.tempo - lastTempo) > 0.001 {
                // Microseconds per quarter note.
                let microseconds = Int((60_000_000 / Swift.max(moment.tempo, 1)).rounded())
                conductor.append(Event(tick: tick, priority: 0,
                                       bytes: [0xFF, 0x51, 0x03]
                                           + bigEndian(microseconds, bytes: 3)))
                lastTempo = moment.tempo
            }
            for note in moment.notes {
                let onset = tick + Int((note.beatOffset * Double(ticksPerQuarter)).rounded())
                let length = Swift.max(Int((note.duration * Double(ticksPerQuarter)).rounded()), 1)
                pending.append(PendingNote(voice: note.voice, pitch: note.note.pitch,
                                           velocity: note.note.velocity,
                                           start: onset, end: onset + length))
            }
            tick += Int((moment.beats * Double(ticksPerQuarter)).rounded())
        }

        var voiceEvents: [Voice: [Event]] = [:]
        for note in resolveOverlaps(pending) {
            let channel = channel(for: note.voice)
            voiceEvents[note.voice, default: []].append(Event(
                tick: note.start, priority: 1,
                bytes: [0x90 | channel, note.pitch, note.velocity]))
            voiceEvents[note.voice, default: []].append(Event(
                tick: note.end, priority: 0,
                bytes: [0x80 | channel, note.pitch, 0x40]))
        }

        // A stable track order, so the same score writes the same bytes every time.
        let voices = Voice.allCases.filter { voiceEvents[$0]?.isEmpty == false }
        var tracks = [track(named: style.name, events: conductor)]
        for voice in voices {
            tracks.append(track(named: voice.rawValue, events: voiceEvents[voice] ?? []))
        }

        let header = chunk("MThd", bigEndian(1, bytes: 2)                // format 1
                           + bigEndian(tracks.count, bytes: 2)
                           + bigEndian(ticksPerQuarter, bytes: 2))
        return Data(header + tracks.flatMap { $0 })
    }

    // MARK: - Reading

    public struct Note: Sendable, Hashable {
        public let channel: UInt8
        public let pitch: UInt8
        public let velocity: UInt8
        public let tick: Int
        public let lengthInTicks: Int
    }

    public struct Parsed: Sendable {
        public var format: Int
        public var ticksPerQuarter: Int
        public var trackNames: [String]
        public var notes: [Note]
        /// Tick and microseconds-per-quarter for every tempo change.
        public var tempoChanges: [(tick: Int, microsecondsPerQuarter: Int)]

        /// Beats per minute at each change, which is what a reader actually wants to compare.
        public var tempi: [(tick: Int, bpm: Double)] {
            tempoChanges.map { ($0.tick, 60_000_000 / Double($0.microsecondsPerQuarter)) }
        }
    }

    public enum Malformed: Error, CustomStringConvertible, Equatable {
        case notAMIDIFile
        case truncated(String)
        case unsupportedDivision(Int)

        public var description: String {
            switch self {
            case .notAMIDIFile: "That is not a standard MIDI file."
            case .truncated(let where_): "The file ends part way through \(where_)."
            case .unsupportedDivision(let value):
                "SMPTE timing (division \(value)) is not supported; this writes ticks per quarter."
            }
        }
    }

    /// Read a standard MIDI file.
    ///
    /// Written from the byte layout in the specification rather than from `encode`, so that a
    /// round-trip test is a test of both rather than of one mistake made twice. It handles
    /// running status and skips meta and system-exclusive events it does not need, which is
    /// what a file from any other writer will contain.
    public static func decode(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        var offset = 0

        func need(_ count: Int, _ what: String) throws {
            guard offset + count <= bytes.count else { throw Malformed.truncated(what) }
        }
        func read(_ count: Int, _ what: String) throws -> Int {
            try need(count, what)
            var value = 0
            for _ in 0..<count { value = (value << 8) | Int(bytes[offset]); offset += 1 }
            return value
        }
        func readVariableLength(_ what: String) throws -> Int {
            var value = 0
            for _ in 0..<4 {
                try need(1, what)
                let byte = bytes[offset]
                offset += 1
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw Malformed.truncated(what)
        }

        try need(14, "the header")
        guard String(decoding: bytes[0..<4], as: UTF8.self) == "MThd" else {
            throw Malformed.notAMIDIFile
        }
        offset = 4
        let headerLength = try read(4, "the header length")
        let format = try read(2, "the format")
        let trackCount = try read(2, "the track count")
        let division = try read(2, "the division")
        guard division > 0, division & 0x8000 == 0 else {
            throw Malformed.unsupportedDivision(division)
        }
        // Header chunks may be longer than six bytes in a later revision; skip the surplus
        // rather than assuming, which is what the specification asks readers to do.
        offset = 8 + headerLength

        var names: [String] = []
        var notes: [Note] = []
        var tempi: [(tick: Int, microsecondsPerQuarter: Int)] = []

        for _ in 0..<trackCount {
            try need(8, "a track header")
            guard String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self) == "MTrk" else {
                throw Malformed.truncated("a track header")
            }
            offset += 4
            let length = try read(4, "a track length")
            let end = offset + length
            guard end <= bytes.count else { throw Malformed.truncated("a track") }

            var tick = 0
            var status: UInt8 = 0
            /// Notes struck and not yet released, by channel and pitch.
            var sounding: [Int: (tick: Int, velocity: UInt8)] = [:]

            while offset < end {
                tick += try readVariableLength("a delta time")
                try need(1, "an event")
                var byte = bytes[offset]
                if byte & 0x80 != 0 {
                    status = byte
                    offset += 1
                    byte = status
                } else {
                    // Running status: the previous status byte is implied.
                    byte = status
                }

                switch byte {
                case 0xFF:
                    try need(1, "a meta event")
                    let type = bytes[offset]
                    offset += 1
                    let payload = try readVariableLength("a meta event length")
                    try need(payload, "a meta event")
                    if type == 0x03 {
                        names.append(String(decoding: bytes[offset..<(offset + payload)],
                                            as: UTF8.self))
                    } else if type == 0x51, payload == 3 {
                        tempi.append((tick, (Int(bytes[offset]) << 16)
                                            | (Int(bytes[offset + 1]) << 8)
                                            | Int(bytes[offset + 2])))
                    }
                    offset += payload
                case 0xF0, 0xF7:
                    let payload = try readVariableLength("a system exclusive length")
                    try need(payload, "a system exclusive event")
                    offset += payload
                default:
                    let kind = byte & 0xF0
                    let channel = byte & 0x0F
                    let dataBytes = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                    try need(dataBytes, "a channel event")
                    let first = bytes[offset]
                    let second = dataBytes == 2 ? bytes[offset + 1] : 0
                    offset += dataBytes
                    let key = Int(channel) << 8 | Int(first)
                    // A note-on with velocity zero is a note-off. Files in the wild use it far
                    // more often than 0x80, and a reader that ignored it would report every
                    // note as running to the end of the piece.
                    if kind == 0x90, second > 0 {
                        sounding[key] = (tick, second)
                    } else if kind == 0x80 || (kind == 0x90 && second == 0) {
                        if let started = sounding.removeValue(forKey: key) {
                            notes.append(Note(channel: channel, pitch: first,
                                              velocity: started.velocity, tick: started.tick,
                                              lengthInTicks: tick - started.tick))
                        }
                    }
                }
            }
            offset = end
        }

        notes.sort {
            $0.tick != $1.tick ? $0.tick < $1.tick
                : ($0.channel != $1.channel ? $0.channel < $1.channel : $0.pitch < $1.pitch)
        }
        return Parsed(format: format, ticksPerQuarter: division, trackNames: names,
                      notes: notes, tempoChanges: tempi)
    }
}
