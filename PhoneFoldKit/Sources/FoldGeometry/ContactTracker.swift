import Foundation
import simd
import FoldCore

/// Tracks which residue pairs are in contact and emits an event when one forms.
///
/// PLAN.md Phase 3 maps a contact formation to a note onset, so what matters is the
/// **transition**, not the state. A pair that stays in contact for two hundred frames is one
/// note, not two hundred.
///
/// Two details keep it musical:
///
/// * **Hysteresis.** A pair forms at `formationCutoff` and only breaks once it exceeds
///   `breakCutoff`. Without the gap, a pair sitting exactly on 8 A chatters in and out and
///   machine-guns the sequencer.
/// * **Interpolated frames are never fed in.** The engine only advances the tracker on raw
///   model readouts. Feeding it 60 fps of interpolation would fire the same contact
///   repeatedly as the spline wobbles across the threshold.
public struct ContactTracker: Sendable {

    /// Inward crossing distance, in angstroms. 8 A between CA atoms is the usual definition.
    public let formationCutoff: Float
    /// Outward distance at which a contact is considered broken. Deliberately larger.
    public let breakCutoff: Float
    /// Pairs closer than this in sequence are neighbours along the chain, not contacts.
    public let minimumSeparation: Int

    private var inContact: [Bool]
    private var residueCount: Int

    public init(formationCutoff: Float = 8.0,
                breakCutoff: Float = 8.5,
                minimumSeparation: Int = 3) {
        precondition(breakCutoff >= formationCutoff,
                     "break cutoff must not be below the formation cutoff")
        self.formationCutoff = formationCutoff
        self.breakCutoff = breakCutoff
        self.minimumSeparation = minimumSeparation
        self.inContact = []
        self.residueCount = 0
    }

    /// Contacts currently held.
    public var activeContactCount: Int { inContact.lazy.filter { $0 }.count }

    /// Feed one **raw** frame and get the contacts that formed on it.
    ///
    /// Events come back in a stable order, sorted by sequence separation then by first
    /// residue, so the same trajectory always produces the same sequence of notes. PLAN.md
    /// Phase 3 requires the same protein to yield the same piece.
    public mutating func update(caPositions ca: [SIMD3<Float>],
                                residues: [AminoAcid]) -> [ContactEvent] {
        let n = ca.count
        if n != residueCount {
            residueCount = n
            inContact = [Bool](repeating: false, count: n * n)
        }
        guard n > minimumSeparation else { return [] }

        var formed: [ContactEvent] = []
        for i in 0..<(n - minimumSeparation) {
            for j in (i + minimumSeparation)..<n {
                let distance = simd_distance(ca[i], ca[j])
                let slot = i * n + j
                if inContact[slot] {
                    if distance > breakCutoff { inContact[slot] = false }
                } else if distance <= formationCutoff {
                    inContact[slot] = true
                    let a = i < residues.count ? residues[i] : .unknown
                    let b = j < residues.count ? residues[j] : .unknown
                    formed.append(ContactEvent(
                        i: i, j: j, distance: distance,
                        isHydrophobicPair: a.isHydrophobic && b.isHydrophobic))
                }
            }
        }
        formed.sort { ($0.separation, $0.i) < ($1.separation, $1.i) }
        return formed
    }

    /// Forget all state, for replaying a trajectory from the beginning.
    public mutating func reset() {
        inContact = [Bool](repeating: false, count: residueCount * residueCount)
    }

    /// Every pair currently in contact, for a one-off map rather than a stream of events.
    public static func contactMap(caPositions ca: [SIMD3<Float>],
                                  cutoff: Float = 8.0,
                                  minimumSeparation: Int = 3) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        let n = ca.count
        guard n > minimumSeparation else { return pairs }
        for i in 0..<(n - minimumSeparation) {
            for j in (i + minimumSeparation)..<n where simd_distance(ca[i], ca[j]) <= cutoff {
                pairs.append((i, j))
            }
        }
        return pairs
    }
}
