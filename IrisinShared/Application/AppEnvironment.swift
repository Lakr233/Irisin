//
//  AppEnvironment.swift
//  Irisin
//

import AptRepository
import Dog
import Foundation

/// Everything that touches `documentsDirectory`, before anything else runs:
/// the app's `AppDelegate` and the launchpad's both call it as they launch,
/// before a scene connects.
enum AppEnvironment {
    /// In order: the reset the Settings app can ask for, the directory, the
    /// log, settings and the repository engine.
    static func prepare() {
        // MARK: - Document

        // The postinst makes the data folder at install, so a normal launch
        // finds it. When it cannot be made here — a home that is missing
        // (on roothide icli registers it inside the bootstrap, which need
        // not have var/mobile), or a Documents that is root's — the helper
        // makes the missing levels for mobile, as the postinst does, and the
        // folder is tried once more.
        let reset = resetApplicationDataIfRequested()
        do {
            let make = {
                Result {
                    try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
                }
            }
            var created = make()
            if case .failure = created {
                requestHomeFromDaemon()
                created = make()
            }
            var isDir = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: documentsDirectory.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else {
                // the crash log is all a user can send: say the path and the reason
                fatalError("Broken Document Permission at \(documentsDirectory.path): \(created)")
            }
        }

        // MARK: - Logging Engine

        do {
            try Dog.shared.initialization(writableDir: documentsDirectory)
        } catch {
            let errorDescription = "[E] Setup persist logging engine failed with error \(error.localizedDescription)"
            #if DEBUG
                fatalError(errorDescription)
            #else
                NSLog(errorDescription)
            #endif
        }
        switch reset {
        case .success:
            Dog.shared.join("App", "data reset, as asked in the Settings app", level: .warning)
        case let .failure(error):
            Dog.shared.join("App", "data reset asked in the Settings app stopped part way: \(error)", level: .error)
        case nil:
            break
        }

        // Local package pages and the queue live for this process only.
        // Clear their private archive copies before accepting new imports;
        // a running helper uses its separate, prepared transaction files.
        let imports = documentsDirectory.appendingPathComponent("DirectInstallCache")
        if FileManager.default.fileExists(atPath: imports.path) {
            do {
                try FileManager.default.removeItem(at: imports)
            } catch {
                Dog.shared.join("App", "could not clear previous local package imports: \(error)", level: .warning)
            }
        }

        // MARK: - SettingStore

        SettingStore.setup(storeAt: documentsDirectory.appendingPathComponent("Settings")) { str in
            Dog.shared.join("SettingStore", "error occurred \(str)")
        }

        // MARK: - Repository Engine

        // The app runs as mobile and never becomes root. Anything privileged goes to
        // irisind over XPC; see PrivilegedBackend. AptRepository gets told where to
        // persist, which package flavour this bootstrap takes, and how to log — it
        // reaches for none of that itself.
        AptEnvironment.bootstrap(AptRepositoryBootstrap.environment(documentsDirectory: documentsDirectory))

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

        Dog.shared.join(
            "App",
            """

            \(Bundle.main.bundleIdentifier ?? "unknown bundle") - \(appVersion ?? "unknown bundle version")
            Build: unknown date
            Location:
                [*] \(Bundle.main.bundleURL.path)
                [*] \(documentsDirectory.path)
            Jailbreak: \(JailbreakRoot.prefix) roothide=\(JailbreakRoot.isRoothide) arch=\(PackagedArchitecture.architecture)
            Environment: uid \(getuid()) gid \(getgid())
            """,
            level: .info
        )

        #if DEBUG
            for (key, value) in ProcessInfo.processInfo.environment {
                Dog.shared.join("Env", "\(key): \(value)", level: .verbose)
            }
        #endif
    }

    /// Runs `prepareUserHome` and waits for it, `timeout` at most. The log
    /// lives in the home, so the outcome goes to NSLog; a failure is left to
    /// the documents check after it.
    private static func requestHomeFromDaemon(timeout: TimeInterval = 15) {
        NSLog("[Irisin] %@ cannot be made, asking irisind to prepare it", documentsDirectory.path)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            defer { finished.signal() }
            do {
                let transcript = try await PrivilegedBackend.link.run(.prepareUserHome)
                for await event in transcript.events {
                    NSLog("[Irisin] %@", event.description)
                }
            } catch {
                NSLog("[Irisin] could not ask irisind for a home: %@", String(describing: error))
            }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("[Irisin] irisind did not make a home within %.0f seconds", timeout)
        }
    }
}
