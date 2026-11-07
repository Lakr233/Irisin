//
//  RepackController.swift
//  Irisin
//

import AlertController
import AptRepository
import Foundation
import IrisinProtocol
import UIKit

/// Repack: an installed package built back into a .deb by the helper, on a
/// progress card, then handed to the share sheet.
///
/// The helper runs as root and writes into a file opened here, so the
/// package is mobile's from the first byte and no path crosses the wire.
/// That is also how Cancel reaches it: the file goes, and the helper stops
/// when it finds nobody holds the file by name any more.
final class RepackController: PackageProgressCard {
    static func start(_ package: Package, from host: UIViewController, anchor: PopoverAnchor?) {
        let card = RepackController(package: package, host: host, anchor: anchor)
        host.present(AlertViewController(contentViewController: card), animated: true)
    }

    private let package: Package
    private weak var host: UIViewController?
    /// What the user touched to ask: where the share sheet points on the iPad.
    private let anchor: PopoverAnchor?

    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Archives")
    /// One at a time, since the card is modal.
    private static let partial = directory.appendingPathComponent("repack.partial")

    private init(package: Package, host: UIViewController, anchor: PopoverAnchor?) {
        self.package = package
        self.host = host
        self.anchor = anchor
        super.init(title: PackageCenter.default.name(of: package), message: String(localized: "Repacking…"))
    }

    override func cancelled() {
        try? FileManager.default.removeItem(at: Self.partial)
    }

    override func run() async {
        // what a run or a share that was killed left: a repacked package can
        // hold what only root could read, so none outlives its sheet for long
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let descriptor = open(Self.partial.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            await close()
            host?.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        defer { Darwin.close(descriptor) }

        var repacked: InstallerEvent.Repacked?
        var problem: InstallerEvent.Problem?
        let status = await PrivilegedBackend.run(
            .repack(identity: package.identity),
            descriptor: descriptor
        ) { @MainActor [weak self] event in
            switch event {
            case let .packageProgress(_, completed, total):
                self?.show(completed: completed, total: total)
            case let .repacked(result):
                repacked = result
            case let .failure(reported):
                problem = reported
            default:
                break
            }
        }
        await close()
        guard !Task.isCancelled, let host else { return cancelled() }
        guard status == 0, let repacked else {
            cancelled()
            let reason = problem ?? .helperUnreachable
            host.presentNotice(title: "Unable to Repack", message: reason.localizedDescription)
            return
        }
        hand(over: repacked, from: host)
    }

    /// The package under the name `dpkg-name` would give it, after saying
    /// what is not as it was installed.
    private func hand(over repacked: InstallerEvent.Repacked, from host: UIViewController) {
        let file = Self.directory.appendingPathComponent((repacked.fileName as NSString).lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: Self.partial, to: file)
        } catch {
            cancelled()
            host.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        let anchor = anchor
        let share = { [weak host] in
            guard let host else { return }
            ShareSheet.present([file], anchor: anchor, from: host) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        var differences: [String] = []
        if repacked.leftOut > 0 {
            differences.append(String(localized: "Missing files: \(repacked.leftOut)"))
        }
        if repacked.changed > 0 {
            differences.append(String(localized: "Files changed since installation: \(repacked.changed)"))
        }
        guard !differences.isEmpty else { return share() }
        host.presentNotice(
            title: "Repacked with Differences",
            message: differences.joined(separator: "\n"),
            dismissTitle: "Share",
            onDismiss: share
        )
    }

    private func show(completed: Int, total: Int) {
        guard total > 0 else { return }
        let downloads = Downloads.shared
        show(
            message: String(localized: "Repacking…"),
            fraction: Double(completed) / Double(total),
            count: String(localized: "\(downloads.byteFormat(bytes: Int64(completed))) of \(downloads.byteFormat(bytes: Int64(total)))")
        )
    }
}
