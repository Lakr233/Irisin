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

    /// Fat, signed by ldid with entitlements that exercise the merge, every
    /// executable segment flag and every kind of value, and carrying an
    /// `__info_plist` section for the info slot.
    func testProgramSignedByLdid() throws {
        try assertRewriteMatchesTheTools("FixtureApp")
    }

    /// Signed by codesign, as Xcode signs: the entitlements in Apple's own
    /// XML, which the merge reads as libplist reads it.
    func testProgramSignedByCodesign() throws {
        try assertRewriteMatchesTheTools("FixtureCodesigned")
    }

    /// No entitlements of its own, then no signature at all: roothide's
    /// four are all either gets.
    func testProgramWithNoEntitlements() throws {
        try assertRewriteMatchesTheTools("fixture-tool")
        try assertRewriteMatchesTheTools("FixtureUnsignedTool")
    }

    /// A program slice beside a library slice is a program to `file`, so
    /// both get the merge and only the program's is the main binary; the
    /// library carries an `__info_plist` for the info slot.
    func testProgramWithALibrarySlice() throws {
        try assertRewriteMatchesTheTools("FixtureMixed")
    }

    /// The merge read back: the program's keys where they stood, the one
    /// roothide also sets now true in its place, roothide's others after
    /// them, and the flags the entitlements ask for.
    func testTheMergedEntitlementsReadBack() throws {
        let rewritten = try XCTUnwrap(MachOBinary(contentsOf: fixture("input/FixtureApp"))).rewritten(identifier: "FixtureApp")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try rewritten.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case let .fat(fat) = try MachOKit.loadFromFile(url: url) else { return XCTFail("not fat") }
        for slice in try fat.machOFiles() {
            let signature = try XCTUnwrap(slice.codeSign)
            let entitlements = try LdidEntitlements(xml: XCTUnwrap(signature.embeddedEntitlementsData))
            XCTAssertEqual(entitlements.entries.map(\.key), [
                "application-identifier", "platform-application", "get-task-allow",
                "com.apple.private.skip-library-validation", "dynamic-codesigning",
                "com.apple.private.amfi.can-execute-cdhash", "com.apple.private.cs.debugger",
                "com.apple.security.exception.files.absolute-path.read-write", "keychain-access-groups",
                "com.example.nested", "com.example.blob", "com.example.long",
                "com.apple.private.security.no-sandbox", "com.apple.private.security.storage.AppBundles",
                "com.apple.private.security.storage.AppDataContainers",
            ])
            XCTAssertEqual(entitlements.entries[1].value, .boolean(true))
            XCTAssertEqual(signature.embeddedDEREntitlementsData, entitlements.der)
            let directory = try XCTUnwrap(signature.codeDirectory)
            // main binary, get-task-allow, dynamic-codesigning, skip-library-validation, can-execute-cdhash
            XCTAssertEqual(directory.executableSegment(in: signature)?.flags.rawValue, 0x1 | 0x10 | 0x40 | 0x80 | 0x100)
        }
    }

    /// What is not code is refused, whatever else its slices are: the same
    /// file with a 32-bit slice first is still refused for what it is.
    func testWhatIsNotCodeIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var fat = try Data(contentsOf: fixture("input/Fixture.dylib"))
        fat.replaceSubrange(16384 ..< 16384 + 4, with: [0xCE, 0xFA, 0xED, 0xFE])
        for type: UInt8 in [1, 10] { // object file, dSYM
            fat[98304 + 12] = type
            try fat.write(to: url)
            XCTAssertThrowsError(try MachOBinary(contentsOf: url)) { XCTAssertEqual($0 as? MachOFailure, .notCode) }
        }
    }

    /// What ldid refuses to carry into DER, or libplist reads its own way,
    /// is refused rather than signed with something ldid would not write.
    func testEntitlementsThatCannotBeCarriedOver() {
        let plist = { (body: String) in "<plist version=\"1.0\"><dict><key>k</key>\(body)</dict></plist>" }
        let bodies = [
            "<real>1.5</real>", "<date>2026-01-01T00:00:00Z</date>",
            // strtoull in any base, and zero, which ldid's DER cannot spell
            "<integer>0</integer>", "<integer>-1</integer>", "<integer>010</integer>", "<integer>0x10</integer>",
            "<integer>&#49;</integer>", "<integer>\u{A0}5</integer>", "<integer/>",
            // a second key in a row, stray text, markup inside a text
            "<key>again</key><true/>", "<string><true/></string>", "stray<true/>", "<true>x</true>",
            "<string>a<!--c-->b</string>", "<string><![CDATA[a]]></string>", "<string q='>'>b</string>",
            // entities libplist matches by their first letters or not at all
            "<string>x&ampy;z</string>", "<string>&foo;</string>", "<string>&#000000065;</string>", "<string>&#0;</string>",
            "<string>&#xD800;</string>", "<string>&#+65;</string>", "<string>a&</string>", "<string>a\0b</string>",
            // base64 libplist decodes its own way
            "<data>QUFB<!--c-->QkJC</data>", "<data>&#81;UFB</data>", "<data>====</data>", "<data>QU=B</data>", "<data>QR==</data>",
            String(repeating: "<array>", count: 64) + String(repeating: "</array>", count: 64),
        ]
        let documents = bodies.map(plist) + [
            "bplist00", "  \n", "\u{FEFF}<dict/>", "<plist version=\"1.0\"><array/></plist>",
            // libplist reads on past an empty root, into it
            "<plist><dict/><key>get-task-allow</key><true/></plist>", "<dict/>\0garbage", "<plist><dict/>",
            "<dict><key>a</key></dict>", "<dict><key/><true/></dict>", "<dict>\u{A0}</dict>",
            "<plist><dict><key>CF$UID</key><integer>1</integer></dict></plist>",
            "<!DOCTYPE plist [<!ENTITY x \"y\">]><dict/>",
        ]
        for document in documents {
            XCTAssertThrowsError(try LdidEntitlements(xml: Data(document.utf8)), document) {
                XCTAssertEqual($0 as? MachOFailure, .unsupportedEntitlements, document)
            }
        }
        XCTAssertThrowsError(try LdidEntitlements(xml: Data(plist("<string>").utf8) + [0xFF] + Data("</string>".utf8)))
        XCTAssertNoThrow(try LdidEntitlements(xml: Data(plist(String(repeating: "<array>", count: 63) + String(repeating: "</array>", count: 63)).utf8)))
    }

    /// What libplist reads as written: every byte of a string, CRs too, the
    /// document up to the end of its root and not a byte further, the last
    /// value of a key where the key first stood.
    func testEntitlementsReadAsLibplistReadsThem() throws {
        let cases: [(String, [LdidEntitlements.Entry])] = [
            ("<dict><key>a\rb</key><string>c\r\nd</string></dict>", [.init(key: "a\rb", value: .string("c\r\nd"))]),
            ("<dict><key>k</key><true/></dict>garbage<", [.init(key: "k", value: .boolean(true))]),
            ("<dict><key>k</key><string>&lt;&gt;&amp;&quot;&apos;&#65;&#x42;&#X43;</string></dict>", [.init(key: "k", value: .string("<>&\"'ABC"))]),
            ("<?xml version=\"1.0\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"x>y\">\n<plist version=\"1.0\"><dict/></plist>\n<!-- c -->", []),
            ("<dict><!-- c --><key>k</key><?pi \"?>\"?><data>\n\tQUFB\n\tQkJC\n\t</data></dict>", [.init(key: "k", value: .data(Data("AAABBB".utf8)))]),
            ("<dict><key>a</key><true/><key>b</key><true/><key>a</key><false/></dict>", [.init(key: "a", value: .boolean(false)), .init(key: "b", value: .boolean(true))]),
            ("<dict><key>é</key><true/><key>e\u{301}</key><false/></dict>", [.init(key: "é", value: .boolean(true)), .init(key: "e\u{301}", value: .boolean(false))]),
            ("<dict><key>k</key><integer> 300 \n</integer><key></key><string/></dict>", [.init(key: "k", value: .integer(300)), .init(key: "", value: .string(""))]),
            ("", []),
        ]
        for (document, entries) in cases {
            XCTAssertEqual(try LdidEntitlements(xml: Data(document.utf8)).entries, entries, document)
        }
    }

    /// libplist writes Foundation's XML but for the order of the keys, and
    /// the writer is held to Foundation on every list: base64 wrapped at
    /// every depth, escapes, CRs, control characters, keys Foundation sorts
    /// by UTF-16 (the emoji before the fullwidth letter) all write as it
    /// writes them, and the keys stay where they arrived.
    func testEntitlementsWriteAsFoundationWritesThem() throws {
        let blob = "<data>" + Data((0 ..< 300).map { UInt8(truncatingIfNeeded: $0 &* 37) }).base64EncodedString() + "</data>"
        let deep = (0 ..< 12).reduce(blob) { inner, _ in "<array>\(blob)\(inner)</array>" }
        let document = """
        <dict><key>zz</key>\(deep)<key>ｆ</key><string>a&lt;b&gt;c&amp;d"e'f]]&gt;\r\n\u{1}\u{7F}</string>\
        <key>😀</key><true/><key>é</key><false/><key>e\u{301}</key><integer>9223372036854775807</integer>\
        <key>a</key><dict/><key>b</key><array/><key>c</key><data></data><key></key><string/></dict>
        """
        var entitlements = try LdidEntitlements(xml: Data(document.utf8))
        entitlements.merge(LdidEntitlements.roothide)
        let xml = try entitlements.xml()
        XCTAssertEqual(try LdidEntitlements(xml: xml).entries, entitlements.entries)
        XCTAssertEqual(entitlements.entries.first?.key, "zz")
        XCTAssertNotEqual(xml, try PropertyListSerialization.data(fromPropertyList: PropertyListSerialization.propertyList(from: xml, format: nil), format: .xml, options: 0))
    }

    /// An `__info_plist` said to run past the file, or to lie over the load
    /// commands ldid rewrites before it reads, is refused, never read.
    func testInfoPlistOutsideTheCodeIsRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: fixture("input/FixtureApp"))
        let section = Data("__info_plist".utf8) + Data(count: 4) + Data("__TEXT".utf8) + Data(count: 10)
        // a section_64's size at 40, eight bytes, and its offset at 48, four
        for (field, width, value) in [(40, 8, UInt64.max), (40, 8, UInt64(Int64.max)), (48, 4, 0)] {
            var bytes = original
            var found = 0
            var from = bytes.startIndex
            while let range = bytes.range(of: section, in: from ..< bytes.endIndex) {
                let at = range.lowerBound + field
                bytes.replaceSubrange(at ..< at + width, with: withUnsafeBytes(of: value.littleEndian) { Array($0.prefix(width)) })
                from = range.upperBound
                found += 1
            }
            XCTAssertEqual(found, 2) // one per slice
            try bytes.write(to: url)
            XCTAssertThrowsError(try XCTUnwrap(MachOBinary(contentsOf: url)).rewritten(identifier: "FixtureApp")) {
                XCTAssertEqual($0 as? MachOFailure, .malformed)
            }
        }
    }

    /// What ldid and install_name_tool make of the header, as the device's
    /// did: a segment past 2^63 is refused rather than trapped on,
    /// `__LINKEDIT` is rounded to the fat header's alignment, the code ends
    /// with the string table, and a name the shell would read otherwise is
    /// refused.
    func testWhatTheHeaderSays() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func u32(_ data: Data, _ offset: Int) -> Int {
            Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        }
        func u64(_ data: Data, _ offset: Int) -> UInt64 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        }
        /// Where each command of `type` is in the thin image at `slice`.
        func commands(_ type: Int, in data: Data, at slice: Int = 0) -> [Int] {
            var offset = slice + 32
            return (0 ..< u32(data, slice + 16)).compactMap { _ in
                defer { offset += u32(data, offset + 4) }
                return u32(data, offset) == type ? offset : nil
            }
        }
        func refusal(_ data: Data) throws -> MachOFailure? {
            try data.write(to: url)
            do {
                _ = try MachOBinary(contentsOf: url)?.rewritten(identifier: "x")
                return nil
            } catch let failure as MachOFailure {
                return failure
            }
        }
        let thin = try Data(contentsOf: fixture("input/FixtureBundle"))
        let linkedit = try XCTUnwrap(commands(0x19, in: thin).first { thin[($0 + 8)...].starts(with: "__LINKEDIT".utf8) })
        var huge = thin
        huge.replaceSubrange(linkedit + 40 ..< linkedit + 48, with: [0, 0, 0, 0, 0, 0, 0, 0x80])
        XCTAssertEqual(try refusal(huge), .malformed)

        var fat = try Data(contentsOf: fixture("input/Fixture.dylib"))
        for arch in 0 ..< 2 {
            fat.replaceSubrange(8 + arch * 20 + 16 ..< 8 + arch * 20 + 20, with: [0, 0, 0, 12])
        }
        try fat.write(to: url)
        let aligned = try XCTUnwrap(MachOBinary(contentsOf: url)).rewritten(identifier: "Fixture.dylib")
        for arch in 0 ..< 2 {
            let slice = u32(Data(aligned[(8 + arch * 20 + 8)...].prefix(4).reversed()), 0)
            let segment = try XCTUnwrap(commands(0x19, in: aligned, at: slice).first { aligned[($0 + 8)...].starts(with: "__LINKEDIT".utf8) })
            XCTAssertEqual(slice % 0x1000, 0)
            XCTAssertEqual(u64(aligned, segment + 32), (u64(aligned, segment + 48) + 0xFFF) & ~0xFFF)
        }

        var strings = thin
        let symtab = try XCTUnwrap(commands(0x2, in: thin).first)
        let end = u32(thin, symtab + 16) + u32(thin, symtab + 20) - 32
        strings.replaceSubrange(symtab + 20 ..< symtab + 24, with: withUnsafeBytes(of: UInt32(u32(thin, symtab + 20) - 32).littleEndian, Array.init))
        try strings.write(to: url)
        let cut = try XCTUnwrap(MachOBinary(contentsOf: url)).rewritten(identifier: "FixtureBundle")
        XCTAssertEqual(u32(cut, try XCTUnwrap(commands(0x1D, in: cut).first) + 8), (end + 15) & ~15)

        // a backslash in a dependency, a blank at the end of an rpath
        var escaped = thin
        let name = try XCTUnwrap(escaped.range(of: Data("/var/jb/".utf8)))
        escaped[name.upperBound] = UInt8(ascii: "\\")
        XCTAssertEqual(try refusal(escaped), .unsupportedName)
        var blank = fat
        let rpath = try XCTUnwrap(commands(0x8000001C, in: blank, at: 16384).first)
        let path = rpath + u32(blank, rpath + 8)
        let pathEnd = try XCTUnwrap(blank[path...].firstIndex(of: 0))
        blank[pathEnd - 1] = 0x20
        XCTAssertEqual(try refusal(blank), .unsupportedName)

        // four bytes of a thin magic are a Mach-O to `file`; of a fat one, text
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C]).write(to: url)
        XCTAssertThrowsError(try MachOBinary(contentsOf: url)) { XCTAssertEqual($0 as? MachOFailure, .malformed) }
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0x0C]).write(to: url)
        XCTAssertNil(try MachOBinary(contentsOf: url))
    }

    func testWhatIsNotMachO() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        // a Java class; and 20 architectures, which `file` calls data
        let fat = { (count: UInt8) in Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, count] + [UInt8](repeating: 0, count: 64)) }
        for bytes in [Data(), Data("#!/bin/sh\necho\n".utf8), fat(0x34), fat(20)] {
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
