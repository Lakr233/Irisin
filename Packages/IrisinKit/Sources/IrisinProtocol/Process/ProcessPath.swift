import Darwin
import Foundation

@_silgen_name("proc_pidpath")
private func irisinProcPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

public enum ProcessPath {
    /// `realpath(3)`, or nil when the path does not resolve. `/var` and `/etc`
    /// are symlinks into `/private`; every comparison in this project is made
    /// on the resolved spelling.
    public static func canonical(_ path: String) -> String? {
        guard !path.utf8.contains(0) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let resolved = path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) }
        }
        return resolved.map { _ in String(cString: buffer) }
    }

    /// The executable path of a running process, canonicalised.
    public static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            irisinProcPIDPath(pid, $0.baseAddress!, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return canonical(String(cString: buffer))
    }

    /// The install root a root binary of ours was installed under, from its
    /// own executable path and the suffix the package gives it.
    ///
    /// roothide relocates rootful paths into a randomized bootstrap directory
    /// and rootless installs under a fixed `/var/jb`, so the prefix is never
    /// known at build time and is never written into Swift. Nil when the
    /// process is not at a path the package installs to, which the callers
    /// treat as a refusal to start.
    public static func installRoot(ofCurrentProcessAt suffix: String) -> String? {
        guard let path = executable(of: getpid()), path.hasSuffix(suffix) else { return nil }
        return String(path.dropLast(suffix.count))
    }
}
