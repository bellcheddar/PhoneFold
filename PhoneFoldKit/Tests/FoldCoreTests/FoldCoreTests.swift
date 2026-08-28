import Testing
@testable import FoldCore

@Suite("FoldCore")
struct FoldCoreTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldCore.version == "0.1.0")
    }
}
