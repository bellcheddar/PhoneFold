import SwiftUI
import Combine
import FoldCore
import FoldSync

/// Screen three: PLAN.md's "Standalone Fold of the Day".
///
/// "One precomputed short trajectory per day, playable on the Watch alone as a small animation
/// with haptics. No inference, no phone required."
///
/// **Alone is the requirement and it is met literally**: nothing here asks the phone anything,
/// and this screen works with the phone off, in a drawer, or never paired. What it draws is
/// baked into the app - `FoldOfTheDay` in `FoldCore`, written by
/// `Tools/make_fold_of_the_day.py` - because the wrist runs no inference and no geometry
/// either. Decoding a trajectory, building a mesh and tracking contacts on a wrist is exactly
/// the ambition PLAN warns Watch apps die of.
struct FoldOfTheDayView: View {
    @StateObject private var model = DailyFoldModel()

    var body: some View {
        Group {
            if let fold = model.fold {
                playing(fold)
            } else {
                unavailable
            }
        }
        .navigationTitle("Daily")
        .onAppear {
            // Only ever under the launch variable. See `WatchLaunch`: watchOS has no input
            // injection, so without this the animation can be built and shipped without
            // anything outside a wrist ever having seen it run.
            if WatchLaunch.autoplaysDailyFold, let fold = model.fold, !model.isPlaying {
                model.start(fold)
            }
        }
        .onDisappear { model.stop() }
    }

    /// **The protein gets the screen.**
    ///
    /// It was a `VStack` of canvas, title, subtitle and button, and the canvas measured
    /// itself at 204 x 63 pt: the chrome had taken three quarters of a 46 mm watch and the
    /// fold was drawing at a quarter of the size it should, because `draw` scales by
    /// `min(width, height)` and the height was 63. Nothing about that is visible from the
    /// code - the layout is unremarkable and every modifier does what it says.
    ///
    /// So the text sits *over* the fold rather than beside it, and the whole screen is the
    /// button. PLAN.md's "a concert, not a workbench" happens to be the answer to a layout
    /// problem here as well as an aesthetic one.
    private func playing(_ fold: DailyFold) -> some View {
        ZStack(alignment: .bottom) {
            Canvas { context, size in
                draw(fold, at: model.time, in: context, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                Text(fold.name)
                    .font(.caption2).lineLimit(1).minimumScaleFactor(0.6)
                // What it is, said plainly. This is a simulated fold arriving near a
                // predicted structure, and one line is what it costs not to imply otherwise.
                Text("\(fold.residueCount) residues · \(Int((fold.quality.nativeFraction * 100).rounded()))% native contacts")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(model.isPlaying ? "Tap to stop" : "Tap to fold")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
            // Legible over a protein that may be any colour behind it.
            .background(
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -18)
                    .allowsHitTesting(false))
        }
        // The whole screen, not a button: there is no room for chrome and nothing else here
        // to tap by mistake.
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isPlaying { model.stop() } else { model.start(fold) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(fold.name), \(fold.residueCount) residues"))
        .accessibilityHint(Text(model.isPlaying ? "Stops the fold" : "Folds it"))
        .accessibilityAddTraits(.isButton)
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("Fold of the Day")
                .font(.headline)
            Text(model.problem ?? "Nothing baked for today.")
                .font(.footnote).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    /// The chain, N to C, in the stage's own rainbow.
    ///
    /// **Eight bands rather than a colour per residue.** A stroke per segment is 75 draw calls
    /// a frame for ubiquitin at thirty frames a second on a watch; eight is the same picture,
    /// because a rainbow along a chain carries no detail an eighth of its length wide.
    private func draw(_ fold: DailyFold, at time: Double,
                      in context: GraphicsContext, size: CGSize) {
        let points = fold.chain(at: time, range: model.range)
        guard points.count > 1 else { return }

        // The same scale on both axes. The projection is already square in its own units, and
        // stretching it to the view would draw a protein that is not this shape.
        let side = min(size.width, size.height)
        // 0.42, not 0.46: each frame is centred on its own centroid and the widest frame
        // reaches the edge of the quantised box exactly, so this is the whole coil against
        // the whole screen with a little air round it.
        let scale = side * 0.42
        // Lifted, because the caption sits over the bottom of the canvas: centring on the
        // canvas would put part of the coil behind the text on every fold.
        let origin = CGPoint(x: size.width / 2, y: size.height * 0.43)
        func place(_ point: (x: Double, y: Double)) -> CGPoint {
            // Minus y: the projection is right-handed and the canvas is not.
            CGPoint(x: origin.x + point.x * scale, y: origin.y - point.y * scale)
        }

        let bands = 8
        for band in 0..<bands {
            let lower = band * (points.count - 1) / bands
            let upper = (band + 1) * (points.count - 1) / bands
            guard upper > lower else { continue }
            var path = Path()
            path.move(to: place(points[lower]))
            for index in (lower + 1)...upper { path.addLine(to: place(points[index])) }
            context.stroke(path,
                           with: .color(Self.rainbow(Double(band) / Double(bands - 1))),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round,
                                              lineJoin: .round))
        }
    }

    /// N terminus blue through to C terminus red, the same direction the stage uses, so a
    /// glance at the wrist and a glance at the phone mean the same thing.
    static func rainbow(_ t: Double) -> Color {
        Color(hue: 0.66 * (1 - min(max(t, 0), 1)), saturation: 0.85, brightness: 1)
    }
}

/// What the wrist knows about today's fold: the resource, the clock and the haptics.
///
/// **A timer rather than a `TimelineView`.** The haptics have to fire as frames go by, and a
/// `TimelineView` would mean deciding that from inside the view's own body - mutating state
/// during a view update, which SwiftUI is entitled to complain about and entitled to run twice.
/// The clock belongs to the model; the view only draws what it says.
@MainActor
final class DailyFoldModel: ObservableObject {

    @Published private(set) var fold: DailyFold?
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var problem: String?

    private(set) var range = 1000
    private var ticker: AnyCancellable?
    private var startedAt: Date?
    private var haptics = WristHaptics()
    private var lastFrame: Int?

    /// Thirty a second. The baked trajectory is ninety frames over six seconds and
    /// `DailyFold.chain(at:)` interpolates between them, so this is how smooth it looks rather
    /// than how much data there is - and thirty is where a wrist stops being able to tell.
    private static let tickRate = 1.0 / 30

    init() {
        guard let url = Bundle.main.url(forResource: "FoldOfTheDay", withExtension: "json") else {
            problem = "The daily fold is missing from this build."
            return
        }
        do {
            let library = try DailyFoldLibrary.decode(try Data(contentsOf: url))
            range = library.quantisedRange
            fold = library.fold()
            if fold == nil { problem = "Nothing baked for today." }
        } catch {
            // Said plainly rather than shown as an empty screen: a blank canvas looks like a
            // fold that has not started, and waiting for it is worse than being told.
            problem = "\(error)"
        }
    }

    func start(_ fold: DailyFold) {
        haptics.reset()
        lastFrame = nil
        time = 0
        startedAt = Date()
        isPlaying = true
        WristHapticPlayer.play(haptics.began(at: Date.timeIntervalSinceReferenceDate))
        ticker = Timer.publish(every: Self.tickRate, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick(of: fold) }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        startedAt = nil
        lastFrame = nil
    }

    /// Advance the clock, fire the haptics frames deserve, and stop at the end.
    ///
    /// The same `WristHaptics` the phone uses to decide what a live fold feels like, so the
    /// daily fold and a fold coming off the phone feel like one thing rather than two features
    /// that happen to buzz.
    private func tick(of fold: DailyFold) {
        guard let startedAt else { return }
        time = Date().timeIntervalSince(startedAt)
        guard time < fold.duration else {
            // The arrival, then hold on the folded structure rather than looping: a fold that
            // restarts is a screensaver, and this one has an ending.
            WristHapticPlayer.play(haptics.finished(at: Date.timeIntervalSinceReferenceDate))
            time = fold.duration
            stop()
            return
        }
        let index = fold.frameIndex(at: time)
        guard index != lastFrame else { return }
        lastFrame = index
        if let cue = haptics.contacts(fold.frames[index].newContacts,
                                      at: Date.timeIntervalSinceReferenceDate) {
            WristHapticPlayer.play(cue)
        }
    }
}
