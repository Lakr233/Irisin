@testable import irisin
import Testing

@MainActor
struct PathListTests {
    /// `-` sorts before `/`, so a sibling whose name extends a directory's
    /// must not come between that directory and its children.
    @Test func aDirectoryKeepsItsChildrenBeforeTheNextSibling() {
        let sorted = PathListController.expandingAncestors(of: [
            "/usr/libexec/irisind",
            "/usr/libexec/irisin-install",
            "/usr/libexec/irisin/icli",
        ])
        #expect(sorted == [
            "/usr",
            "/usr/libexec",
            "/usr/libexec/irisin",
            "/usr/libexec/irisin/icli",
            "/usr/libexec/irisin-install",
            "/usr/libexec/irisind",
        ])
    }
}
