import Foundation

/// A protein sequence with its identifying metadata.
///
/// Named `ProteinSequence` rather than PLAN.md's `Sequence` because the latter would shadow
/// the Swift standard library protocol at every use site in this package.
public struct ProteinSequence: Sendable, Hashable, Identifiable {
    /// The FASTA header without its leading `>`, empty for a bare sequence.
    public let header: String
    /// One-letter codes, upper-cased, with gaps and stops already removed.
    public let letters: String

    public var id: String { header.isEmpty ? letters : header }
    public var count: Int { letters.count }
    public var isEmpty: Bool { letters.isEmpty }
    public var residues: [AminoAcid] { letters.map(AminoAcid.init(code:)) }

    /// The accession, where the header follows the UniProt convention `db|accession|entry`.
    public var accession: String? {
        let parts = header.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return String(parts[1])
    }

    /// Protein name from a UniProt header: the text between the entry name and the first
    /// `OS=` field. Returns nil for headers that do not follow the convention.
    public var proteinName: String? {
        guard let range = header.range(of: " ") else { return nil }
        let rest = header[range.upperBound...]
        let name = rest.components(separatedBy: " OS=").first ?? String(rest)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Organism from a UniProt header's `OS=` field, up to the next `XX=` field.
    public var organism: String? {
        guard let osRange = header.range(of: " OS=") else { return nil }
        let rest = header[osRange.upperBound...]
        // Fields are ` XX=`; find the next one and cut there.
        var organism = String(rest)
        for field in ["OX=", "GN=", "PE=", "SV="] {
            if let r = organism.range(of: " \(field)") {
                organism = String(organism[..<r.lowerBound])
            }
        }
        let trimmed = organism.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    public init(header: String = "", letters: String) {
        self.header = header
        self.letters = letters
    }
}

// MARK: - Parsing

public enum FASTAError: Error, CustomStringConvertible, Equatable {
    case empty
    case noResidues(header: String)
    case tooShort(count: Int, minimum: Int)
    case tooLong(count: Int, maximum: Int)
    case unexpectedCharacters(Set<Character>, header: String)

    public var description: String {
        switch self {
        case .empty:
            "That file or text has nothing in it."
        case .noResidues(let header):
            header.isEmpty
                ? "No residues found."
                : "The record \"\(header)\" has a header but no residues under it."
        case .tooShort(let count, let minimum):
            "A protein needs at least \(minimum) residues to fold; this has \(count)."
        case .tooLong(let count, let maximum):
            "This sequence is \(count) residues. The current limit is \(maximum)."
        case .unexpectedCharacters(let chars, let header):
            Self.unexpectedMessage(chars, header)
        }
    }

    private static func unexpectedMessage(_ chars: Set<Character>, _ header: String) -> String {
        let list = chars.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
        return header.isEmpty
            ? "Unexpected characters in the sequence: \(list)."
            : "Unexpected characters in \"\(header)\": \(list)."
    }
}

public enum FASTA {

    /// Characters that are silently removed rather than treated as residues:
    /// alignment gaps, translation stops, and whitespace of any kind.
    static let strippable: Set<Character> = ["-", ".", "*", " ", "\t"]

    /// Parse one or more FASTA records. Also accepts a bare sequence with no header, which
    /// is what someone pasting from a paper or a text field will usually produce.
    ///
    /// Wrapped lines are joined, lower case is upper-cased, and gaps and stops are stripped.
    /// Ambiguity codes (`B`, `Z`, `J`, `X`, `U`, `O`) are **kept** and resolve to
    /// `AminoAcid.unknown`: a sequence with a `B` in it should still fold. Anything else,
    /// such as a digit or a punctuation mark, is an error, because it usually means the
    /// input was not a sequence at all.
    public static func parse(_ text: String) throws -> [ProteinSequence] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FASTAError.empty
        }

        var records: [(header: String, lines: [Substring])] = []
        // Split on `isNewline`, not on "\n". In Swift "\r\n" is a SINGLE Character (a
        // grapheme cluster), so `split(separator: "\n")` does not match it at all and a
        // Windows file arrives as one enormous line with the header glued to the residues.
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if line.hasPrefix(">") || line.hasPrefix(";") {
                records.append((String(line.dropFirst()).trimmingCharacters(in: .whitespaces), []))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if records.isEmpty { records.append(("", [])) }
                records[records.count - 1].lines.append(line)
            }
        }

        guard !records.isEmpty else { throw FASTAError.empty }

        return try records.map { record in
            var kept = ""
            var unexpected: Set<Character> = []
            for line in record.lines {
                for character in line {
                    let upper = Character(String(character).uppercased())
                    if strippable.contains(upper) { continue }
                    if upper.isLetter {
                        kept.append(upper)
                    } else {
                        unexpected.insert(character)
                    }
                }
            }
            if !unexpected.isEmpty {
                throw FASTAError.unexpectedCharacters(unexpected, header: record.header)
            }
            guard !kept.isEmpty else { throw FASTAError.noResidues(header: record.header) }
            return ProteinSequence(header: record.header, letters: kept)
        }
    }

    /// Parse and return the single record, rejecting a multi-record file.
    public static func parseOne(_ text: String) throws -> ProteinSequence {
        let all = try parse(text)
        return all[0]
    }

    /// Validate a sequence against the engine's length limits.
    ///
    /// The minimum is 8: below that there is no fold to watch and P-SEA has nothing to work
    /// with. The maximum is the caller's, because it differs by device and engine.
    public static func validate(_ sequence: ProteinSequence,
                                minimum: Int = 8,
                                maximum: Int) throws {
        if sequence.count < minimum {
            throw FASTAError.tooShort(count: sequence.count, minimum: minimum)
        }
        if sequence.count > maximum {
            throw FASTAError.tooLong(count: sequence.count, maximum: maximum)
        }
    }

    /// Render as FASTA with the conventional 60-column wrap.
    public static func format(_ sequence: ProteinSequence, columns: Int = 60) -> String {
        var out = sequence.header.isEmpty ? "" : ">\(sequence.header)\n"
        var index = sequence.letters.startIndex
        while index < sequence.letters.endIndex {
            let end = sequence.letters.index(index, offsetBy: columns,
                                             limitedBy: sequence.letters.endIndex)
                ?? sequence.letters.endIndex
            out += sequence.letters[index..<end] + "\n"
            index = end
        }
        return out
    }
}
