@testable import AptRepository
import CryptoKit
import Foundation
import IrisinProtocol
import Testing

/// An index is held to the Release fetched beside it: a CDN that still has
/// yesterday's copy of one spelling does not get it compiled.
struct IndexDigestsTests {
    private static let current = Data("Package: a\nVersion: 2\n".utf8)
    private static let stale = Data("Package: a\nVersion: 1\n".utf8)

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Parsed as the update parses it, so the folded `SHA256` value is the
    /// parser's and not this test's idea of it.
    private static func release(listing paths: [String], md5Only: Bool = false) throws -> [String: String] {
        let lines = paths.map { " \(hex(current)) \(current.count) \($0)" }.joined(separator: "\n")
        return try DebianControl.parse("""
        Origin: Example
        Architectures: iphoneos-arm64
        \(md5Only ? "MD5Sum" : "SHA256"):
        \(lines)
        """)
    }

    private let flat = URL(string: "https://example.org/Release")!
    private let suite = URL(string: "https://example.org/dists/stable/Release")!

    @Test func flatRepositoryIndexIsHeldToItsRelease() throws {
        let digests = try IndexDigests(release: Self.release(listing: ["Packages", "Packages.xz"]), releaseUrl: flat)
        let url = try #require(URL(string: "https://example.org/Packages.xz"))
        #expect(digests.verdict(of: Self.current, at: url) == .matches)
        #expect(digests.verdict(of: Self.stale, at: url) == .differs)
    }

    @Test func suiteIndexIsFoundByItsPathUnderTheRelease() throws {
        let path = "main/binary-iphoneos-arm64/Packages.bz2"
        let digests = try IndexDigests(release: Self.release(listing: [path]), releaseUrl: suite)
        let url = try #require(URL(string: "https://example.org/dists/stable/\(path)"))
        #expect(digests.verdict(of: Self.current, at: url) == .matches)
        #expect(digests.verdict(of: Self.stale, at: url) == .differs)
    }

    @Test func dotSlashSpellingIsTheSameFile() throws {
        let digests = try IndexDigests(release: Self.release(listing: ["./Packages"]), releaseUrl: flat)
        #expect(try digests.verdict(of: Self.stale, at: #require(URL(string: "https://example.org/Packages"))) == .differs)
    }

    @Test func whatTheReleaseDoesNotListIsNotJudged() throws {
        let listed = try IndexDigests(release: Self.release(listing: ["Packages"]), releaseUrl: flat)
        #expect(try listed.verdict(of: Self.stale, at: #require(URL(string: "https://example.org/Packages.gz"))) == .unlisted)
        #expect(try listed.verdict(of: Self.stale, at: #require(URL(string: "https://elsewhere.org/Packages"))) == .unlisted)

        let md5 = try IndexDigests(release: Self.release(listing: ["Packages"], md5Only: true), releaseUrl: flat)
        #expect(try md5.verdict(of: Self.stale, at: #require(URL(string: "https://example.org/Packages"))) == .unlisted)

        let silent = IndexDigests(release: ["origin": "Example"], releaseUrl: flat)
        #expect(try silent.verdict(of: Self.stale, at: #require(URL(string: "https://example.org/Packages"))) == .unlisted)
    }

    @Test func indexTheSessionUnpackedIsTheUncompressedOne() throws {
        // `Packages.gz` sent with Content-Encoding: gzip arrives as `Packages`
        let release = try DebianControl.parse("""
        Origin: Example
        SHA256:
         \(Self.hex(Self.current)) \(Self.current.count) Packages
         \(Self.hex(Data("packed".utf8))) 6 Packages.gz
        """)
        let digests = IndexDigests(release: release, releaseUrl: flat)
        let url = try #require(URL(string: "https://example.org/Packages.gz"))
        #expect(digests.verdict(of: Self.current, at: url) == .matches)
        #expect(digests.verdict(of: Self.stale, at: url) == .differs)
    }

    @Test func aWordOutOfPlaceCostsOneEntry() throws {
        let digests = IndexDigests(
            release: ["sha256": "junk \(Self.hex(Self.current)) 22 Packages"],
            releaseUrl: flat
        )
        #expect(try digests.verdict(of: Self.stale, at: #require(URL(string: "https://example.org/Packages"))) == .differs)
    }

    @Test func releaseDateIsRead() throws {
        let early = try #require(IndexDigests.date(of: ["date": "Sat, 19 Sep 2026 11:54:05 +0000"]))
        let late = try #require(IndexDigests.date(of: ["date": "Sat, 19 Sep 2026 18:21:09 UTC"]))
        #expect(early < late)
        #expect(IndexDigests.date(of: ["date": "yesterday"]) == nil)
        #expect(IndexDigests.date(of: [:]) == nil)
    }

    @Test func staleIndexIsNotRead() throws {
        // a refused index is logged, and the log is the environment's
        _ = TestEnvironment.root
        let digests = try IndexDigests(release: Self.release(listing: ["Packages"]), releaseUrl: flat)
        let base = try #require(URL(string: "https://example.org/Packages"))
        let fresh = RepositoryCenter.FetchedIndex(url: base, data: Self.current)
        let old = RepositoryCenter.FetchedIndex(url: base, data: Self.stale)
        func read(_ indexes: [RepositoryCenter.FetchedIndex], digests: IndexDigests?) -> String? {
            RepositoryCenter.readPackageIndexes(indexes, of: [base], suffix: "", digests: digests)
        }

        #expect(read([fresh], digests: digests)?.contains("Version: 2") == true)
        #expect(read([old], digests: digests) == nil)
        // no Release this time: read as before
        #expect(read([old], digests: nil)?.contains("Version: 1") == true)
        #expect(read([], digests: digests) == nil)
    }

    @Test func componentsAreReadInOrderAndAListedOneMustArrive() throws {
        _ = TestEnvironment.root
        let main = try #require(URL(string: "https://example.org/dists/stable/main/binary-iphoneos-arm64/Packages"))
        let extra = try #require(URL(string: "https://example.org/dists/stable/extra/binary-iphoneos-arm64/Packages"))
        let first = RepositoryCenter.FetchedIndex(url: main, data: Self.current)
        let second = RepositoryCenter.FetchedIndex(url: extra, data: Self.stale)
        func read(_ indexes: [RepositoryCenter.FetchedIndex], listing: [String]) throws -> String? {
            let digests = try IndexDigests(release: Self.release(listing: listing), releaseUrl: suite)
            return RepositoryCenter.readPackageIndexes(indexes, of: [main, extra], suffix: "", digests: digests)
        }

        // whichever answered first, main is read first
        let both = try #require(try read([second, first], listing: []))
        #expect(try #require(both.range(of: "Version: 2")?.lowerBound) < both.range(of: "Version: 1")!.lowerBound)
        // a component the Release never listed may be missing
        #expect(try read([first], listing: ["main/binary-iphoneos-arm64/Packages"]) != nil)
        // one it lists may not: the spelling is refused whole
        #expect(try read([first], listing: ["extra/binary-iphoneos-arm64/Packages"]) == nil)
    }
}
