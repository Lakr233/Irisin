//
//  QueueChange.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import UIKit

/// One package the queue's plan touches, as the change sheet and the queue
/// page show it.
nonisolated struct QueueChange: Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable {
        /// the order a diff sorts in: what goes, what comes, what moves
        case remove, install, update, downgrade, reinstall

        /// The order the sections read in.
        static let reading: [Kind] = [.install, .update, .downgrade, .remove, .reinstall]

        /// What a section of this kind is called: "Install", or "Install
        /// (Dependencies)" for what the requests bring along.
        func title(dependencies: Bool) -> String {
            let title = switch self {
            case .remove: String(localized: "Remove")
            case .install: String(localized: "Install")
            case .update: String(localized: "Update")
            case .downgrade: String(localized: "Downgrade")
            case .reinstall: String(localized: "Reinstall")
            }
            return dependencies ? String(localized: "\(title) (Dependencies)") : title
        }
    }

    let kind: Kind
    let package: Package
    /// The installed version, for everything but a new install.
    let current: String?
    /// The user asked for this one; everything else follows from it.
    let requested: Bool

    /// Every package the plan touches, by identity.
    static func changes(of plan: ResolutionPlan?, requested: Set<String>) -> [String: QueueChange] {
        guard let plan else { return [:] }
        let installed = Dictionary(
            plan.snapshot.installed.map { ($0.identity, $0.latestVersion) },
            uniquingKeysWith: { a, _ in a }
        )
        var result: [String: QueueChange] = [:]
        for package in plan.remove {
            result[package.identity] = .init(
                kind: .remove,
                package: package,
                current: package.latestVersion,
                requested: requested.contains(package.identity)
            )
        }
        for package in plan.install {
            let current = installed[package.identity] ?? nil
            let kind: Kind = if let current, let next = package.latestVersion {
                switch Package.compareVersion(next, b: current) {
                case .aIsBiggerThenB: .update
                case .aIsSmallerThenB: .downgrade
                default: .reinstall
                }
            } else {
                .install
            }
            result[package.identity] = .init(
                kind: kind,
                package: package,
                current: current,
                requested: requested.contains(package.identity)
            )
        }
        return result
    }

    /// The list's sections in reading order, each kind's requests ahead of
    /// the dependencies they bring, rows by name.
    @MainActor
    static func sections(
        of changes: some Collection<QueueChange>
    ) -> [(kind: Kind, dependencies: Bool, changes: [QueueChange])] {
        let byName = changes.sorted { $0.name < $1.name }
        return Kind.reading.flatMap { kind in
            [false, true].compactMap { dependencies in
                let rows = byName.filter { $0.kind == kind && $0.requested != dependencies }
                return rows.isEmpty ? nil : (kind, dependencies, rows)
            }
        }
    }

    @MainActor
    var name: String {
        PackageCenter.default.name(of: package)
    }

    /// The version line: "1.0", or "1.0 → 1.1" for a move.
    var versions: String {
        let next = package.latestVersion ?? String(localized: "Unknown version")
        switch kind {
        case .update, .downgrade: return "\(current ?? "") → \(next)"
        case .remove: return current ?? next
        case .install, .reinstall: return next
        }
    }

    /// Why a package the user did not ask for is in the plan.
    @MainActor
    func reason(in plan: ResolutionPlan?, cleanup: Set<String>) -> String? {
        guard !requested else { return nil }
        let identity = package.identity
        guard kind != .remove else {
            return cleanup.contains(identity) ? String(localized: "No longer needed") : nil
        }
        let dependents = (plan?.requiredBy[identity] ?? []).map { dependent in
            plan?.finalPackages.first { $0.identity == dependent }.map(PackageCenter.default.name(of:)) ?? dependent
        }
        return dependents.isEmpty
            ? String(localized: "Required")
            : String(localized: "Required by \(ListFormatter.localizedString(byJoining: dependents))")
    }

    /// What goes under the name: the download still to come, the size on
    /// disk, and why a package nobody asked for is in `plan`.
    @MainActor
    func details(in plan: ResolutionPlan?, cleanup: Set<String>) -> [String] {
        let format = DownloadCenter.shared.byteFormat
        var details: [String] = []
        if kind != .remove, let size = package.publishedSize, !package.isOnDisk {
            details.append(String(localized: "\(format(size)) to download"))
        }
        if let size = package.installedSize {
            details.append(String(localized: "\(format(size)) on disk"))
        }
        if let reason = reason(in: plan, cleanup: cleanup) {
            details.append(reason)
        }
        return details
    }

    /// The row for this change: the package's icon, its name in bold on one
    /// line, red and struck through for a removal and green for an install,
    /// grey when `muted`, and `details` under it.
    @MainActor
    func content(icon: UIImage?, details: [String], muted: Bool = false) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.image = icon
        content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
        content.imageProperties.reservedLayoutSize = CGSize(width: 32, height: 32)
        content.imageProperties.cornerRadius = 7
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.font = .footnote
        content.secondaryTextProperties.color = .textSubtitle
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.bodyEmphasized,
            // spelled out even when off: a reused label keeps a removal's
            // strikethrough that the next text does not mention
            .strikethroughStyle: 0,
        ]
        switch kind {
        case _ where muted:
            attributes[.foregroundColor] = UIColor.textSubtitle
        case .remove:
            attributes[.foregroundColor] = UIColor.swipeDelete
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        case .install:
            attributes[.foregroundColor] = UIColor.diffAddition
        case .update, .downgrade, .reinstall:
            attributes[.foregroundColor] = UIColor.textTitle
        }
        content.attributedText = NSAttributedString(string: name, attributes: attributes)
        content.secondaryText = details.isEmpty ? nil : details.joined(separator: " · ")
        return content
    }
}

extension Package {
    /// The size the repository published, when it published one.
    var publishedSize: Int64? {
        latestMetadata?["size"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// What the package takes on disk once installed; the control file
    /// counts it in KiB.
    var installedSize: Int64? {
        latestMetadata?["installed-size"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 * 1024 : nil }
    }

    /// Has a file already, local or cached. The cache is only a hint here;
    /// the download center hashes the file before trusting it.
    var isOnDisk: Bool {
        fileOnDisk != nil
    }

    /// That file, for whoever only reads or copies it.
    var fileOnDisk: URL? {
        if let localFileURL {
            return localFileURL
        }
        guard let cached = DownloadCenter.shared.completedFiles[obtainDownloadLink()],
              FileManager.default.fileExists(atPath: cached.path)
        else { return nil }
        return cached
    }
}
