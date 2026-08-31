import SwiftUI

/// Screen three: PLAN.md's "Standalone Fold of the Day".
///
/// "One precomputed short trajectory per day, playable on the Watch alone as a small animation
/// with haptics. No inference, no phone required."
///
/// The screen exists now and says what it will be; the trajectory and its playback are P5b-06.
/// A placeholder that claims to be finished would be the exact thing this project forbids, so
/// this one says plainly that it is not built yet rather than showing an empty animation that
/// looks broken.
struct FoldOfTheDayView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Fold of the Day")
                .font(.headline)
            Text("A short fold a day, with haptics, without the phone. Not built yet.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .navigationTitle("Daily")
    }
}
