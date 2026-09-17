//
//  AppPaths.swift
//  Irisin
//

import Foundation

/// Where this install keeps its state. Read from every thread, decided once.
nonisolated let documentsDirectory: URL = FileManager
    .default
    .urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("wiki.qaq.irisin")

/// Deletes what Irisin created for itself when "Reset on Next Launch" is on
/// in the Settings app (`Settings.bundle`): `documentsDirectory` (the
/// catalogue, repositories, downloads, logs and in-app settings), partial
/// downloads, and the app's own defaults, the switch included. Nil when the
/// switch is off; otherwise how removing `documentsDirectory` went.
/// `AppDelegate.prepareEnvironment()` asks before anything opens a file in
/// there. The app has no container, so its home is `/var/mobile`, shared
/// with every other app without one; nothing else under it is touched, and
/// installed packages belong to the bootstrap.
func resetApplicationDataIfRequested() -> Result<Void, any Error>? {
    guard UserDefaults.standard.bool(forKey: "ResetOnNextLaunch") else { return nil }
    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "wiki.qaq.irisin")
    PartialDownloads.clear()
    return Result {
        guard FileManager.default.fileExists(atPath: documentsDirectory.path) else { return }
        try FileManager.default.removeItem(at: documentsDirectory)
    }
}
