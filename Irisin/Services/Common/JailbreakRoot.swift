//
//  JailbreakRoot.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation
import IrisinClient

/// Single source of truth for where the jailbreak bootstrap lives.
/// rootless (Dopamine): `/var/jb` via libroot.dylib, else that path as fallback.
/// roothide: randomized path, read from libroothide through the `.jbroot` symlink roothide keeps beside the app.
/// simulator: the directory `SimulatorDaemon` installs into, spelled rootless.
nonisolated enum JailbreakRoot {
    #if targetEnvironment(simulator)
        static let prefix = DaemonLink.simulatedInstallRoot
        static let isRoothide = false
    #else
        static let prefix = libraryPrefix
        static let isRoothide = prefix != "/var/jb"
    #endif

    private static let libraryPrefix: String = {
        // roothide does not ship libroot.dylib, probe its own library first
        let roothideLibrary = Bundle.main.bundlePath + "/.jbroot/usr/lib/libroothide.dylib"
        if let handle = dlopen(roothideLibrary, RTLD_NOW),
           let symbol = dlsym(handle, "jbroot")
        {
            typealias JBRoot = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>
            let root = String(cString: unsafeBitCast(symbol, to: JBRoot.self)("/"))
            return root.hasSuffix("/") ? String(root.dropLast()) : root
        }
        if let handle = dlopen("@rpath/libroot.dylib", RTLD_NOW),
           let symbol = dlsym(handle, "libroot_get_jbroot_prefix")
        {
            typealias Prefix = @convention(c) () -> UnsafePointer<CChar>
            return String(cString: unsafeBitCast(symbol, to: Prefix.self)())
        }
        return "/var/jb"
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
