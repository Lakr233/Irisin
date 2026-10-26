//
//  CommandLineChanges.swift
//  Irisin
//

import AptRepository
import Foundation
import notify

/// `irisin-cli` installs and removes packages behind the app's back: it
/// posts this once a run ends, and a running app reads dpkg's installed
/// list again. The catalogue is the app's alone to write, so this is all
/// the command line asks of it (Documentation/CommandLine.md).
enum CommandLineChanges {
    /// The name `irisin-cli`'s `Runner.packagesChanged` posts.
    static let name = "wiki.qaq.irisin.packages-changed"

    private static var token: Int32 = NOTIFY_TOKEN_INVALID

    /// Once, when the engines are up: what they read at launch is fresh.
    static func observe() {
        guard token == NOTIFY_TOKEN_INVALID else { return }
        notify_register_dispatch(name, &token, .main) { _ in
            MainActor.assumeIsolated {
                _ = Task { await PackageCenter.default.reloadLocalPackages() }
            }
        }
    }
}
