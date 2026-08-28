import Foundation
import FoldCore
import FoldEngine

/// The bundled sample gallery.
///
/// PLAN.md Phase 4 wants twelve one-tap demos each with a note on what to listen for; the
/// note travels in the trajectory's own metadata, so the gallery is just whatever `.pftraj`
/// files are in the bundle rather than a second list to keep in step.
@MainActor
final class TrajectoryLibrary: ObservableObject {

    struct Entry: Identifiable {
        let id: String
        let url: URL
        let metadata: TrajectoryMetadata

        var displayName: String { metadata.name }
        var subtitle: String {
            var parts = ["\(metadata.residueCount) residues"]
            if let organism = metadata.organism, !organism.hasPrefix("none") {
                parts.append(organism)
            }
            if metadata.provenance.isGenerated { parts.append("generated") }
            return parts.joined(separator: " · ")
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loadError: String?

    init() { reload() }

    func reload() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "pftraj",
                                          subdirectory: nil) else {
            loadError = "No trajectories are bundled with this build."
            return
        }
        var found: [Entry] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let bundle = try TrajectoryBundleCodec.read(contentsOf: url)
                // A test fixture must never reach a user as a fold.
                guard bundle.metadata.provenance.isShippable else { continue }
                found.append(Entry(id: url.lastPathComponent, url: url,
                                   metadata: bundle.metadata))
            } catch {
                // One bad file must not empty the gallery.
                print("skipping \(url.lastPathComponent): \(error)")
            }
        }
        entries = found.sorted { $0.metadata.residueCount < $1.metadata.residueCount }
        loadError = entries.isEmpty ? "No usable trajectories were found." : nil
    }

    func provider(for entry: Entry) throws -> SampleTrajectoryProvider {
        try SampleTrajectoryProvider(contentsOf: entry.url)
    }
}
