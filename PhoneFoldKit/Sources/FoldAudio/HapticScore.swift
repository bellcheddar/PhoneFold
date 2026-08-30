import Foundation

/// One thing the fold asks the device to do to the listener's hand.
///
/// Deliberately not a `CHHapticEvent`. Which moments produce which feelings is the interesting
/// part and is the same on a phone and a watch; playing them is a platform detail with hardware
/// that may not exist. Keeping the two apart means the mapping can be asserted exactly rather
/// than felt for, which is the same reason the musical clock has no audio framework in it.
public struct HapticEvent: Sendable, Hashable {

    public enum Kind: String, Sendable, Hashable {
        /// A tap. Contact formation.
        case transient
        /// A sustained low rumble, tracking how tightly the core is packed.
        case rumble
        /// The fold resolving. Its own shape, so it cannot be mistaken for another contact.
        case convergence
    }

    public let kind: Kind
    /// Beats from the start of the moment that produced it.
    public let beatOffset: Double
    /// 0...1.
    public let intensity: Double
    /// 0...1. Higher is crisper; a long-range contact is sharper than a local one.
    public let sharpness: Double
    /// Beats. Zero for a transient.
    public let duration: Double

    public init(kind: Kind, beatOffset: Double, intensity: Double, sharpness: Double,
                duration: Double = 0) {
        self.kind = kind
        self.beatOffset = beatOffset
        self.intensity = Swift.min(Swift.max(intensity, 0), 1)
        self.sharpness = Swift.min(Swift.max(sharpness, 0), 1)
        self.duration = Swift.max(duration, 0)
    }
}

/// Turns a bar of music into what the hand feels.
///
/// PLAN.md: "`CoreHaptics` on iPhone and Watch: transient on contact formation, sharper for
/// long-range, a low rumble tracking core packing, a distinct pattern at convergence."
///
/// **The haptics come from the same moments the music does**, not from a second pass over the
/// trajectory. A tap that did not land with its note would feel like a fault rather than like
/// the same event reaching two senses.
public enum HapticScore {

    /// The most taps one moment may ask for.
    ///
    /// A bar can carry sixteen contact onsets, and sixteen taps in a beat is not sixteen
    /// sensations - it is a buzz, and it wears the actuator out for nothing. Six is about as
    /// many as a hand resolves in a beat, and the ones kept are the ones that carry the fold.
    public static let maximumTaps = 6

    /// Below this, a contact is not worth a tap: it would be felt as noise under the ones that
    /// matter rather than as an event of its own.
    static let minimumIntensity = 0.15

    /// What one moment should feel like.
    public static func events(for moment: ScoreMoment) -> [HapticEvent] {
        var events: [HapticEvent] = []

        // Contacts, in the order the music sounds them. A long-range contact is sharper: it is
        // two parts of the chain that were far apart meeting, and it should feel like a
        // different event from a turn of a helix closing.
        let contacts = moment.notes.filter { $0.voice == .contact || $0.voice == .bass }
        for note in contacts.prefix(maximumTaps) {
            let separation = note.partner.map { abs($0 - note.residue) } ?? 0
            // Local contacts are dull taps, long-range ones crisp. The boundaries are
            // `ContactRange`'s own, so the feel and the register agree about what a contact is.
            let sharpness = separation >= 12 ? 0.85 : (separation >= 6 ? 0.55 : 0.3)
            let intensity = Double(note.note.velocity) / 127
            guard intensity >= minimumIntensity else { continue }
            events.append(HapticEvent(kind: .transient, beatOffset: note.beatOffset,
                                      // Core packing is the one worth feeling hardest.
                                      intensity: note.voice == .bass
                                          ? Swift.min(intensity * 1.25, 1) : intensity,
                                      sharpness: sharpness))
        }

        // The rumble, tracking how tightly the chain is packed. It runs the whole moment, so
        // successive bars join into one continuous sensation that tightens as the fold does.
        //
        // Silent below a third: an unfolded chain that buzzed continuously would be a constant
        // rather than a signal, and the whole point is that it grows.
        if moment.compaction > 0.33 {
            let scaled = (moment.compaction - 0.33) / 0.67
            events.append(HapticEvent(kind: .rumble, beatOffset: 0,
                                      intensity: 0.15 + 0.45 * scaled,
                                      sharpness: 0.1,
                                      duration: moment.beats))
        }

        // Convergence: its own shape, once. Long, soft and rising, so it cannot be mistaken
        // for another contact however many are landing around it.
        if moment.isCadence {
            events.append(HapticEvent(kind: .convergence, beatOffset: 0,
                                      intensity: 0.8, sharpness: 0.25,
                                      duration: Swift.max(moment.beats, 2)))
        }

        return events.sorted {
            $0.beatOffset != $1.beatOffset ? $0.beatOffset < $1.beatOffset
                : $0.kind.rawValue < $1.kind.rawValue
        }
    }
}
