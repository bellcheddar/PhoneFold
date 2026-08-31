import Foundation
import FoldCore

/// What to fold in a batch, read from a FASTA file or a plain list of accessions.
///
/// PLAN.md Phase 5a: "Batch mode: drop a multi-record FASTA or a list of accessions, fold them
/// all, produce a film per protein overnight. This is the feature that makes it useful rather
/// than a toy."
///
/// **A FASTA gives sequences, and PhoneFold cannot fold a sequence.** That is worth stating
/// plainly rather than discovering at item 30 of an overnight run. There is no
/// sequence-to-structure model here: ESMFold was dropped as the engine in Phase 0, and the two
/// engines that fold toward something need a structure to fold toward. So what a batch actually
/// consumes is **accessions**, and a FASTA is accepted because UniProt's own headers carry one:
/// `>sp|P69905|HBA_HUMAN`. A FASTA whose headers carry no accession is rejected with that reason
/// rather than being silently turned into a list of failed lookups.
///
/// The sequence is still read, and it is not decoration: it is checked against the sequence
/// AlphaFold returns for the same accession. A mismatch means the file describes a different
/// isoform or a construct, and the fold would be of something other than what the file says.
public struct BatchInput: Sendable, Equatable {

    /// Which kind of identifier a record names.
    ///
    /// **Two kinds, because the two resolve from different places.** A UniProt accession is
    /// what AlphaFold's API takes, and is what a batch of real work will use. A PDB entry id
    /// resolves from nothing online here - `AlphaFoldClient` does not take one - but it is what
    /// the bundled trajectories are keyed by, and it is what a structural biologist actually has
    /// in the clipboard. Naming the kind lets the *resolver* decide what it can serve, instead
    /// of the parser guessing.
    public enum Kind: String, Sendable, Equatable {
        case uniProt
        case pdb
    }

    /// One protein to fold.
    public struct Item: Sendable, Equatable {
        public let accession: String
        public let kind: Kind
        /// The entry name from a FASTA header (`HBA_HUMAN`), when there was one.
        public let label: String?
        /// The sequence the file claims, for checking against what is fetched. Empty for a
        /// plain accession list, which carries no sequence to disagree with.
        public let sequence: String

        public init(accession: String, kind: Kind = .uniProt, label: String? = nil,
                    sequence: String = "") {
            self.accession = accession
            self.kind = kind
            self.label = label
            self.sequence = sequence
        }
    }

    /// A line that could not be used, and why. Kept rather than dropped: a batch that quietly
    /// folds 3 of a 50-record file is worse than one that says which 47 it could not read.
    public struct Rejection: Sendable, Equatable {
        public let line: Int
        public let text: String
        public let reason: String
    }

    public var items: [Item]
    public var rejections: [Rejection]

    public init(items: [Item], rejections: [Rejection] = []) {
        self.items = items
        self.rejections = rejections
    }

    // MARK: - Accession recognition

    /// UniProt's own accession pattern, from their FAQ, plus an optional isoform suffix.
    ///
    /// **Written out rather than approximated as "six alphanumerics".** A loose pattern accepts
    /// `HBA_HUMAN` and every other header word, and the failure then happens one network round
    /// trip later, per record, as a 404 that looks like the database's fault.
    static let accessionPattern =
        "[OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9]([A-Z][A-Z0-9]{2}[0-9]){1,2}"

    static let accessionRegex = try! NSRegularExpression(
        pattern: "^(?:\(accessionPattern))(-[0-9]+)?$")

    /// A PDB entry id, optionally with an entity or chain suffix: `1UBQ`, `1UBQ_1`, `6VXX_A`.
    ///
    /// Four characters, the first a digit, which is the actual rule and is what keeps it from
    /// swallowing ordinary header words.
    static let pdbRegex = try! NSRegularExpression(
        pattern: "^[0-9][A-Z0-9]{3}([_-][A-Z0-9]{1,4})?$")

    /// Whether a token is a UniProt accession.
    public static func isAccession(_ token: String) -> Bool {
        matches(accessionRegex, token)
    }

    /// Whether a token is a PDB entry id.
    public static func isPDBIdentifier(_ token: String) -> Bool {
        matches(pdbRegex, token)
    }

    /// What kind of identifier this is, if any.
    public static func kind(of token: String) -> Kind? {
        if isAccession(token) { return .uniProt }
        if isPDBIdentifier(token) { return .pdb }
        return nil
    }

    static func matches(_ regex: NSRegularExpression, _ token: String) -> Bool {
        let upper = token.uppercased()
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        return regex.firstMatch(in: upper, range: range) != nil
    }

    // MARK: - Parsing

    /// Read a FASTA file or a plain list.
    ///
    /// The two are told apart by the presence of `>` rather than by a file extension, because a
    /// batch list dragged onto the app has whatever name the user gave it.
    public static func parse(_ text: String) -> BatchInput {
        text.contains(">") ? parseFASTA(text) : parseList(text)
    }

    /// One accession per line. `#` starts a comment; blank lines are skipped.
    static func parseList(_ text: String) -> BatchInput {
        var items: [Item] = []
        var rejections: [Rejection] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let line = raw.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // A whole line, not a first token: "P69905 haemoglobin" is a list with a comment
            // nobody marked, and folding it would be folding the wrong thing silently.
            let token = line.split(separator: " ").first.map(String.init) ?? line
            if let kind = kind(of: token) {
                items.append(Item(accession: token.uppercased(), kind: kind))
            } else {
                rejections.append(Rejection(
                    line: index + 1, text: line,
                    reason: "\"\(token)\" is not a UniProt accession or a PDB id"))
            }
        }
        return deduplicated(BatchInput(items: items, rejections: rejections))
    }

    /// Multi-record FASTA. Accessions come from the header; sequences are kept for the check.
    static func parseFASTA(_ text: String) -> BatchInput {
        var items: [Item] = []
        var rejections: [Rejection] = []
        var pending: (item: Item, line: Int)?
        var sequence = ""

        func flush() {
            guard let pending else { return }
            items.append(Item(accession: pending.item.accession, kind: pending.item.kind,
                              label: pending.item.label, sequence: sequence))
        }

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") {
                flush()
                pending = nil
                sequence = ""
                let header = String(line.dropFirst())
                if let parsed = accession(inHeader: header) {
                    pending = (Item(accession: parsed.accession, kind: parsed.kind,
                                    label: parsed.label), index + 1)
                } else {
                    rejections.append(Rejection(
                        line: index + 1, text: header,
                        reason: "no UniProt accession or PDB id in the header"))
                }
            } else if !line.isEmpty, pending != nil {
                // Residue letters only. A FASTA that has picked up line numbers or a stray
                // digit would otherwise produce a sequence that silently fails the check
                // against AlphaFold for the wrong reason.
                sequence += line.uppercased().filter { $0.isLetter }
            }
        }
        flush()
        return deduplicated(BatchInput(items: items, rejections: rejections))
    }

    /// Pull the accession and entry name out of a FASTA header.
    ///
    /// Handles UniProt's `sp|P69905|HBA_HUMAN`, a bare `>P69905`, and `>P69905 description`.
    static func accession(inHeader header: String)
        -> (accession: String, kind: Kind, label: String?)? {
        let bars = header.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if bars.count >= 2, let kind = kind(of: bars[1]) {
            let label = bars.count >= 3
                ? bars[2].split(separator: " ").first.map(String.init) : nil
            return (bars[1].uppercased(), kind, label)
        }
        // No bars, or the second field was not an identifier: try each whitespace-separated
        // word, so ">P69905 Haemoglobin subunit alpha" works.
        for word in header.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let kind = kind(of: String(word)) {
                return (String(word).uppercased(), kind, nil)
            }
        }
        return nil
    }

    /// Drop repeats, keeping the first.
    ///
    /// An overnight batch that folds the same protein twice has wasted an hour, and a list
    /// pasted together from two sources overlaps more often than not.
    static func deduplicated(_ input: BatchInput) -> BatchInput {
        var seen: Set<String> = []
        var items: [Item] = []
        var rejections = input.rejections
        for item in input.items {
            if seen.insert(item.accession).inserted {
                items.append(item)
            } else {
                rejections.append(Rejection(line: 0, text: item.accession,
                                            reason: "repeated; the first one is kept"))
            }
        }
        return BatchInput(items: items, rejections: rejections)
    }
}
