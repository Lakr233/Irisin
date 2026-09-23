import AptRepository
import Foundation
@testable import irisin
import Testing

struct RecommendedRepositoriesTests {
    private let rootless = "iphoneos-arm64"
    private let roothide = "iphoneos-arm64e"

    private func write(_ sources: [[String: Any]], named name: String, in directory: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent(name).appendingPathExtension("plist"))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        try body(directory)
    }

    @Test func bundleListsReadForEveryBootstrap() throws {
        let directory = try #require(Bundle.main.resourceURL)
        for majorVersion in 16 ... 26 {
            let rootlessLines = RecommendedRepositories.lines(in: directory, architecture: rootless, majorVersion: majorVersion)
            #expect(rootlessLines.filter { $0.contains("apt.procurs.us") }.count == 1)
            #expect(rootlessLines.allSatisfy { RepositorySource(line: $0) != nil })
            let roothideLines = RecommendedRepositories.lines(in: directory, architecture: roothide, majorVersion: majorVersion)
            #expect(roothideLines.contains("https://roothide.github.io"))
            #expect(roothideLines.allSatisfy { RepositorySource(line: $0) != nil })
        }
        #expect(RecommendedRepositories.lines(in: directory, architecture: rootless, majorVersion: 17)
            .contains("deb https://apt.procurs.us 2000 main"))
    }

    @Test func procursusSuiteFollowsTheSystemVersion() throws {
        let directory = try #require(Bundle.main.resourceURL)
        let suites = [16: "1900", 17: "2000", 18: "3000", 26: "3000"]
        for (majorVersion, suite) in suites {
            #expect(RecommendedRepositories.lines(in: directory, architecture: rootless, majorVersion: majorVersion)
                .contains("deb https://apt.procurs.us \(suite) main"))
        }
    }

    @Test func unknownArchitectureRecommendsNothing() throws {
        let directory = try #require(Bundle.main.resourceURL)
        #expect(RecommendedRepositories.lines(in: directory, architecture: "darwin-arm64", majorVersion: 18).isEmpty)
    }

    @Test func managedListWithEntriesReplacesTheArchitectureList() throws {
        try withDirectory { directory in
            try write([["source": "https://rootless.example"]], named: "default-list-\(rootless)", in: directory)
            try write([["source": "https://managed.example"]], named: "default-list-managed", in: directory)
            #expect(RecommendedRepositories.lines(in: directory, architecture: rootless, majorVersion: 18)
                == ["https://managed.example"])
            #expect(RecommendedRepositories.lines(in: directory, architecture: "darwin-arm64", majorVersion: 18)
                == ["https://managed.example"])
        }
    }

    @Test func emptyOrBrokenManagedListFallsBack() throws {
        try withDirectory { directory in
            try write([["source": "https://rootless.example"]], named: "default-list-\(rootless)", in: directory)
            try write([], named: "default-list-managed", in: directory)
            #expect(RecommendedRepositories.lines(in: directory, architecture: rootless, majorVersion: 18)
                == ["https://rootless.example"])
            try Data("not a list".utf8).write(to: directory.appendingPathComponent("default-list-managed.plist"))
            #expect(RecommendedRepositories.lines(in: directory, architecture: rootless, majorVersion: 18)
                == ["https://rootless.example"])
        }
    }

    @Test func systemVersionBoundsAreInclusive() {
        let entry = RecommendedRepositories.Entry(source: "x", minimumSystemVersion: 17, maximumSystemVersion: 17)
        #expect(!entry.applies(to: 16))
        #expect(entry.applies(to: 17))
        #expect(!entry.applies(to: 18))
    }
}
