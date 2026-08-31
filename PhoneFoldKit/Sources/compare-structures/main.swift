import Foundation
import FoldCore
import FoldGeometry

// PLAN.md Phase 5a's structure comparison, on the command line. Studio's drag-and-drop surface
// calls the same `StructureComparison`; this is what can be checked without a window.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: compare-structures <prediction.cif|pdb> <experimental.cif|pdb>
                              [--chain X] [--offset N] [--worst N]

    Superposes the prediction onto the experimental structure and reports the RMSD and the
    residues that deviate most. Residues are matched by **number**, not by position, because a
    crystal structure is usually missing its disordered ends and a prediction is not.

    If the two files number from 1 and mean different things by it, this says so and suggests
    the --offset that lines them up rather than reporting a confident wrong number.

    """.utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let mobilePath = arguments.removeFirst()
let referencePath = arguments.removeFirst()
var chain: String?
var worst = 10
var offset = 0
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--chain":
        index += 1
        guard index < arguments.count else { usage() }
        chain = arguments[index]
    case "--offset":
        index += 1
        guard index < arguments.count else { usage() }
        offset = Int(arguments[index]) ?? 0
    case "--worst":
        index += 1
        guard index < arguments.count else { usage() }
        worst = Int(arguments[index]) ?? 10
    default: usage()
    }
    index += 1
}

do {
    func load(_ path: String) throws -> StructureFile {
        let url = URL(fileURLWithPath: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try StructureFile.read(text,
                                      identifier: url.deletingPathExtension().lastPathComponent)
    }
    let mobile = try load(mobilePath)
    let reference = try load(referencePath)
    print("prediction:   \(mobile.identifier)  \(mobile.residues.count) residues, "
          + "chains \(mobile.chains.joined(separator: ","))")
    print("experimental: \(reference.identifier)  \(reference.residues.count) residues, "
          + "chains \(reference.chains.joined(separator: ","))")

    let result = try StructureComparison.compare(mobile: mobile, reference: reference,
                                                 chain: chain, offset: offset)
    print("")
    print(result.summary)
    if !result.onlyInMobile.isEmpty || !result.onlyInReference.isEmpty {
        // Spelled out rather than summarised: a comparison over a quarter of the protein is a
        // different claim from one over all of it, and the ranges say which.
        func ranges(_ numbers: [Int]) -> String {
            guard !numbers.isEmpty else { return "none" }
            var parts: [String] = []
            var start = numbers[0], previous = numbers[0]
            for number in numbers.dropFirst() {
                if number != previous + 1 {
                    parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
                    start = number
                }
                previous = number
            }
            parts.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            return parts.joined(separator: ", ")
        }
        print("only in the prediction:   \(ranges(result.onlyInMobile))")
        print("only in the experimental: \(ranges(result.onlyInReference))")
    }
    print("")
    print("worst \(min(worst, result.matched)) residues:")
    for deviation in result.worst(worst) {
        // **Not `%s`.** `String(format:)` bridges to C varargs, and handing a Swift `String`
        // to `%s` is undefined behaviour: this segfaulted on the first real file it was given,
        // having been perfectly happy in every synthetic test, because the tests never
        // formatted a residue name.
        let number = String(format: "%4d", deviation.number)
        let distance = String(format: "%6.2f", deviation.deviation)
        let b = String(format: "%.1f", deviation.referenceBFactor)
        let name = deviation.name.padding(toLength: 4, withPad: " ", startingAt: 0)
        print("  \(number) \(name) \(distance) Å   (reference B \(b))")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
