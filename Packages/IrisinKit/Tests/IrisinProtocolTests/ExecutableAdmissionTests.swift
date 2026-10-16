import Darwin
import Foundation
@testable import IrisinProtocol
import XCTest

/// Which executables irisind serves. The harness cannot make a file root's,
/// so it trusts its own uid as the owner; every other rule is the device's.
final class ExecutableAdmissionTests: XCTestCase {
    private var root = ""
    private var outside = ""

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: ProcessPath.canonical(NSTemporaryDirectory())!)
        let scratch = base.appendingPathComponent("admission-\(UUID().uuidString)")
        root = scratch.appendingPathComponent("jbroot").path
        outside = scratch.appendingPathComponent("elsewhere").path
        for directory in [root + "/usr/libexec", outside] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        for directory in [scratch.path, root, root + "/usr", root + "/usr/libexec", outside] {
            chmod(directory, 0o755)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    private var admission: ExecutableAdmission {
        ExecutableAdmission(installRoot: root, trustsSystemVolume: false, trustedOwners: [getuid()])
    }

    private func executable(_ path: String, mode: mode_t = 0o755) throws -> String {
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
        XCTAssertEqual(chmod(path, mode), 0)
        return path
    }

    func testInsideTheInstallRootIsAdmitted() throws {
        let client = try executable(root + "/usr/libexec/apelind-session")
        XCTAssertEqual(admission.admit(client), .success(client))
    }

    func testOutsideTheInstallRootIsRefused() throws {
        let client = try executable(outside + "/tool")
        XCTAssertEqual(admission.admit(client), .failure(.outsideTrustedPlaces))
    }

    /// `/x/jbroot2` begins with the string `/x/jbroot` and is not inside it.
    func testASiblingThatSharesThePrefixIsOutside() throws {
        let sibling = root + "2"
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        chmod(sibling, 0o755)
        let client = try executable(sibling + "/tool")
        XCTAssertEqual(admission.admit(client), .failure(.outsideTrustedPlaces))
        XCTAssertFalse(ExecutableAdmission.isInside(sibling + "/tool", root: root))
        XCTAssertTrue(ExecutableAdmission.isInside(root + "/usr/tool", root: root))
        XCTAssertTrue(ExecutableAdmission.isInside(root, root: root + "/"))
    }

    /// A link inside the root to a file outside is judged where it leads.
    func testASymlinkOutOfTheRootIsRefused() throws {
        let target = try executable(outside + "/tool")
        let link = root + "/usr/libexec/escape"
        XCTAssertEqual(symlink(target, link), 0)
        XCTAssertEqual(admission.admit(link), .failure(.outsideTrustedPlaces))
    }

    /// And a directory link out of the root is resolved before anything is
    /// compared.
    func testADirectoryLinkOutOfTheRootIsRefused() throws {
        _ = try executable(outside + "/tool")
        XCTAssertEqual(symlink(outside, root + "/usr/libexec/elsewhere"), 0)
        XCTAssertEqual(admission.admit(root + "/usr/libexec/elsewhere/tool"), .failure(.outsideTrustedPlaces))
    }

    /// `..` is resolved too: `/root/usr/../../elsewhere` is not in the root.
    func testDotDotOutOfTheRootIsRefused() throws {
        _ = try executable(outside + "/tool")
        XCTAssertEqual(admission.admit(root + "/usr/../../elsewhere/tool"), .failure(.outsideTrustedPlaces))
    }

    func testAGroupOrWorldWritableFileIsRefused() throws {
        let group = try executable(root + "/usr/libexec/group", mode: 0o775)
        let world = try executable(root + "/usr/libexec/world", mode: 0o757)
        XCTAssertEqual(admission.admit(group), .failure(.untrustedFile))
        XCTAssertEqual(admission.admit(world), .failure(.untrustedFile))
    }

    func testAFileNotExecutableByItsOwnerIsRefused() throws {
        let client = try executable(root + "/usr/libexec/plain", mode: 0o644)
        XCTAssertEqual(admission.admit(client), .failure(.untrustedFile))
    }

    func testAFileOwnedBySomeoneElseIsRefused() throws {
        let client = try executable(root + "/usr/libexec/tool")
        let strict = ExecutableAdmission(installRoot: root, trustsSystemVolume: false, trustedOwners: [0])
        XCTAssertEqual(strict.admit(client), .failure(.untrustedFile))
    }

    func testADirectoryOthersCanWriteIsRefused() throws {
        let writable = root + "/var/mobile"
        try FileManager.default.createDirectory(atPath: writable, withIntermediateDirectories: true)
        chmod(root + "/var", 0o755)
        chmod(writable, 0o777)
        let client = try executable(writable + "/tool")
        XCTAssertEqual(admission.admit(client), .failure(.untrustedDirectory(writable)))
    }

    /// The root itself is one of the directories that must be trusted.
    func testAWritableInstallRootIsRefused() throws {
        let client = try executable(root + "/usr/libexec/tool")
        chmod(root, 0o777)
        defer { chmod(root, 0o755) }
        XCTAssertEqual(admission.admit(client), .failure(.untrustedDirectory(root)))
    }

    func testANULIsRefusedBeforeAnythingIsResolved() throws {
        let client = try executable(root + "/usr/libexec/tool")
        XCTAssertEqual(admission.admit(client + "\u{0}/../../elsewhere/tool"), .failure(.unresolvable))
        XCTAssertNil(ProcessPath.canonical(client + "\u{0}"))
    }

    func testAMissingFileIsRefused() {
        XCTAssertEqual(admission.admit(root + "/usr/libexec/absent"), .failure(.unresolvable))
    }

    func testADirectoryIsNotAnExecutable() {
        XCTAssertEqual(admission.admit(root + "/usr/libexec"), .failure(.untrustedFile))
    }

    /// The system volume is trusted where it is the device `/` is on; a
    /// Mac's `/bin/ls` is root's on its sealed system volume, and the
    /// scratch directory is on the data volume.
    func testTheSystemVolumeIsTrustedAndTheDataVolumeIsNot() throws {
        let system = ExecutableAdmission(installRoot: nil, trustsSystemVolume: true)
        XCTAssertEqual(system.admit("/bin/ls"), .success("/bin/ls"))
        let elsewhere = try executable(outside + "/tool")
        let mine = ExecutableAdmission(installRoot: nil, trustsSystemVolume: true, trustedOwners: [getuid()])
        XCTAssertEqual(mine.admit(elsewhere), .failure(.outsideTrustedPlaces))
    }

    /// No install root (rootful, or an empty one) trusts the system volume
    /// alone, never every path.
    func testAnEmptyInstallRootTrustsNoPrefix() throws {
        let client = try executable(root + "/usr/libexec/tool")
        let none = ExecutableAdmission(installRoot: "", trustsSystemVolume: false, trustedOwners: [getuid()])
        XCTAssertNil(none.installRoot)
        XCTAssertEqual(none.admit(client), .failure(.outsideTrustedPlaces))
    }
}
