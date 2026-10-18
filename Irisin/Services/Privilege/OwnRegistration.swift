import Dog
import Foundation
import IrisinProtocol
import UIKit

/// Irisin's own LaunchServices record, which a transaction that updates the
/// app leaves alone: registering a running app stops it, halfway through its
/// own update. The app asks for it as it leaves (`exitForUpgrade`), and the
/// registration stopping it is the exit. One stopped before it could ask
/// finds its record older than its bundle at the next launch, and asks then,
/// once per build.
enum OwnRegistration {
    /// The build a launch last asked for, so a registration that keeps
    /// failing costs one exit and never every launch.
    private static let attemptedBuildKey = "OwnRegistrationAttemptedBuild"

    /// Starts `registerOwnApplication` and returns once the helper has it,
    /// false when no daemon took it within `timeout`. The helper runs in a
    /// session of its own and finishes whatever this process does next;
    /// the transcript is only logged. The daemon that answers is the one the
    /// update just loaded, which may still be starting.
    static func request(within timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                let transcript = try await PrivilegedBackend.link.run(.registerOwnApplication)
                Task.detached {
                    for await event in transcript.events {
                        Dog.shared.join("OwnRegistration", event.description, level: .info)
                    }
                }
                return true
            } catch {
                guard Date() < deadline else {
                    Dog.shared.join("OwnRegistration", "not started: \(error)", level: .error)
                    return false
                }
                PrivilegedBackend.link.invalidate()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The registration asked for, then the exit, behind the progress alert
    /// the operation page shows for an update of the app.
    @MainActor
    static func finishUpdate(from controller: UIViewController, registering: Bool) {
        let progress = progressAlert(
            title: "Updating App…",
            message: "Preparing the app update. The app will exit when it finishes."
        )
        controller.present(progress, animated: true) {
            Task {
                if registering {
                    _ = await request()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                UIApplication.prepareForExitAndSuspend()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                exit(0)
            }
        }
    }

    /// At launch, once the daemon has answered: an update that stopped the
    /// app before it asked leaves LaunchServices with the build before this
    /// one, and this build asks once.
    @MainActor
    static func finishIfStale(from controller: UIViewController) {
        guard let bundled = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              let registered = registeredBuild, registered != bundled,
              UserDefaults.standard.string(forKey: attemptedBuildKey) != bundled
        else { return }
        Dog.shared.join("OwnRegistration", "registered build \(registered), bundle \(bundled)", level: .warning)
        UserDefaults.standard.set(bundled, forKey: attemptedBuildKey)
        finishUpdate(from: controller, registering: true)
    }

    /// `CFBundleVersion` as LaunchServices recorded it for this app.
    private static var registeredBuild: String? {
        guard let identifier = Bundle.main.bundleIdentifier,
              let proxies = NSClassFromString("LSApplicationProxy") as? NSObject.Type
        else { return nil }
        let lookup = NSSelectorFromString("applicationProxyForIdentifier:")
        guard proxies.responds(to: lookup),
              let proxy = proxies.perform(lookup, with: identifier)?.takeUnretainedValue() as? NSObject,
              proxy.responds(to: NSSelectorFromString("bundleVersion"))
        else { return nil }
        return proxy.value(forKey: "bundleVersion") as? String
    }
}
