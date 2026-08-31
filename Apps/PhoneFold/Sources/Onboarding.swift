import SwiftUI
import FoldAudio

/// The three cards a first-time user sees.
///
/// PLAN.md Phase 4: "three cards. What it does, what the music means, and the disclaimer".
///
/// **The disclaimer is not softened and not buried.** PLAN.md gives its wording and says "Marc
/// will be asked about this and the app should answer first" - so it is the last thing before
/// the app opens, in the same type as everything else rather than in small print, and a short
/// form of it stays permanently in About.
struct Onboarding: View {

    /// PLAN.md's exact words. Changing them is a decision, not an edit.
    static let disclaimer = """
        PhoneFold visualises how a neural network converges on a structure. It is not a \
        physical folding pathway, and no protein folds this way.
        """

    struct Card: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let body: String
        /// The disclaimer card is set apart, because it is the one that must be read.
        var isDisclaimer = false
    }

    static let cards: [Card] = [
        Card(id: 0, symbol: "atom", title: "A protein folds on your phone",
             body: """
                 Everything runs on the device. A sequence is folded here, frame by frame, and \
                 nothing about it leaves the phone. Choose a protein, or fetch one by \
                 accession, and watch it find its shape.
                 """),
        Card(id: 1, symbol: "music.note.list", title: "The music is the fold",
             body: """
                 Every note comes from the trajectory rather than from the sequence. A contact \
                 forming is an onset, and how far apart in the chain its two halves are sets \
                 how high it sounds. Helices are a sustained pad, sheets a staccato figure, \
                 coils an arpeggio. As the chain compacts the tempo rises, and when the \
                 structure settles the harmony resolves.

                 Confidence is audible: an uncertain region is dull and out of tune, so a \
                 disordered protein never resolves at all. A trained ear can hear a bad \
                 prediction.
                 """),
        Card(id: 2, symbol: "exclamationmark.triangle", title: "What this is not",
             body: disclaimer, isDisclaimer: true),
    ]

    @Binding var isPresented: Bool
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Self.cards) { card in
                    cardView(card).tag(card.id)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .always))
            #endif

            Button {
                if page < Self.cards.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    Onboarding.markSeen()
                    isPresented = false
                }
            } label: {
                Text(page < Self.cards.count - 1 ? "Next" : "Start folding")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 320)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color(hex: 0x2B5CE6)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 28)
        }
        .frame(minWidth: 380, minHeight: 460)
        .background(
            LinearGradient(colors: [Color(hex: 0x181432), Color(hex: 0x0B0A1F)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    private func cardView(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: card.symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(card.isDisclaimer ? Color(hex: 0xFCB900) : Color(hex: 0x4A9FD4))
            Text(card.title)
                .font(.system(.title2, design: .default).weight(.semibold))
                .foregroundStyle(.white)
            Text(card.body)
                .font(.callout)
                .foregroundStyle(card.isDisclaimer ? .white : Color(hex: 0xB6BFD0))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, 30)
    }

    // MARK: - Whether it has been seen

    /// **Not `@AppStorage`.** The stage needs this value in a `@State` initialiser, to decide
    /// whether to present the sheet at all, and a property wrapper cannot be read there - it
    /// only exists once the view does. Reading `UserDefaults` directly works in both places.
    ///
    /// Versioned in the key, so that a materially different introduction can be shown again to
    /// someone who dismissed the old one rather than being silently skipped.
    static let seenKey = "phonefold.onboarding.seen.v1"

    static var hasBeenSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    static func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }

    /// For the About screen's "show it again", and for testing.
    static func forget() { UserDefaults.standard.removeObject(forKey: seenKey) }
}
