import Testing
@testable import FoldAudio

@Suite("FoldAudio")
struct FoldAudioTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldAudio.version == "0.1.0")
    }
}
