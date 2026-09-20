//
//  DashboardController+Sections.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/15.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension DashboardController {
    nonisolated struct Section: Sendable {
        let title: String
        let packages: [Package]
        let shouldLimit: Bool
        let action: (@MainActor @Sendable (UIViewController?) -> Void)?
    }

    /// Takes a copy of what the centers know and builds the sections off the
    /// main actor.
    static func sections() async -> [Section] {
        await build(
            index: PackageCenter.default.index,
            repositories: RepositoryCenter.default.repositories
        )
    }

    @concurrent
    private nonisolated static func build(
        index: PackageIndex,
        repositories: [URL: Repository]
    ) async -> [Section] {
        var builder = [Section?]()
        builder.append(buildAvailableUpdate(index))
        builder.append(buildRecentUpdate(index))
        builder.append(buildRepoFeatured(index, repositories))
        builder.append(buildRecentInstall(index))
        return builder
            .compactMap(\.self)
            .filter { $0.packages.count > 0 }
    }

    private nonisolated static func buildAvailableUpdate(_ index: PackageIndex) -> Section? {
        let candidates = index.updateCandidates().map(\.candidate)
        return Section(
            title: String(localized: "Updates"),
            packages: candidates.sorted { a, b in
                PackageCenter.default.name(of: a)
                    < PackageCenter.default.name(of: b)
            },
            shouldLimit: false,
            action: { controller in
                UpdateController.show(from: controller)
            }
        )
    }

    private nonisolated static func buildRepoFeatured(
        _ index: PackageIndex,
        _ repositories: [URL: Repository]
    ) -> Section? {
        var builder = [Package]()
        for repo in repositories.values {
            for banner in FeaturedBanner.entries(in: repo) {
                guard let identity = banner["package"] as? String,
                      let package = index.obtainPackage(with: identity.lowercased(), in: repo.url)
                else {
                    continue
                }
                builder.append(package)
            }
        }
        return Section(
            title: String(localized: "Featured"),
            packages: builder.sorted { a, b in
                PackageCenter.default.name(of: a)
                    < PackageCenter.default.name(of: b)
            },
            shouldLimit: true,
            action: nil
        )
    }

    private nonisolated static func buildRecentInstall(_ index: PackageIndex) -> Section? {
        let everything = index
            .obtainInstalledPackageList()
            .filter { !($0.latestMetadata?["tag"]?.contains("role::cydia") ?? false) }

        var builder = [Date?: [Package]]()
        for item in everything {
            let lastModifiedDate = index.obtainLastModification(for: item.identity, and: .install)
            builder[lastModifiedDate, default: []].append(item)
        }
        for (key, value) in builder {
            builder[key] = value.sorted { a, b in
                PackageCenter.default.name(of: a)
                    < PackageCenter.default.name(of: b)
            }
        }
        let none = builder[nil]
        let constructor = builder
            .map { ($0, $1) }
            .filter { $0.0 != nil }
            .sorted { pairA, pairB in
                pairA.0 ?? Date() > pairB.0 ?? Date()
            }
        var result = constructor.map(\.1)
        if let none {
            result.append(none)
        }

        return Section(
            title: String(localized: "Recent Installs"),
            packages: result.flatMap(\.self),
            shouldLimit: true,
            action: nil
        )
    }

    private nonisolated static func buildRecentUpdate(_ index: PackageIndex) -> Section? {
        let list = index.obtainRecentUpdatedList()
        guard list.count > 0 else {
            return nil
        }
        var builder = [Package]()
        for key in list.keys.sorted(by: { $0 > $1 }) {
            let compiler = list[key, default: []]
                .compactMap { identity, repoUrl -> Package? in
                    if let url = repoUrl,
                       let package = index.obtainPackage(with: identity, in: url)
                    {
                        package
                    } else {
                        PackageCenter.default.newestPackage(
                            of: Array(index.obtainPackageSummary(with: identity).values),
                            preferring: index.obtainInstallOrigin(of: identity)?.repoRef
                        )
                    }
                }
                .sorted {
                    PackageCenter.default.name(of: $0)
                        < PackageCenter.default.name(of: $1)
                }
            builder.append(contentsOf: compiler)
        }
        return Section(
            title: String(localized: "Recent Updates"),
            packages: builder,
            shouldLimit: true
        ) { controller in
            var list = PackageCenter
                .default
                .obtainRecentUpdatedList()
            guard list.count > 0 else {
                return
            }
            for (key, value) in list {
                list[key] = value.sorted { $0.0 < $1.0 }
            }
            let target = RecentUpdateController()
            target.updateDataSource = list
            controller?.present(next: target)
        }
    }
}
