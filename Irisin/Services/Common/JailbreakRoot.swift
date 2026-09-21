//
//  JailbreakRoot.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation
import IrisinClient
import IrisinProtocol

/// Single source of truth for where the jailbreak bootstrap lives.
/// rootless (Dopamine): `/var/jb` via libroot.dylib, else that path as fallback.
/// roothide: randomized path, read from libroothide through the `.jbroot` symlink roothide keeps beside the app.
/// simulator: the directory `SimulatorDaemon` installs into, spelled rootless.
nonisolated enum JailbreakRoot {
    #if targetEnvironment(simulator)
        static let prefix = DaemonLink.simulatedInstallRoot
        static let isRoothide = false
    #else
        static let prefix = libraryRoot.prefix
        static let isRoothide = libraryRoot.isRoothide
    #endif

    /// libroot defines the rootfs prefix as empty on Dopamine and `/rootfs`
    /// on roothide. Older implementations may omit that API: only then
    /// compare `/var/jb` with its target, never just their spelling.
    /// See https://github.com/opa334/libroot#providing-paths.
    static func isRoothide(prefix: String, rootlessPrefix: String, rootfsPrefix: String? = nil) -> Bool {
        if let rootfsPrefix {
            return rootfsPrefix == "/rootfs"
        }
        guard prefix != rootlessPrefix else { return false }
        guard let root = ProcessPath.canonical(prefix),
              let rootless = ProcessPath.canonical(rootlessPrefix)
        else { return true }
        return root != rootless
    }

    /// The roothide bootstrap an app bundle is installed in, from the
    /// bundle's own path, which is how libroothide finds its root too
    /// (`init.c` reads it off its own image path). The `.jbroot` link
    /// beside the app is made by roothide's dpkg hook or by the jailbreak
    /// when it loads a binary, so an install that went through neither has
    /// no link and the path is the only evidence there is. The path is read
    /// as spelled: resolving it could only lose the name being looked for.
    static func roothideRoot(ofBundleAt bundlePath: String) -> String? {
        let components = bundlePath.split(separator: "/")
        guard let index = components.firstIndex(where: isRoothideRootName) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    /// libroothide's `is_jbroot_name`: `.jbroot-` and sixteen hex digits,
    /// the last byte the xor of the seven before it. Digits only: a sign is
    /// a number to `UInt64` and to `strtoull`, and no name roothide makes.
    private static func isRoothideRootName(_ name: Substring) -> Bool {
        let prefix = ".jbroot-"
        let digits = name.dropFirst(prefix.count)
        guard name.hasPrefix(prefix), digits.count == 16, digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16)
        else { return false }
        let check = (1 ... 7).reduce(UInt8(0)) { $0 ^ UInt8(truncatingIfNeeded: value >> ($1 * 8)) }
        return check == UInt8(truncatingIfNeeded: value)
    }

    private static let libraryRoot: (prefix: String, isRoothide: Bool) = {
        if let root = roothideRoot(ofBundleAt: Bundle.main.bundlePath) {
            return (root, true)
        }
        // roothide does not ship libroot.dylib, probe its own library first
        let roothideLibrary = Bundle.main.bundlePath + "/.jbroot/usr/lib/libroothide.dylib"
        if let handle = dlopen(roothideLibrary, RTLD_NOW),
           let symbol = dlsym(handle, "jbroot")
        {
            typealias JBRoot = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?
            if let value = unsafeBitCast(symbol, to: JBRoot.self)("/") {
                let root = String(cString: value)
                return (root.hasSuffix("/") ? String(root.dropLast()) : root, true)
            }
        }
        if let handle = dlopen("@rpath/libroot.dylib", RTLD_NOW),
           let symbol = dlsym(handle, "libroot_get_jbroot_prefix")
        {
            typealias Prefix = @convention(c) () -> UnsafePointer<CChar>?
            if let value = unsafeBitCast(symbol, to: Prefix.self)() {
                let root = String(cString: value)
                let rootfs = dlsym(handle, "libroot_get_root_prefix")
                    .flatMap { unsafeBitCast($0, to: Prefix.self)() }
                    .map { String(cString: $0) }
                return (root, isRoothide(prefix: root, rootlessPrefix: "/var/jb", rootfsPrefix: rootfs))
            }
        }
        return ("/var/jb", false)
    }()

    /// A bootstrap path spelled with the daemon's install root when the
    /// daemon has answered, and with libroot's prefix until then. The two
    /// can disagree on a bootstrap libroot was not built for.
    static func installedPath(_ absolutePath: String) -> String {
        if case let .daemon(root) = PrivilegedBackend.backend {
            return root + absolutePath
        }
        return path(absolutePath)
    }

    /// A path as a package and dpkg's lists spell it, where a syscall finds
    /// it: under the prefix the path already carries on rootless, under the
    /// jbroot on roothide, whose lists are written from inside the vroot.
    static func diskPath(ofListed path: String) -> String {
        guard !isRoothide else { return installedPath(path) }
        let rootless = "/var/jb"
        guard path == rootless || path.hasPrefix(rootless + "/") else { return path }
        return installedPath(String(path.dropFirst(rootless.count)))
    }

    /// map a bootstrap-relative absolute path, eg `/Library/dpkg/status`, onto this device
    static func path(_ absolutePath: String) -> String {
        prefix + absolutePath
    }
}
