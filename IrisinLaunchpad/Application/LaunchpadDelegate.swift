//
//  LaunchpadDelegate.swift
//  IrisinLaunchpad
//

import UIKit

/// The launchpad: Irisin on Apple TV and Vision Pro, where a browser on
/// another device is the interface and this app serves it
/// (Documentation/WebManagement.md). It shares the app's services
/// (`Irisin/Services`) and engines, and has one screen of its own.
@main
final class LaunchpadDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        willFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppEnvironment.prepare()
        return true
    }

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        AppBootstrap.start()
        Task { await LaunchpadSetup.addRecommendedRepositories() }
        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting session: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = LaunchpadSceneDelegate.self
        return configuration
    }

    func applicationWillTerminate(_: UIApplication) {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }
}
