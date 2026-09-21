import Foundation
@testable import irisin
import Testing

struct PackagedArchitectureTests {
    @Test func runtimeRootfsAPIIdentifiesRelocatedBootstrapsWithoutASymlink() {
        #expect(!JailbreakRoot.isRoothide(
            prefix: "/private/preboot/dopamine/procursus",
            rootlessPrefix: "/missing-rootless-link",
            rootfsPrefix: ""
        ))
        // A compatibility link cannot turn a roothide runtime into rootless.
        #expect(JailbreakRoot.isRoothide(
            prefix: "/bootstrap", rootlessPrefix: "/bootstrap", rootfsPrefix: "/rootfs"
        ))
    }

    @Test func rootlessSymlinkTargetIsNotRoothide() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let target = directory.appendingPathComponent("preboot/dopamine/procursus")
        let link = directory.appendingPathComponent("jb")
        let roothide = directory.appendingPathComponent(".jbroot-test")
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        try files.createDirectory(at: roothide, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!JailbreakRoot.isRoothide(prefix: link.path, rootlessPrefix: link.path))
        #expect(!JailbreakRoot.isRoothide(prefix: target.path, rootlessPrefix: link.path))
        #expect(!JailbreakRoot.isRoothide(prefix: target.path + "/", rootlessPrefix: link.path))
        #expect(JailbreakRoot.isRoothide(prefix: roothide.path, rootlessPrefix: link.path))

        try files.removeItem(at: link)
        #expect(JailbreakRoot.isRoothide(prefix: roothide.path, rootlessPrefix: link.path))
        #expect(!JailbreakRoot.isRoothide(prefix: link.path, rootlessPrefix: link.path))
    }

    @Test func bundlePathIdentifiesRoothideWithoutTheJBRootLink() {
        let parent = "/var/containers/Bundle/Application"
        #expect(JailbreakRoot.roothideRoot(
            ofBundleAt: parent + "/.jbroot-0123456789ABCDEF/Applications/irisin.app"
        ) == parent + "/.jbroot-0123456789ABCDEF")
        #expect(JailbreakRoot.roothideRoot(
            ofBundleAt: parent + "/.jbroot-0123456789abcdef/Applications/irisin.app"
        ) == parent + "/.jbroot-0123456789abcdef")
    }

    /// libroothide's own rule for the name, checksum included: a looser
    /// match would take the `.jbroot` link inside a bundle for a bootstrap.
    @Test(arguments: [
        "/var/jb/Applications/irisin.app",
        "/private/preboot/dopamine/procursus/Applications/irisin.app",
        "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEE/Applications/irisin.app",
        "/var/containers/Bundle/Application/.jbroot-test/Applications/irisin.app",
        "/var/jb/Applications/irisin.app/.jbroot/Applications/irisin.app",
        "/var/containers/Bundle/Application/.jbroot-+123456789ABCDEF/Applications/irisin.app",
    ])
    func bundlePathOutsideARoothideRootIsNotRoothide(path: String) {
        #expect(JailbreakRoot.roothideRoot(ofBundleAt: path) == nil)
    }

    @Test(arguments: [
        ("iphoneos-arm64", "iphoneos-arm64e"),
        ("iphoneos-arm64e", "iphoneos-arm64"),
        ("all", "iphoneos-arm64"),
    ])
    func convertedIrisinRequiresTheMatchingOfficialPackage(packaged: String, detected: String) throws {
        let message = try #require(PackagedArchitecture.incompatibilityMessage(
            packaged: packaged, detected: detected
        ))
        #expect(message.contains(packaged))
        #expect(message.contains(detected))
    }

    @Test(arguments: ["iphoneos-arm64", "iphoneos-arm64e"])
    func nativePackagesAndUnpackagedDevelopmentBuildsCanStart(architecture: String) {
        #expect(PackagedArchitecture.incompatibilityMessage(
            packaged: architecture, detected: architecture
        ) == nil)
        #expect(PackagedArchitecture.incompatibilityMessage(
            packaged: nil, detected: architecture
        ) == nil)
    }
}
