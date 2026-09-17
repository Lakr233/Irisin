import AptRepository
import Foundation
import IrisinAdapter
import IrisinProtocol
import XCTest

/// `RootlessToRoothide` against the script it stands in for, over real
/// packages. Nothing third-party is kept in the repository, so the packages
/// come from outside:
///
///     ADAPTER_CONFORMANCE_DIR=<dir> swift test --filter AdapterConformanceTests
///
/// `<dir>/in/*.deb` are rootless packages and `<dir>/ref/<same name>` what
/// roothide's `patch.sh` (Compat Layer mode) made of each on a device;
/// `Scripts/adapter-reference.sh` fills both. Each input is prepared and
/// adapted, each reference only prepared, and the two manifests must say
/// the same: paths, kinds, modes, owners, link targets, every blob's
/// SHA-256 (so a Mach-O the same to the byte, signature included), the
/// control paragraph and every control member. What is allowed to differ is
/// written down in `compare` and nowhere else. A package the adapter
/// refuses as more than a simple tweak is listed, not compared; one it
/// refuses for any other reason fails. Skipped without the variable.
final class AdapterConformanceTests: XCTestCase {
    func testAdaptedPackagesMatchThePatcher() throws {
        guard let root = ProcessInfo.processInfo.environment["ADAPTER_CONFORMANCE_DIR"].map(URL.init(fileURLWithPath:)) else {
            throw XCTSkip("ADAPTER_CONFORMANCE_DIR is not set")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-conformance-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let inputs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("in").resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "deb" }.sorted { $0.path < $1.path }
        XCTAssertFalse(inputs.isEmpty)
        var compared = 0
        for input in inputs {
            let name = input.lastPathComponent
            let ours = scratch.appendingPathComponent("ours-\(name)")
            let theirs = scratch.appendingPathComponent("theirs-\(name)")
            _ = try ArchiveStream.prepareDebianPackage(at: input, in: ours)
            let digest: String?
            do {
                digest = try PackageAdapters.installed.adapt(preparedPackageAt: ours, on: "iphoneos-arm64e")
            } catch let refusal as AdaptationFailure {
                // Refusing a real package is in scope — the conversion takes
                // simple tweaks and the script takes more — but only for
                // that reason. A binary we could not read, or an adapter
                // that is not there, is a divergence whatever the script
                // made of the same package.
                switch refusal {
                case .notSimple, .incompatible: break
                case .malformedBinary, .unavailable: XCTFail("\(name): \(refusal)")
                }
                print("conformance: \(name) refused: \(refusal)")
                continue
            }
            XCTAssertNotNil(digest, "\(name) is not a rootless package")
            _ = try ArchiveStream.prepareDebianPackage(at: root.appendingPathComponent("ref/\(name)"), in: theirs)
            try compare(ours, theirs, name)
            compared += 1
            print("conformance: \(name) matches")
        }
        XCTAssertGreaterThan(compared, 0, "every package was refused")
    }

    private func compare(_ ours: URL, _ theirs: URL, _ name: String) throws {
        let mine = try PreparedPackage.read(from: ours)
        let reference = try PreparedPackage.read(from: theirs)
        XCTAssertEqual(mine.control, reference.control, name)
        XCTAssertEqual(mine.controlFiles.mapValues(\.sha256), reference.controlFiles.mapValues(\.sha256), name)

        let entries = Dictionary(uniqueKeysWithValues: mine.entries.map { ($0.path, $0) })
        let expected = Dictionary(uniqueKeysWithValues: reference.entries.map { ($0.path, $0) })
        XCTAssertEqual(entries.keys.sorted(), expected.keys.sorted(), name)
        for (path, entry) in entries {
            guard let other = expected[path] else { continue }
            let label = "\(name): \(path)"
            XCTAssertEqual(entry.kind, other.kind, label)
            XCTAssertEqual(entry.linkTarget, other.linkTarget, label)
            // the script's directories for the mirror are whatever `mkdir`
            // made them for the user running it; the device has them already
            if !["var", "var/mobile", "var/mobile/Library"].contains(path) {
                XCTAssertEqual([entry.uid, entry.gid], [other.uid, other.gid], label)
            }
            // a link's mode is the umask of the device that unpacked it
            if entry.kind != .symbolicLink {
                XCTAssertEqual(entry.mode, other.mode, label)
            }
            guard let file = entry.file, let otherFile = other.file, file.sha256 != otherFile.sha256 else { continue }
            // the script turns every property list into XML so that sed can
            // read it, then edits only those of daemons and libSandy, which
            // are refused here: the same values in another encoding
            let mineList = try? PropertyListSerialization.propertyList(from: Data(contentsOf: ours.appendingPathComponent(file.name)), format: nil)
            let otherList = try? PropertyListSerialization.propertyList(from: Data(contentsOf: theirs.appendingPathComponent(otherFile.name)), format: nil)
            XCTAssertTrue(
                path.hasSuffix(".plist") && mineList != nil && (mineList as? NSObject) == (otherList as? NSObject),
                "\(label): contents differ"
            )
        }
    }
}
