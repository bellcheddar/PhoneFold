import SwiftUI
import FoldSync

/// Screen one: what is folding, how far through, and the transport.
struct NowPlayingView: View {
    @EnvironmentObject private var model: WatchModel
    /// The Crown's own value, which is the scrub position while the user is turning it.
    @State private var crown: Double = 0
    @State private var isScrubbing = false

    private var state: FoldRemote.State? { model.state }

    var body: some View {
        VStack(spacing: 6) {
            if let state {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: isScrubbing ? crown : state.progress)
                        .stroke(Color(red: 0.56, green: 0.71, blue: 1),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        if let confidence = state.meanConfidence {
                            Text("\(Int(confidence.rounded()))")
                                .font(.title2.monospacedDigit())
                            Text(state.confidenceLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(Int(((isScrubbing ? crown : state.progress)) * 100))%")
                                .font(.title2.monospacedDigit())
                        }
                    }
                }
                .frame(height: 84)
                // PLAN: "Digital Crown scrubs the timeline, which is a genuinely lovely fit."
                .focusable()
                .digitalCrownRotation($crown, from: 0, through: 1, by: 0.01,
                                      sensitivity: .medium, isContinuous: false)
                .onChange(of: crown) { _, value in
                    isScrubbing = true
                    model.send(.scrub(value))
                }

                Button {
                    model.send(state.isPlaying ? .pause : .play)
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            } else {
                // **Says which of the two silences this is.** A wrist showing nothing could
                // mean the phone is not folding or that it cannot be reached, and those want
                // different things from the user.
                Image(systemName: model.isReachable ? "atom" : "iphone.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(model.isReachable ? "Nothing folding" : "Phone not reachable")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { model.refreshReachability() }
        .navigationTitle("PhoneFold")
    }
}
