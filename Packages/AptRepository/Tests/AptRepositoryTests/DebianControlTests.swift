import AptRepository
import Testing

struct DebianControlTests {
    @Test func continuationAndLiteralHash() throws {
        let fields = try DebianControl.parse("Package: aa\nDepends: bb,\n\tcc\nDescription: text # is literal\nConffiles:\n /etc/aa digest\n")
        #expect(fields["depends"] == "bb, cc")
        #expect(fields["description"] == "text # is literal")
        #expect(fields["conffiles"] == " /etc/aa digest")
    }

    @Test(arguments: ["Package: aa\nDepends: bb\nDepends: cc", " depends on nothing", "Package: aa\ninvalid", "Package: aa\nDepends: bb\0cc"])
    func malformedParagraphIsRejected(_ value: String) {
        #expect(throws: (any Error).self) { try DebianControl.parse(value) }
    }
}
