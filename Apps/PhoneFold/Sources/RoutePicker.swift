import SwiftUI
import AVKit

/// The system's audio route picker.
///
/// PLAN.md Phase 4: "`AVRoutePickerView` in the transport bar for audio route selection."
///
/// **The system control, not a list of our own.** Route selection is one of the places where
/// reimplementing the platform's UI is actively wrong: the picker knows about AirPlay 2 groups,
/// nearby speakers, hearing devices and CarPlay, and a hand-rolled list would offer a subset
/// while looking authoritative. It is also the only way to reach some routes at all.
struct RoutePicker: View {
    var body: some View {
        #if os(iOS) || os(tvOS)
        RoutePickerRepresentable()
            .frame(width: 32, height: 32)
            .accessibilityLabel("Audio output")
            .accessibilityHint("Choose where the music plays: this device, AirPlay, or a "
                               + "connected speaker")
        #else
        // macOS has no AVRoutePickerView: output is chosen in Sound settings or the menu bar,
        // and a button here would either do nothing or duplicate a system control badly.
        EmptyView()
        #endif
    }
}

#if os(iOS) || os(tvOS)
private struct RoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        // The stage is near-black, so the default dark glyph would be invisible on it.
        view.tintColor = UIColor(red: 0.42, green: 0.62, blue: 0.90, alpha: 1)
        view.activeTintColor = UIColor(red: 0.17, green: 0.36, blue: 0.90, alpha: 1)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
