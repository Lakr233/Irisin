//
//  InstalledController+Value.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension InstalledController {
    /// Update datasource in this routine
    /// - Parameter withSearchText: search controller passed text
    func updateSource(withSearchText: String? = nil) {
        origins = PackageCenter.default.obtainInstallOrigins()
        var read = PackageCenter
            .default
            .obtainInstalledPackageList()
            .filter {
                !($0.latestMetadata?["tag"]?.contains("role::cydia") ?? false)
                    || (withSearchText?.hasPrefix("gsc") ?? false)
            }
        sectionCounts = read.reduce(into: [:]) { $0[Self.section(of: $1), default: 0] += 1 }
        authorCounts = read.reduce(into: [:]) { counts, package in
            for author in Set(Self.authors(of: package)) {
                counts[author, default: 0] += 1
            }
        }
        let sections = selectedSections
        if !sections.isEmpty {
            read = read.filter { sections.contains(Self.section(of: $0)) }
        }
        let authors = selectedAuthors
        if !authors.isEmpty {
            read = read.filter { !authors.isDisjoint(with: Self.authors(of: $0)) }
        }
        if let search = withSearchText, search.count > 0 {
            searchFiltering(key: search, result: &read)
        }
        switch sortOption {
        case .name:
            read = read.sorted { compareName(a: $0, b: $1) }
            if sortReversed {
                read = read.reversed()
            }
            dataSource = [.init(key: nil, section: nil, packages: read)]
        case .lastModification:
            var builder = [Date?: InstalledGroup]()
            for item in read {
                let lastModifiedDate = PackageCenter
                    .default
                    .obtainLastModification(for: item.identity, and: .install)
                let section: String = if let lastModifiedDate {
                    formatter.string(from: lastModifiedDate)
                } else {
                    String(localized: "Unknown Date")
                }
                var sectionBuilder = builder[
                    lastModifiedDate,
                    default: InstalledGroup(key: lastModifiedDate, section: section, packages: [])
                ]
                sectionBuilder.packages.append(item)
                builder[lastModifiedDate] = sectionBuilder
            }
            for (key, value) in builder {
                let foo = value.packages.sorted { compareName(a: $0, b: $1) }
                builder[key] = InstalledGroup(key: key, section: value.section, packages: foo)
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
            if sortReversed {
                result = result.reversed()
            }
            // never no section at all: the layout's footer hangs off the
            // last one, and a list with none has nowhere to put it
            dataSource = result.isEmpty ? [.init(key: nil, section: nil, packages: [])] : result
        }
        applySnapshot()
    }

    /// Which installed packages have a candidate: a walk of the whole list, so
    /// it runs off the main actor and only when the packages themselves may
    /// have moved. A search keystroke cannot change the answer.
    func refreshUpdateSet() {
        updateSetTask?.cancel()
        updateSetTask = Task { [weak self] in
            let identities = await Self.identitiesWithUpdate(in: PackageCenter.default.index)
            guard !Task.isCancelled, let self else { return }
            identitiesWithUpdate = identities
            setupBarItems()
            // the indicator lives outside the package: repaint the rows
            applySnapshot()
        }
    }

    /// Two index lookups per package and the list runs into the thousands,
    /// so the page asks once and reads the answer per row.
    @concurrent
    private nonisolated static func identitiesWithUpdate(in index: PackageIndex) async -> Set<String> {
        Set(index.updateCandidates().map(\.installed.identity))
    }

    func searchFiltering(key: String, result: inout [Package]) {
        let key = key.lowercased()
        result = result
            .filter {
                let shown = origins[$0.identity] ?? $0
                let name = PackageCenter.default.name(of: shown).lowercased()
                let describe = PackageCenter.default.description(of: shown).lowercased()
                return name.contains(key) || describe.contains(key)
            }
    }

    func compareName(a: Package, b: Package) -> Bool {
        PackageCenter.default.name(of: origins[a.identity] ?? a).lowercased()
            <
            PackageCenter.default.name(of: origins[b.identity] ?? b).lowercased()
    }
}
