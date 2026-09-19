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

    /// Each path is walked up a component a turn, to the root or to nothing.
    @Test func aPathThatIsNotOneStillEnds() {
        let odd = ["", "/", "//", "///a//", "a", "./", "../..", "/a/\u{034F}", "\u{034F}/", "/a\u{0301}/b\r\n/"]
        let sorted = PathListController.expandingAncestors(of: odd)
        #expect(!sorted.contains(""))
        #expect(!sorted.contains("/"))
        #expect(sorted.contains("/a"))
    }
}
