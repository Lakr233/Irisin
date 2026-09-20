//
//  ExportFile.swift
//  Irisin
//

import AptRepository
import Dog
import IrisinProtocol
import UIKit

/// Everything the app hands out as a file goes through here: a stamp for the
/// name, the share sheet, and the one text shape a package list is exported
/// in. There is no choice of format any more — a repository list is our own
/// file type, a package list is plain text.
enum ExportFile {
    /// A readable date for an exported file's name.
    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    /// One package a line: identity, name and version, tab separated.
    static func packageText(_ packages: [Package]) -> Data {
        Data(packages
            .map { [$0.identity, PackageCenter.default.name(of: $0), $0.latestVersion ?? ""].joined(separator: "\t") }
            .joined(separator: "\n")
            .utf8)
    }

    /// One repository as a `.irisinrepos` with a single entry: Share on the
    /// list, on the iPad's sidebar and on the repository's own page all hand
    /// out the same file.
    static func shareRepository(_ url: URL, from host: UIViewController, anchor: PopoverAnchor?) {
        guard let source = RepositoryCenter.default.obtainImmutableRepository(withUrl: url)?.source,
              let data = try? RepositoryListFile(sources: [source]).encoded()
        else {
            host.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        share(data, named: "\(url.host ?? "repository").irisinrepos", from: host, anchor: anchor)
    }

    /// Export All Repository Information…, the same action on the repository
    /// list's long press and on the iPad sidebar's.
    static func exportRepositoryAction(
        _ url: URL,
        host: @escaping () -> UIViewController?,
        anchor: @escaping () -> PopoverAnchor?
    ) -> UIAction {
        UIAction(
            title: String(localized: "Export All Repository Information…"),
            image: UIImage(systemName: "square.and.arrow.up.on.square")
        ) { _ in
            guard let host = host(),
                  let repository = RepositoryCenter.default.obtainImmutableRepository(withUrl: url)
            else { return }
            // the catalogue of a large repository is megabytes of rows; the
            // main actor takes the handle and nothing else
            let index = PackageCenter.default.index
            let name = "\(url.host ?? "repository")-\(stamp()).irisinrepo"
            Task {
                guard let data = await encodeRepository(repository, from: index) else {
                    host.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
                    return
                }
                share(data, named: name, from: host, anchor: anchor())
            }
        }
    }

    @concurrent
    private static func encodeRepository(_ repository: Repository, from index: PackageIndex) async -> Data? {
        let packages = index.obtainPackageList(in: repository.url)
        return try? RepositoryFile(repository: repository, packages: packages).encoded()
    }

    /// Writes the bytes beside the app's other temporaries and puts the share
    /// sheet over `host`. On the iPad a popover needs somewhere to point:
    /// `anchor` when the caller has one, and what `ShareSheet.popoverTarget`
    /// finds on the page when it does not.
    static func share(_ data: Data, named name: String, from host: UIViewController, anchor: PopoverAnchor? = nil) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            host.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        ShareSheet.present([file], anchor: anchor, from: host)
    }

    // MARK: - WHOLE EXPORTS

    /// Every registered repository as one `.irisinrepos`.
    static func shareRepositoryList(from host: UIViewController, anchor: PopoverAnchor? = nil) {
        let sources = RepositoryCenter.default.obtainRepositoryUrls()
            .compactMap { RepositoryCenter.default.obtainImmutableRepository(withUrl: $0)?.source }
        guard !sources.isEmpty else {
            host.presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        guard let data = try? RepositoryListFile(sources: sources).encoded() else {
            host.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        share(data, named: "Repositories-\(stamp()).irisinrepos", from: host, anchor: anchor)
    }

    /// Everything installed, one package a line, by name.
    static func shareInstalledPackageList(from host: UIViewController, anchor: PopoverAnchor? = nil) {
        let packages = PackageCenter.default.obtainInstalledPackageList()
            .sorted { $0.identity < $1.identity }
        guard !packages.isEmpty else {
            host.presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        share(packageText(packages), named: "installed-\(stamp()).txt", from: host, anchor: anchor)
    }

    /// dpkg's own status file, the raw record of what is installed.
    static func shareStatus(from host: UIViewController, anchor: PopoverAnchor? = nil) {
        shareCopy(
            of: JailbreakRoot.installedPath("/Library/dpkg/status"),
            named: "dpkg-status-\(stamp()).txt",
            from: host,
            anchor: anchor
        )
    }

    /// The helper's plain-text account of its last run.
    static func shareInstallerLog(from host: UIViewController, anchor: PopoverAnchor? = nil) {
        shareCopy(
            of: JailbreakRoot.installedPath(IrisinWire.installerLogPath),
            named: "irisin-install-\(stamp()).log",
            from: host,
            anchor: anchor
        )
    }

    /// This launch's journal, what Logs shows.
    static func shareAppLog(from host: UIViewController, anchor: PopoverAnchor? = nil) {
        let text = Dog.shared.obtainCurrentLogContent()
        guard !text.isEmpty else {
            host.presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        share(Data(text.utf8), named: "irisin-\(stamp()).log", from: host, anchor: anchor)
    }

    /// A copy, so the sheet never holds a bootstrap file open while its
    /// owner rewrites it. A file that is not there is nothing to export.
    private static func shareCopy(
        of path: String,
        named name: String,
        from host: UIViewController,
        anchor: PopoverAnchor?
    ) {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            host.presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        share(data, named: name, from: host, anchor: anchor)
    }

    /// Export… as a submenu: the same files wherever it hangs.
    static func menu(from host: UIViewController, anchor: @escaping () -> PopoverAnchor?) -> UIMenu {
        func action(
            _ title: String,
            _ symbol: String,
            _ run: @escaping (UIViewController, PopoverAnchor?) -> Void
        ) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak host] _ in
                guard let host else { return }
                run(host, anchor())
            }
        }
        return UIMenu(
            title: String(localized: "Export…"),
            image: UIImage(systemName: "square.and.arrow.up"),
            children: [
                UIMenu(options: .displayInline, children: [
                    action(String(localized: "Export Repository List"), "list.bullet.rectangle") {
                        shareRepositoryList(from: $0, anchor: $1)
                    },
                    action(String(localized: "Export Package List"), "shippingbox") {
                        shareInstalledPackageList(from: $0, anchor: $1)
                    },
                    action(String(localized: "Export dpkg Status"), "doc.text") {
                        shareStatus(from: $0, anchor: $1)
                    },
                ]),
                UIMenu(options: .displayInline, children: [
                    action(String(localized: "Export Installer Log"), "doc.plaintext") {
                        shareInstallerLog(from: $0, anchor: $1)
                    },
                    action(String(localized: "Export App Log"), "ladybug") {
                        shareAppLog(from: $0, anchor: $1)
                    },
                ]),
            ]
        )
    }
}
