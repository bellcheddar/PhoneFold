import SwiftUI
import FoldSync

/// Screen two: what the fold sounds like and what it looks like on the phone.
///
/// The two pickers share a screen because they are the same kind of choice - how the fold is
/// presented, not what is folding - and because three screens is the ceiling.
struct VoicingView: View {
    @EnvironmentObject private var model: WatchModel

    /// The phone's own lists, in a stable order. Empty until the phone has said anything,
    /// which is honest: the wrist does not know what the phone can offer until it is told.
    private var styles: [(id: String, name: String)] {
        (model.state?.styles ?? [:]).map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }
    private var colourModes: [(id: String, name: String)] {
        (model.state?.colourModes ?? [:]).map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        List {
            Section("Style") {
                ForEach(styles, id: \.id) { style in
                    Button {
                        model.send(.style(style.id))
                    } label: {
                        HStack {
                            Text(style.name)
                            Spacer()
                            if model.state?.styleID == style.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    // Selection is a tick as well as a colour, because the Watch's own tint
                    // is the only colour available and it is not enough on its own.
                    .accessibilityAddTraits(model.state?.styleID == style.id ? [.isSelected] : [])
                }
            }
            Section("Colour") {
                ForEach(colourModes, id: \.id) { mode in
                    Button {
                        model.send(.colourMode(mode.id))
                    } label: {
                        HStack {
                            Text(mode.name)
                            Spacer()
                            if model.state?.colourMode == mode.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityAddTraits(
                        model.state?.colourMode == mode.id ? [.isSelected] : [])
                }
            }

            if styles.isEmpty && colourModes.isEmpty {
                Text("Connect to the phone to see what it can play.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Voicing")
    }
}
