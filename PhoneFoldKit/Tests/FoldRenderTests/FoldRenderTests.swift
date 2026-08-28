import Testing
@testable import FoldRender

@Suite("FoldRender")
struct FoldRenderTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldRender.version == "0.1.0")
    }
}
