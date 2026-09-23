@testable import AptRepository
import Foundation
import Testing

/// A Release read the way repositories write them, never the way a
/// package's control paragraph is held to.
struct ReleaseFileTests {
    /// mtac.app's Release as served on 2026-09-24: an empty `Description`,
    /// then one `SHA256` table per publish, blank lines between them.
    @Test func mtacKeepsItsNameAndLosesItsDigests() throws {
        let reading = try #require(ReleaseFile.read(TestEnvironment.fixture("mtac-release")))
        #expect(reading.fields["label"] == "MTAC's Repo")
        #expect(reading.fields["origin"] == "MTAC's Repo")
        #expect(reading.fields["architectures"] == "iphoneos-arm iphoneos-arm64 iphoneos-arm64e")
        #expect(reading.fields["description"] == "")
        #expect(reading.digestsDuplicated)
        #expect(reading.fields["sha256"] == nil)
        // the strict reader refuses the file outright
        #expect(throws: (any Error).self) { try DebianControl.parse(TestEnvironment.fixture("mtac-release")) }
    }

    @Test func ordinaryReleaseReadsAsBefore() throws {
        let text = """
        Origin: Example
        Label: Example
        Architectures: iphoneos-arm64
        SHA256:
         \(String(repeating: "a", count: 64)) 12 Packages
         \(String(repeating: "b", count: 64)) 34 Packages.xz
        """
        let reading = try #require(ReleaseFile.read(text))
        #expect(!reading.digestsDuplicated)
        #expect(reading.fields == (try DebianControl.parse(text)))
        let digests = IndexDigests(release: reading.fields, releaseUrl: URL(string: "https://example.test/Release")!)
        #expect(digests.lists(URL(string: "https://example.test/Packages.xz")!))
    }

    @Test func blankLineDoesNotEndTheFile() throws {
        let reading = try #require(ReleaseFile.read("Origin: A\n\nLabel: B\r\n\nLabel: C\n continued\nSuite: stable\n"))
        #expect(reading.fields == ["origin": "A", "label": "B", "suite": "stable"])
        #expect(!reading.digestsDuplicated)
    }

    @Test func whatIsNoReleaseIsNil() {
        #expect(ReleaseFile.read("") == nil)
        #expect(ReleaseFile.read("\n\n  \n") == nil)
        #expect(ReleaseFile.read("<html><body>Sign in to this network</body></html>") == nil)
        #expect(ReleaseFile.read("<a href=\"https://example.test\">x</a>") == nil)
        #expect(ReleaseFile.read(" continuation first") == nil)
        #expect(ReleaseFile.read("Origin: A\u{0}") == nil)
    }
}
