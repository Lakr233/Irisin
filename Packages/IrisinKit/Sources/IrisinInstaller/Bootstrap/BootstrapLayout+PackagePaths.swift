import Foundation

extension BootstrapLayout {
    /// A shebang may already name a prefix-compiled rootless interpreter.
    /// Resolve it once; an unprefixed interpreter belongs to the bootstrap too.
    func interpreterPath(_ path: String) -> String {
        if case let .rootless(prefix) = kind, path.hasPrefix(prefix + "/") {
            return path
        }
        return tool(path)
    }

    /// The text a package's symbolic link is written with. roothide's vroot
    /// writes an absolute target as the kernel path it means, in the jbroot
    /// unless it says `/rootfs`, and reads it back as the archive spelled it.
    /// Written verbatim, the link would leave the jbroot for every reader:
    /// ElleKit's loader links pointed at the system volume.
    func linkText(_ target: String) -> String {
        guard case let .roothide(jbroot) = kind, target.hasPrefix("/") else { return target }
        if target == "/rootfs" {
            return "/"
        }
        if target.hasPrefix("/rootfs/") {
            return String(target.dropFirst("/rootfs".count))
        }
        return jbroot + target
    }

    /// The kernel path a link's text names. The text is one everywhere but
    /// in the simulator, whose links keep the rootless prefix of a mount the
    /// Mac does not have.
    func linkedPath(_ text: String) -> String {
        guard case .rootless = kind, text.hasPrefix("/") else { return text }
        return resolve(text)
    }

    /// Convert a kernel pathname to the vocabulary read by bootstrap programs.
    /// Installed control files live inside jbroot; staged scripts in the app's
    /// container live outside it and need roothide's rootfs bridge.
    func scriptPath(_ kernelPath: String) -> String {
        guard case let .roothide(jbroot) = kind else { return kernelPath }
        let root = URL(fileURLWithPath: jbroot).standardizedFileURL.path
        let path = URL(fileURLWithPath: kernelPath).standardizedFileURL.path
        if path == root {
            return "/"
        }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count))
        }
        return systemPath(path)
    }
}
