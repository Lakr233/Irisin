@testable import IrisinAdapter
import MachOKit
import XCTest

/// The adapter against the tools it stands in for. `Fixtures/expected` was
/// written on a device by `install_name_tool` and `ldid -Hsha256 -S`, the
/// commands roothide's patcher runs (see `Fixtures/build.sh`), and the
/// comparison is the whole file, signature included.
final class MachOBinaryTests: XCTestCase {
    private func fixture(_ path: String) throws -> URL {
        try XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent(path))
    }

    private func assertRewriteMatchesTheTools(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let binary = try XCTUnwrap(MachOBinary(contentsOf: fixture("input/\(name)")), file: file, line: line)
        let expected = try Data(contentsOf: fixture("expected/\(name)"))
        let rewritten = try binary.rewritten(identifier: name)
        XCTAssertEqual(rewritten.count, expected.count, file: file, line: line)
        let difference = zip(rewritten, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertNil(difference, "first difference at byte \(difference ?? 0)", file: file, line: line)
    }

    /// Fat, a weak dependency, and an rpath whose new spelling is already
    /// there: the duplicate stays, and both slices are laid out again.
    func testFatLibrary() throws {
        try assertRewriteMatchesTheTools("Fixture.dylib")
    }

    func testThinBundle() throws {
        try assertRewriteMatchesTheTools("FixtureBundle")
    }

    /// No signature to replace: the load command is added.
    func testLibraryThatWasNeverSigned() throws {
        try assertRewriteMatchesTheTools("FixtureUnsigned.dylib")
    }

    /// Read back through MachOKit rather than through our own offsets.
    func testTheResultReadsBack() throws {
        let rewritten = try XCTUnwrap(MachOBinary(contentsOf: fixture("input/Fixture.dylib"))).rewritten(identifier: "Fixture.dylib")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try rewritten.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case let .fat(fat) = try MachOKit.loadFromFile(url: url) else { return XCTFail("not fat") }
        for slice in try fat.machOFiles() {
            XCTAssertEqual(slice.rpaths, [
                "@loader_path/.jbroot/usr/lib", "@loader_path/.jbroot/usr/lib", "@loader_path/.jbroot/Library/Frameworks",
            ])
            XCTAssertEqual(slice.dependencies.map(\.dylib.name), [
                "@loader_path/.jbroot/usr/lib/libfixturedep.dylib", "/usr/lib/libSystem.B.dylib",
            ])
            XCTAssertEqual(try slice.codeSign?.codeDirectory?.identifier(in: XCTUnwrap(slice.codeSign)), "Fixture.dylib")
        }
    }

    /// A program is not rewritten, whatever else its slices are: the same
    /// file with a 32-bit slice first is still refused as a program.
    func testOnlyLibrariesAndBundlesAreTaken() throws {
        XCTAssertThrowsError(try MachOBinary(contentsOf: fixture("input/fixture-tool"))) {
            XCTAssertEqual($0 as? MachOFailure, .notLibrary)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var fat = try Data(contentsOf: fixture("input/Fixture.dylib"))
        fat.replaceSubrange(16384 ..< 16384 + 4, with: [0xCE, 0xFA, 0xED, 0xFE])
        for type: UInt8 in [2, 1, 10] { // program, object file, dSYM
            fat[98304 + 12] = type
            try fat.write(to: url)
            XCTAssertThrowsError(try MachOBinary(contentsOf: url)) { XCTAssertEqual($0 as? MachOFailure, .notLibrary) }
        }
    }

    func testWhatIsNotMachO() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for bytes in [Data(), Data("#!/bin/sh\necho\n".utf8), Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x34] + [UInt8](repeating: 0, count: 64))] {
            try bytes.write(to: url)
            XCTAssertNil(try MachOBinary(contentsOf: url))
        }
    }

    /// Every way a header can point outside its file is refused before
    /// MachOKit, which would follow it, is handed the file.
    func testMalformedInputIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let thin = try Data(contentsOf: fixture("input/FixtureBundle"))
        let fat = try Data(contentsOf: fixture("input/Fixture.dylib"))
        func patched(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
            var data = data
            data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
            return data
        }
        let cases: [(Data, MachOFailure)] = [
            (thin.prefix(20), .malformed),
            (patched(thin, at: 16, [0xFF, 0xFF, 0, 0]), .malformed), // more commands than their space holds
            (patched(thin, at: 20, [0xFF, 0xFF, 0xFF, 0x7F]), .malformed), // commands past the end of the file
            (patched(thin, at: 36, [4, 0, 0, 0]), .malformed), // a command shorter than its own header
            (patched(thin, at: 0, [0xCE, 0xFA, 0xED, 0xFE]), .unsupportedSlice), // 32-bit
            (patched(fat, at: 16, [0x7F, 0xFF, 0xFF, 0xFF]), .malformed), // a slice past the end of the file
            (patched(fat, at: 16384, [0xCE, 0xFA, 0xED, 0xFE]), .unsupportedSlice),
        ]
        for (bytes, failure) in cases {
            try bytes.write(to: url)
            XCTAssertThrowsError(try MachOBinary(contentsOf: url)) { XCTAssertEqual($0 as? MachOFailure, failure) }
        }
    }
}
