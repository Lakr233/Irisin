@testable import IrisinProtocol
import Testing

/// libroothide's rule for a root's name, and which install roots each
/// system serves.
struct BootstrapSupportTests {
    private static let parent = "/private/var/containers/Bundle/Application"

    @Test(arguments: [".jbroot-0123456789ABCDEF", ".jbroot-0123456789abcdef"])
    func rootNameWithItsChecksum(name: String) {
        #expect(RoothideRoot.isRootName(name))
    }

    /// A looser match would take the `.jbroot` link inside a bundle for a
    /// bootstrap.
    @Test(arguments: [
        ".jbroot-0123456789ABCDEE", ".jbroot-test", ".jbroot", ".jbroot-+123456789ABCDEF",
        ".jbroot-0123456789ABCDEF0", "jbroot-0123456789ABCDEF",
    ])
    func otherNamesAreNotRoots(name: String) {
        #expect(!RoothideRoot.isRootName(name))
    }

    @Test func rootOfAPathInsideOne() {
        #expect(RoothideRoot.root(ofPath: Self.parent + "/.jbroot-0123456789ABCDEF/Applications/irisin.app")
            == Self.parent + "/.jbroot-0123456789ABCDEF")
        #expect(RoothideRoot.root(ofPath: "/var/jb/Applications/irisin.app/.jbroot/Applications") == nil)
    }

    @Test(arguments: ["", "/var/jb", "/private/preboot/ABC/jb-x/procursus", "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"])
    func iOSServesEveryRootItAlwaysHas(installRoot: String) {
        #expect(BootstrapSupport.serves(installRoot: installRoot, on: .iOS))
    }

    @Test func tvOSServesARoothideRoot() {
        #expect(BootstrapSupport.serves(installRoot: Self.parent + "/.jbroot-0123456789ABCDEF", on: .tvOS))
        #expect(BootstrapSupport.serves(installRoot: "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF", on: .tvOS))
    }

    /// Rootful, rootless and a root that only looks like RootHide's.
    @Test(arguments: [
        "", "/", "/var/jb", "/private/preboot/ABC/jb-x/procursus", Self.parent + "/.jbroot-0123456789ABCDEE",
        Self.parent + "/.jbroot-0123456789ABCDEF/usr", "/usr",
    ])
    func tvOSRefusesEveryOtherRoot(installRoot: String) {
        #expect(!BootstrapSupport.serves(installRoot: installRoot, on: .tvOS))
    }
}
