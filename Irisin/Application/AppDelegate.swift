//
//  AppDelegate.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/17.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

// preconcurrency: the configuration is a plain static var upstream, written
// here once before any alert exists
@preconcurrency import AlertController
import AptRepository
import Combine
import Dog
import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    var repositoryUpdateSubscription: AnyCancellable?

    /// possible fix for some tweak crashing on something isn't my problem actually
    /// -[irisin.AppDelegate window]: unrecognized selector sent to instance
    var window: UIWindow?

    func application(
        _: UIApplication,
        willFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Self.prepareEnvironment()
        return true
    }

    /// Everything that touches `documentsDirectory`, in order: the reset the
    /// Settings app can ask for, the directory, the log, settings and the
    /// repository engine.
    private static func prepareEnvironment() {
        // MARK: - Document

        let reset = resetApplicationDataIfRequested()
        do {
            try? FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            var isDir = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: documentsDirectory.path, isDirectory: &isDir)
            guard exists, isDir.boolValue else {
                fatalError("Broken Document Permission")
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

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        observeRepositoryUpdates()

        // before the first table, label or scene exists
        #if !DEBUG
            UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        #endif
        UITableView.appearance().sectionHeaderTopPadding = 0.0
        adoptDynamicTypeEverywhere()

        AppBootstrap.start()

        // the promoted button is the app's accent; red is kept for the
        // confirmations that destroy something
        AlertControllerConfiguration.accentColor = .buttonNormal
        // every alert wears the app icon, read from the bundle's own icon
        // entry so it follows whatever Icon Composer renders
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        if let name = (primary?["CFBundleIconFiles"] as? [String])?.last {
            AlertControllerConfiguration.alertImage = UIImage(named: name)
        }

        return true
    }

    func applicationWillTerminate(_: UIApplication) {
        UIApplication.gracefullyTerminate()
    }
}

extension UIApplication {
    static func gracefullyTerminate() {
        Dog.shared.join("Terminator", "calling gracefully terminate", level: .warning)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    static func prepareForExitAndSuspend() {
        UIApplication.gracefullyTerminate()
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }
}
