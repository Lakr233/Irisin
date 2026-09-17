@testable import IrisinInstaller
import Testing

struct BootstrapScriptPathTests {
    @Test func rootlessInterpreterIsPrefixedExactlyOnce() {
        let layout = BootstrapLayout(kind: .rootless(prefix: "/bootstrap"))
        #expect(layout.interpreterPath("/bin/sh") == "/bootstrap/bin/sh")
        #expect(layout.interpreterPath("/bootstrap/bin/sh") == "/bootstrap/bin/sh")
        #expect(layout.scriptPath("/var/mobile/package stage/preinst") == "/var/mobile/package stage/preinst")
    }

    @Test func roothideDistinguishesJbrootFromRootfs() {
        let layout = BootstrapLayout(kind: .roothide(jbroot: "/private/containers/.jbroot-test"))
        #expect(layout.interpreterPath("/bin/sh") == "/private/containers/.jbroot-test/bin/sh")
        #expect(layout.scriptPath("/private/containers/.jbroot-test/Library/dpkg/info/example.postinst") == "/Library/dpkg/info/example.postinst")
        #expect(layout.scriptPath("/var/mobile/package stage/preinst") == "/rootfs/var/mobile/package stage/preinst")
        #expect(layout.scriptPath("/private/containers/.jbroot-test-other/preinst") == "/rootfs/private/containers/.jbroot-test-other/preinst")
    }
}
