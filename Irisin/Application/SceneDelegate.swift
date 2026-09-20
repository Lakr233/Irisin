//
//  SceneDelegate.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/17.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import UIKit
import UniformTypeIdentifiers

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let reloadThrottle = Throttler(minimumDelay: 0.5)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        self.window = window

        guard PackagedArchitecture.incompatibilityMessage == nil else {
            window.rootViewController = UnsupportedArchitectureController()
            window.makeKeyAndVisible()
            return
        }

        // The interface is the root from the first frame: a tab bar that
        // arrives later, over a loading screen, draws itself in as it comes.
        // Laid out once the window has its size, which is what picks the
        // layout, and before anything is drawn.
        window.rootViewController = InterfaceHostController()
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // created from user activity
        if let userActivity = options.userActivities.first ?? session.stateRestorationActivity {
            if !configure(with: userActivity) {
                Dog.shared.join(self, "failed to restore from \(userActivity)", level: .warning)
            }
            return
        }

        // if not, check for url schemes
        let urlContexts = options.urlContexts
        Task {
            self.scene(scene, openURLContexts: urlContexts)
        }
    }

    private func configure(with activity: NSUserActivity) -> Bool {
        guard activity.title == NSUserActivity.dropPackageActivityType,
              let data = activity.userInfo?["attach"] as? Data,
              let package = Package.propertyListDecoded(with: data)
        else { return false }
        Task {
            await interface()?.pageStack?.pushViewController(PackageController(package: package), animated: true)
        }
        return true
    }

    func sceneDidBecomeActive(_: UIScene) {
        guard PackagedArchitecture.incompatibilityMessage == nil else { return }
        Dog.shared.join(self, "sceneDidBecomeActive", level: .info)
        // at launch the first read is `load()`'s own, and a second one right
        // behind it reads the same file
        guard AppBootstrap.isFinished else { return }
        reloadThrottle.throttle {
            Task {
                await PackageCenter.default.reloadLocalPackages()
            }
        }
    }

    func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard PackagedArchitecture.incompatibilityMessage == nil else { return }
        for item in URLContexts {
            if item.url.isFileURL {
                open(file: item.url, inPlace: item.options.openInPlace)
                continue
            }
            guard let link = IrisinLink(item.url) else {
                Dog.shared.join(self, "refused link \(item.url.absoluteString)", level: .warning)
                presentNotice(title: "Unable to Open Link", message: "This link is not valid.")
                continue
            }
            Dog.shared.join(self, "opening link \(item.url.absoluteString)")
            switch link {
            case let .addRepositories(sources): openQuickAddRepo(sources)
            case let .package(identity): openPackage(identity)
            }
        }
    }

    /// The interface once the engines are up, so what is opened in it finds
    /// the repositories and packages it asks for. Nothing where the
    /// interface never opens.
    private func interface() async -> InterfaceHostController? {
        guard await AppBootstrap.finished() else { return nil }
        return window?.rootViewController as? InterfaceHostController
    }

    private func openQuickAddRepo(_ sources: [RepositorySource]) {
        Task {
            guard let interface = await interface() else { return }
            // a sheet the user has open stays, with this one over it
            (interface.presentedViewController ?? interface)
                .present(RepositoryAddController.sheet(candidates: sources, origin: .link), animated: true)
        }
    }

    /// The package as the newest repository offers it, else what dpkg reports
    /// is installed. A link to a package no added repository has opens
    /// nothing: there is no page to show, and a blank one would be a lie.
    private func openPackage(_ identity: String) {
        Task {
            guard let interface = await interface() else { return }
            let center = PackageCenter.default
            let offered = center.newestPackage(
                of: Array(center.obtainPackageSummary(with: identity).values),
                preferring: center.obtainInstallOrigin(of: identity)?.repoRef
            )
            guard let package = offered
                ?? center.obtainInstalledPackageList().first(where: { $0.identity == identity })
            else {
                (interface.presentedViewController ?? interface).presentNotice(
                    title: "Package Not Found",
                    message: "No added repository offers “\(identity)”. Add the repository that has it, then try again."
                )
                return
            }
            interface.pageStack?.pushViewController(PackageController(package: package), animated: true)
        }
    }

    /// A file the system handed us, by what it is rather than by its name.
    /// Opened in place it is still the user's own file, sitting in Files: it
    /// is read through a security scope and never moved.
    private func open(file url: URL, inPlace: Bool) {
        let type = UTType(filenameExtension: url.pathExtension)
        if type == .irisinRepositoryList || type == .irisinRepository {
            importRepositories(from: url, inPlace: inPlace)
        } else if type == .debArchive {
            openQuickInstall(url: url, inPlace: inPlace)
        } else {
            Dog.shared.join(self, "refused file \(url.lastPathComponent)", level: .warning)
            presentNotice(title: "Unable to Open Link", message: "This link is not valid.")
        }
    }

    private func importRepositories(from url: URL, inPlace: Bool) {
        let scoped = inPlace && url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url),
              let sources = try? RepositoryListFile.sources(in: data)
        else {
            presentNotice(title: "Unable to Import", message: "This file could not be read. Choose another file.")
            return
        }
        Task {
            // what is already added is known once the repositories are read
            guard let interface = await interface() else { return }
            let registered = Set(RepositoryCenter.default.obtainRepositoryUrls())
            let fresh = sources.filter { !registered.contains($0.url) }
            guard !fresh.isEmpty else {
                presentNotice(title: "Nothing to Import", message: "This file has no new repositories to add.")
                return
            }
            (interface.presentedViewController ?? interface)
                .present(RepositoryAddController.sheet(candidates: fresh, origin: .file), animated: true)
        }
    }

    private func openQuickInstall(url: URL, inPlace: Bool) {
        Task {
            let target = DebOpenController()
            target.patternLocation = url
            target.openedInPlace = inPlace
            await interface()?.pageStack?.pushViewController(target, animated: true)
        }
    }

    /// The scene delegate is not a view controller, so an alert waits for the
    /// interface the same way a page does.
    private func presentNotice(title: String.LocalizationValue, message: String.LocalizationValue) {
        Task {
            guard let interface = await interface() else { return }
            (interface.presentedViewController ?? interface).presentNotice(title: title, message: message)
        }
    }
}
