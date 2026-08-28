import Testing
@testable import FoldSync

@Suite("FoldSync")
struct FoldSyncTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldSync.version == "0.1.0")
    }
}
