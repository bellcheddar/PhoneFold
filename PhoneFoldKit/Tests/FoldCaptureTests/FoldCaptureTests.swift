import Testing
@testable import FoldCapture

@Suite("FoldCapture")
struct FoldCaptureTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldCapture.version == "0.1.0")
    }
}
