//
//  SearchResult.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/13.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import Foundation

nonisolated struct SearchResult: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case installed(package: Package)
        case repository(url: URL)
        case package(identity: String, repository: URL)
        case author(name: String)
    }

    enum Section: Hashable, Sendable {
        case installed, package, repository, author
    }

    let associatedValue: Target
    let searchText: String
    let underKey: String
    let ratio: Double

    var section: Section {
        switch associatedValue {
        case .installed: .installed
        case .package: .package
        case .repository: .repository
        case .author: .author
        }
    }

    /// A row is the thing it points at. The key and the matched text change
    /// with every keystroke; a row that stays gets reconfigured, not replaced.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.associatedValue == rhs.associatedValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(associatedValue)
    }
}

/// Walks a copy of the package index and the repositories for a key. Runs on
/// the concurrent pool and stops as soon as the task that asked is cancelled,
/// which a newer keystroke does.
nonisolated extension SearchResult {
    @concurrent
    static func search(
        key: String,
        in index: PackageIndex,
        repositories: [URL: Repository]
    ) async -> [[SearchResult]] {
        let context = Context(key: key, index: index, repositories: repositories)
        var result = [[SearchResult]]()
        for part in [
            context.installed(),
            context.packages(),
            context.repositories(),
            context.authors(),
        ] {
            if Task.isCancelled {
                return []
            }
            result.append(part)
        }
        return result.filter { !$0.isEmpty }
    }

    private struct Context {
        let key: String
        let index: PackageIndex
        let repositoryTable: [URL: Repository]

        init(key: String, index: PackageIndex, repositories: [URL: Repository]) {
            self.key = key.lowercased()
            self.index = index
            repositoryTable = repositories
        }

        /// Best match first: the ratio, then the shorter name, then the name.
        /// This used to be three chained `sorted` calls, which cost three
        /// passes and did not spell that order — `sorted` is not stable.
        private static func ranks(_ lhs: (String, SearchResult), _ rhs: (String, SearchResult)) -> Bool {
            if lhs.1.ratio != rhs.1.ratio {
                return lhs.1.ratio > rhs.1.ratio
            }
            if lhs.0.count != rhs.0.count {
                return lhs.0.count < rhs.0.count
            }
            return lhs.0 < rhs.0
        }

        private func lookupInside(
            packages: [Package],
            compiler: (Package) -> (SearchResult.Target)
        ) -> [SearchResult] {
            var result = [(String, SearchResult)]()
            autoreleasepool {
                for package in packages {
                    if Task.isCancelled {
                        return
                    }
                    let searchableContent = """
                    \(package.latestMetadata?["name"] ?? "")
                    \(package.latestMetadata?["author"] ?? "")
                    \(package.latestMetadata?["section"] ?? "")
                    \(package.latestMetadata?["description"] ?? "")
                    \(package.latestMetadata?["package"] ?? "")
                    """.lowercased()
                    if searchableContent.contains(key) {
                        var ratio = 1.0
                        let extraDecisions = [PackageCenter.default.name(of: package), package.identity]
                            .map { $0.lowercased() }
                        for extraDecision in extraDecisions where extraDecision.hasPrefix(key) {
                            ratio += 1.0
                        }
                        let search = SearchResult(
                            associatedValue: compiler(package),
                            searchText: searchableContent,
                            underKey: key,
                            ratio: ratio
                        )
                        let name = package
                            .latestMetadata?["name"]
                            ?? package.identity
                        result.append((name, search))
                    }
                }
            }
            return result.sorted(by: Self.ranks).map(\.1)
        }

        func installed() -> [SearchResult] {
            let packages = index
                .obtainInstalledPackageList()
                .filter {
                    !($0.latestMetadata?["tag"]?.contains("role::cydia") ?? false)
                        || key.hasPrefix("gsc")
                }
            return lookupInside(packages: packages) { package in
                SearchResult.Target.installed(package: package)
            }
        }

        func repositories() -> [SearchResult] {
            var result = [SearchResult]()
            for (url, repo) in repositoryTable.sorted(by: { $0.key.absoluteString < $1.key.absoluteString }) {
                if Task.isCancelled {
                    return result
                }
                let searchableContent = """
                \(url.absoluteString)
                \(repo.nickName)
                \(repo.repositoryDescription ?? "")
                """.lowercased()
                if searchableContent.contains(key) {
                    result.append(SearchResult(
                        associatedValue: .repository(url: url),
                        searchText: searchableContent,
                        underKey: key,
                        ratio: 1.0
                    ))
                }
            }
            return result
        }

        /// The full-text index answers this one; every hit already carries
        /// the columns a row shows.
        func packages() -> [SearchResult] {
            var result = [(String, SearchResult)]()
            for hit in index.search(key) {
                if Task.isCancelled {
                    return []
                }
                let searchableContent = """
                \(hit.name)
                \(hit.author)
                \(hit.section)
                \(hit.description)
                \(hit.identity)
                """.lowercased()
                var ratio = 1.0
                let name = hit.name.isEmpty ? hit.identity : hit.name
                for extraDecision in [name, hit.identity].map({ $0.lowercased() }) where extraDecision.hasPrefix(key) {
                    ratio += 1.0
                }
                let search = SearchResult(
                    associatedValue: .package(identity: hit.identity, repository: hit.repository),
                    searchText: searchableContent,
                    underKey: key,
                    ratio: ratio
                )
                result.append((name, search))
            }
            return result.sorted(by: Self.ranks).map(\.1)
        }

        func authors() -> [SearchResult] {
            var result = [SearchResult]()
            autoreleasepool {
                for author in index.obtainAuthorList() {
                    if Task.isCancelled {
                        return
                    }
                    let searchableContent = author.lowercased()
                    if searchableContent.contains(key) {
                        result.append(SearchResult(
                            associatedValue: .author(name: author),
                            searchText: searchableContent,
                            underKey: key,
                            ratio: 1.0
                        ))
                    }
                }
            }
            return result
        }
    }
}
