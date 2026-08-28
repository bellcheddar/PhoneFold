import Testing
@testable import FoldEngine

@Suite("FoldEngine")
struct FoldEngineTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldEngine.version == "0.1.0")
    }
}
