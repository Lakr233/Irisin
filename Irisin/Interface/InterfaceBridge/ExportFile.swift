//
//  ExportFile.swift
//  Irisin
//

import AptRepository
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
    static func shareRepository(_ url: URL, from host: UIViewController, anchor: UIView?) {
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
        anchor: @escaping () -> UIView?
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
    /// `anchor` when the caller has a view, and what `presentShareSheet`
    /// finds on the page when it does not.
    static func share(_ data: Data, named name: String, from host: UIViewController, anchor: UIView? = nil) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            host.presentNotice(title: "Unable to Export", message: "The file could not be written. Try again.")
            return
        }
        host.presentShareSheet([file], anchor: anchor.map { PopoverAnchor($0) })
    }
}
