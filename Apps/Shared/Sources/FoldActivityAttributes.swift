#if os(iOS)
import ActivityKit
import FoldCore

/// The Live Activity's identity, wrapped around `FoldActivitySnapshot`.
///
/// **Compiled into both the app and the widget extension from this one file**, rather than
/// duplicated. Duplicated, the two copies encode differently the first time a field is added on
/// one side, and the failure is a Live Activity that silently stops updating rather than a build
/// error.
///
/// The guard is `os(iOS)` and not `canImport(ActivityKit)`, which was measured: ActivityKit
/// imports perfectly well on macOS and then every symbol in it is unavailable, so `canImport`
/// compiles the block and the build fails inside it. `canImport` answers a question about the
/// module, not about the platform.
struct FoldActivityAttributes: ActivityAttributes {
    typealias ContentState = FoldActivitySnapshot

    /// Fixed for the life of the activity.
    var proteinName: String
    var engineName: String
}
#endif
