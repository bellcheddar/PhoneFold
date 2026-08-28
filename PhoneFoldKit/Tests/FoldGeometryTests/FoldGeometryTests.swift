import Testing
@testable import FoldGeometry

@Suite("FoldGeometry")
struct FoldGeometryTests {
    @Test("module identity is present")
    func moduleIdentity() {
        #expect(FoldGeometry.version == "0.1.0")
    }
}
