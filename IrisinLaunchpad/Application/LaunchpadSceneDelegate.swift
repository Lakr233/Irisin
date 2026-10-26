//
//  LaunchpadSceneDelegate.swift
//  IrisinLaunchpad
//

import Combine
import UIKit

/// Serves the page while the launchpad is in front, and only then: each
/// time it comes back it shows a new code. The screen stays awake while it
/// serves, so the code is there when the browser asks.
final class LaunchpadSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var registration: AnyCancellable?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = LaunchpadController()
        window.makeKeyAndVisible()
        self.window = window

        // An update that stopped the launchpad before it registered itself
        // leaves LaunchServices with the build before this one: it asks once
        // the daemon answers, then leaves, as the app does.
        registration = PrivilegedBackend.backendUpdates
            .compactMap(\.self)
            .first()
            .receive(on: DispatchQueue.main)
            .sink { backend in
                guard backend.isPrivileged, OwnRegistration.claimStaleRegistration() else { return }
                WebManagement.shared.stop()
                Task {
                    _ = await OwnRegistration.request()
                    exit(0)
                }
            }
    }

    func sceneWillEnterForeground(_: UIScene) {
        serve()
    }

    func sceneDidBecomeActive(_: UIScene) {
        serve()
    }

    func sceneDidEnterBackground(_: UIScene) {
        WebManagement.shared.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func serve() {
        // a build for another bootstrap reads nothing, and serves nothing
        guard PackagedArchitecture.incompatibilityMessage == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        WebManagement.shared.start()
    }
}
