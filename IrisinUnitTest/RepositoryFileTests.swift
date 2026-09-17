import AptRepository
import Foundation
@testable import irisin
import Testing

struct RepositoryFileTests {
    private let procursus = RepositorySource(
        url: URL(string: "https://apt.procurs.us")!,
        distribution: "2000",
        components: ["main"]
    )
    private let havoc = RepositorySource(url: URL(string: "https://havoc.app")!)

    /// A reader who opens the list in a text editor should see the addresses
    /// they are about to add; the catalogue of a whole repository should not
    /// cost them a text file the size of the catalogue.
    @Test func aListIsXmlAndOneRepositoryIsBinary() throws {
        let list = try RepositoryListFile(sources: [procursus, havoc]).encoded()
        #expect(list.starts(with: Data("<?xml".utf8)))

        let one = try RepositoryFile(
            repository: Repository(source: procursus),
            packages: []
        ).encoded()
        #expect(one.starts(with: Data("bplist".utf8)))
    }

    @Test func aListSurvivesTheRoundTrip() throws {
        let data = try RepositoryListFile(sources: [procursus, havoc]).encoded()
        #expect(try RepositoryListFile.sources(in: data) == [procursus, havoc])
    }

    /// A `.irisinrepo` describes its repository in its own words. Only the
    /// address is taken; everything else comes back from the server.
    @Test func oneRepositoryImportsAsItsAddressAlone() throws {
        let data = try RepositoryFile(
            repository: Repository(source: procursus),
            packages: []
        ).encoded()
        #expect(try RepositoryListFile.sources(in: data) == [procursus])
    }

    @Test func aSourceAptWouldRefuseIsDropped() throws {
        let broken = RepositorySource(url: URL(string: "https://havoc.app")!, distribution: "stable", components: [])
        let data = try RepositoryListFile(sources: [procursus, broken]).encoded()
        #expect(try RepositoryListFile.sources(in: data) == [procursus])
    }

    /// A file from a newer Irisin is refused, not read as far as it goes.
    @Test func anotherFormatIsRefused() throws {
        var file = RepositoryListFile(sources: [procursus])
        file.format = 2
        let data = try file.encoded()
        #expect(throws: RepositoryFileFailure.unsupportedFormat) {
            try RepositoryListFile.sources(in: data)
        }
    }

    @Test func somethingElseEntirelyIsRefused() {
        #expect(throws: RepositoryFileFailure.unreadable) {
            try RepositoryListFile.sources(in: Data("not a property list".utf8))
        }
    }
}
