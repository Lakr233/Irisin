//
//  DownloadArchiveController.swift
//  Irisin
//

import AlertController
import AptRepository
import UIKit

/// Download Archive: one package's .deb fetched the way the queue fetches
/// it — the vendor's link for a purchase, the verified download cache when
/// the file is there — on a progress card, then handed to the share sheet.
/// Cancel stops the download unless the queue needs the same file.
final class DownloadArchiveController: PackageProgressCard {
    static func start(for package: Package, from host: UIViewController, anchor: PopoverAnchor?) {
        var store: URL?
        if package.isCommercial {
            guard let signedIn = PackageMenu.signedInStore(of: package, from: host) else { return }
            store = signedIn
        }
        let card = DownloadArchiveController(package: package, store: store, host: host, anchor: anchor)
        host.present(AlertViewController(contentViewController: card), animated: true)
    }

    private let package: Package
    /// The repository to ask for the purchased link; nil for a free package.
    private let store: URL?
    private weak var host: UIViewController?
    /// What the user touched to ask: where the share sheet points on the iPad.
    private let anchor: PopoverAnchor?

    private init(package: Package, store: URL?, host: UIViewController, anchor: PopoverAnchor?) {
        self.package = package
        self.store = store
        self.host = host
        self.anchor = anchor
        super.init(
            title: PackageCenter.default.name(of: package),
            message: store == nil ? String(localized: "Preparing…") : String(localized: "Checking Purchase…")
        )
    }

    // MARK: - Work

    override func run() async {
        var target = package
        if let store {
            let check = await PackageMenu.checkPurchase(of: package, in: store)
            guard case let .purchased(purchased) = check else {
                guard !Task.isCancelled else { return }
                await close()
                if let host {
                    await PackageMenu.present(check, from: host)
                }
                return
            }
            target = purchased
        }
        guard !Task.isCancelled else { return }

        let downloads = Downloads.shared
        let url = target.obtainDownloadLink()
        downloads.downloadArchive(target)
        defer { downloads.release(target) }
        // ponytail: polls four times a second like the queue page; a
        // publisher on the statuses if the tick ever shows
        while downloads.isDownloading(url) {
            show(downloads.status(for: url))
            try? await Task.sleep(continuousSeconds: 0.25)
            guard !Task.isCancelled else { return }
        }
        let status = downloads.status(for: url)
        await close()
        // Cancel may land while the card leaves
        guard !Task.isCancelled else { return }
        guard let file = status?.file, FileManager.default.fileExists(atPath: file.path) else {
            host?.presentNotice(
                title: "Download Failed",
                message: status?.errorDescription ?? String(localized: "The download was interrupted.")
            )
            return
        }
        share(file, of: target)
    }

    private func share(_ file: URL, of package: Package) {
        guard let copy = try? Self.namedCopy(of: file, for: package) else {
            host?.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        guard let host else { return }
        ShareSheet.present([copy], anchor: anchor, from: host)
    }

    /// A copy under the name dpkg-name would give it, so what lands in
    /// Files or AirDrop says what it is.
    nonisolated static func namedCopy(of file: URL, for package: Package) throws -> URL {
        let version = package.latestVersion?.split(separator: ":").last.map(String.init) ?? "0"
        let architecture = package.latestMetadata?["architecture"] ?? "all"
        let name = [package.identity, version, architecture]
            .joined(separator: "_")
            .replacingOccurrences(of: "/", with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Archives")
        let copy = directory.appendingPathComponent(name + ".deb")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    // MARK: - Card

    private func show(_ status: Downloads.Status?) {
        guard let status, status.completedBytes > 0 else {
            return show(message: String(localized: "Preparing…"))
        }
        let downloads = Downloads.shared
        // every byte is in: the file is being hashed, a cached one included
        let verifying = status.completedBytes >= status.totalBytes
        show(
            message: verifying ? String(localized: "Verifying…") : String(localized: "Downloading…"),
            fraction: status.fractionCompleted,
            count: String(localized: "\(downloads.byteFormat(bytes: status.completedBytes)) of \(downloads.byteFormat(bytes: status.totalBytes))")
        )
    }
}
