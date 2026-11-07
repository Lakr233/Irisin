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

    /// The export is the page's list, one path a line, and a path is bytes.
    @Test func theExportIsOnePathALine() {
        let text = PathListController.listText(["/usr", "/usr/share/résumé 文件"])
        #expect(String(decoding: text, as: UTF8.self) == "/usr\n/usr/share/résumé 文件\n")
        #expect(PathListController.listText([]).isEmpty)
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
