//
//  PackageMenu+Install.swift
//  Irisin
//

import AptRepository
import AptResolver
import Dog
import UIKit

extension PackageMenu {
    /// The alert behind the Unsupported button and behind any install path a
    /// foreign flavour still reaches.
    static func presentUnsupportedArchitecture(of package: Package, from host: UIViewController) {
        host.presentNotice(
            title: "Unsupported Architecture",
            message: String(localized: "This package is built for \(package.architectures.joined(separator: ", ")). This device uses \(EnvironmentDetector.architecture). Choose a compatible package.")
        )
    }

    static let resolveInstallRequest: Item.Block = { package, host, _ in
        guard package.isSupportedOnDevice || package.localFileURL != nil else {
            presentUnsupportedArchitecture(of: package, from: host)
            return
        }
        guard let version = package.latestVersion,
              let selected = PackageCenter
              .default
              .trim(package: package, toVersion: version)
        else {
            // no candidate version, or one the resolver cannot represent
            Dog.shared.join("PackageAction", "\(package.identity) has no installable version", level: .error)
            host.presentNotice(
                title: "Unable to Load Package",
                message: "This package could not be loaded. Try a different repository."
            )
            return
        }
        // before a purchase is checked: nobody pays for the record the
        // alert is about to talk them out of
        guard await keeps(selected, from: host) else { return }
        if selected.localFileURL != nil {
            await enqueue([.install(selected)], from: host)
            return
        }

        guard selected.isCommercial else {
            await enqueue([.install(selected)], from: host)
            return
        }
        guard let repoUrl = signedInStore(of: selected, from: host) else { return }
        let alert = progressAlert(
            title: "Checking Purchase…",
            message: "Communicating with the vendor…"
        )
        // on screen before the check: a quick answer would dismiss it while
        // it is still coming in, which UIKit ignores
        await withCheckedContinuation { done in
            host.present(alert, animated: true) { done.resume() }
        }
        // the requests time out on their own; nothing waits forever
        let check = await checkPurchase(of: selected, in: repoUrl)
        // gone before the next sheet: the host cannot present while it is leaving
        await alert.dismissFinishing(animated: true)
        if case let .purchased(purchased) = check {
            await enqueue([.install(purchased)], from: host)
        } else {
            await present(check, from: host)
        }
    }

    /// Whether the request goes on with the selected record, after a look
    /// at what else the repositories offer under its identifier. One built
    /// for this system comes ahead of one an adapter would rewrite, then a
    /// newer version of the same build. Taking a recommendation opens its
    /// page and queues nothing: the request for it is made there, by the
    /// user, with the package in front of them.
    static func keeps(_ selected: Package, from host: UIViewController) async -> Bool {
        let center = PackageCenter.default
        let advice = PackageSelectionAdvice(
            selected: selected,
            offers: Array(center.obtainPackageSummary(with: selected.identity).values),
            device: AptEnvironment.current.deviceArchitecture,
            installable: AptEnvironment.current.installableArchitectures
        )
        let installed = center.obtainPackageInstallationInfo(with: selected.identity)?.version
        let anyway = anywayTitle(for: selected, installedVersion: installed)

        if let native = advice.nativeAlternative(installedVersion: installed) {
            let choice = await host.askRecommendation(
                title: "Better Package Available",
                message: String(localized: "You selected version \(selected.latestVersion ?? ""), built for \(selected.architectures.joined(separator: ", ")), which would be installed in compatibility mode. \(repositoryName(of: native)) offers version \(native.latestVersion ?? "") built for this system."),
                anywayTitle: anyway
            )
            switch choice {
            case .recommended:
                host.present(next: PackageController(package: native))
                return false
            case .anyway: break
            case .cancel: return false
            }
        }
        // blocked updates are news the user asked not to hear
        if !center.blockedUpdateTable.contains(selected.identity),
           let newer = advice.newerAlternative(
               installedVersion: installed,
               adaptedUpdates: center.offersAdaptedUpdates
           )
        {
            let choice = await host.askRecommendation(
                title: "Newer Version Available",
                message: String(localized: "You selected version \(selected.latestVersion ?? ""). \(repositoryName(of: newer)) offers version \(newer.latestVersion ?? "")."),
                anywayTitle: anyway
            )
            switch choice {
            case .recommended:
                host.present(next: PackageController(package: newer))
                return false
            case .anyway: break
            case .cancel: return false
            }
        }
        return true
    }

    /// The button that goes on as asked, named after the menu item that asked.
    private static func anywayTitle(for selected: Package, installedVersion: String?) -> String {
        if TaskManager.shared.queuedPackage(of: selected.identity) != nil {
            return String(localized: "Replace Anyway")
        }
        guard let installedVersion, let version = selected.latestVersion else {
            return String(localized: "Install Anyway")
        }
        return switch Package.compareVersion(version, b: installedVersion) {
        case .aIsBiggerThenB: String(localized: "Update Anyway")
        case .aIsSmallerThenB: String(localized: "Downgrade Anyway")
        default: String(localized: "Reinstall Anyway")
        }
    }

    private static func repositoryName(of package: Package) -> String {
        guard let url = package.repoRef else { return "" }
        return RepositoryCenter.default.obtainImmutableRepository(withUrl: url)?.nickName
            ?? url.host
            ?? url.absoluteString
    }

    /// What the vendor said about a commercial package.
    enum PurchaseCheck {
        /// Bought: the package's `filename` is the vendor's download link,
        /// which expires.
        case purchased(Package)
        case forSale(identity: String, repository: URL)
        case vendorUnavailable
        case downloadUnavailable
        case unavailable
    }

    /// The repository a commercial package is sold from, once the user is
    /// signed in there. Nil after saying why not; signing in starts here.
    static func signedInStore(of package: Package, from host: UIViewController) -> URL? {
        guard let repoUrl = package.repoRef,
              let repo = RepositoryCenter.default.obtainImmutableRepository(withUrl: repoUrl)
        else {
            host.presentNotice(
                title: "Unable to Load Package",
                message: "This package could not be loaded. Try a different repository."
            )
            return nil
        }
        guard PaymentManager.shared.obtainStoredTokenInfomation(for: repo) != nil else {
            PaymentManager.shared.startUserAuthenticate(
                window: host.view.window ?? UIWindow(),
                controller: host,
                repoUrl: repoUrl
            ) {}
            return nil
        }
        return repoUrl
    }

    /// `package` is trimmed to the version the user picked.
    static func checkPurchase(of package: Package, in repoUrl: URL) async -> PurchaseCheck {
        guard let info = await PaymentManager.shared.obtainPackageInfo(
            for: repoUrl,
            withPackageIdentity: package.identity
        ) else {
            // jsonReply already said why; this says what it cost.
            Dog.shared.join(
                "PackageAction",
                "vendor did not answer for \(package.identity), cannot tell whether it is purchased",
                level: .error
            )
            return .vendorUnavailable
        }
        Dog.shared.join("PackageAction", "\(package.identity) purchased=\(info.purchased ?? false)", level: .info)
        guard info.purchased == true else {
            return info.available == true ? .forSale(identity: package.identity, repository: repoUrl) : .unavailable
        }
        guard let download = await PaymentManager.shared.queryDownloadLink(withPackage: package),
              let version = package.latestVersion,
              var meta = package.latestMetadata
        else {
            Dog.shared.join("PackageAction", "\(package.identity) purchased but no download link", level: .error)
            return .downloadUnavailable
        }
        meta["filename"] = download.absoluteString
        return .purchased(Package(identity: package.identity, payload: [version: meta], repoRef: repoUrl))
    }

    /// Everything but `.purchased`: the purchase to start, or why not.
    static func present(_ check: PurchaseCheck, from host: UIViewController) async {
        switch check {
        case .purchased:
            break
        case let .forSale(identity, repository):
            _ = await PaymentManager.shared.initPurchase(
                for: repository,
                withPackageIdentity: identity,
                window: host.view.window ?? UIWindow()
            )
        case .vendorUnavailable:
            host.presentNotice(
                title: "Vendor Unavailable",
                message: "The vendor did not answer. Try again."
            )
        case .downloadUnavailable:
            host.presentNotice(
                title: "Download Unavailable",
                message: "The repository did not provide a download for this purchase. Try again later."
            )
        case .unavailable:
            host.presentNotice(
                title: "Package Unavailable",
                message: "This package is not available. Contact the vendor for support."
            )
        }
    }
}

extension Package {
    /// Sold through the repository's payment endpoint.
    var isCommercial: Bool {
        latestMetadata?["tag"]?.contains("cydia::commercial") ?? false
    }
}
