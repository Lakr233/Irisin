//
//  PackageSelectionAdvice.swift
//  Irisin
//

import AptRepository
import Foundation

/// What the added repositories offer under the identifier of a package on
/// its way to the queue, and whether one of those records is the better
/// pick: a newer version. The selected record is trimmed to
/// its version; an offer is a repository's whole record, read at its newest.
nonisolated struct PackageSelectionAdvice {
    let selected: Package
    /// Every other installable record of the identifier, at its newest
    /// version built for this system.
    let candidates: [Package]
    let device: String

    init(selected: Package, offers: [Package], device: String) {
        self.selected = selected
        self.device = device
        candidates = offers.compactMap { offer -> Package? in
            guard offer.identity == selected.identity,
                  let version = offer.versions(builtFor: device)?.latestVersion,
                  let trimmed = PackageCenter.default.trim(package: offer, toVersion: version),
                  // what a menu would not offer is not recommended either
                  trimmed.obtainDownloadLink() != PackageBadUrl,
                  trimmed != selected
            else { return nil }
            return trimmed
        }
    }

    /// A newer version. A version below the installed one was picked to go
    /// down, so nothing newer is news.
    func newerAlternative(installedVersion: String?) -> Package? {
        guard let version = selected.latestVersion else { return nil }
        if let installedVersion, goesDown(selected, below: installedVersion) {
            return nil
        }
        return best(of: candidates.filter { candidate in
            guard let offered = candidate.latestVersion else { return false }
            return Package.compareVersion(offered, b: version) == .aIsBiggerThenB
        })
    }

    private func goesDown(_ package: Package, below installed: String) -> Bool {
        Package.compareVersion(package.latestVersion ?? "", b: installed) == .aIsSmallerThenB
    }

    /// The newest; at a tie a build for this architecture ahead of an `all`
    /// one, then the selected record's repository, then the address, so two
    /// reads of the same index recommend the same record.
    private func best(of list: [Package]) -> Package? {
        func precedes(_ a: Package, _ b: Package) -> Bool {
            switch Package.compareVersion(a.latestVersion ?? "", b: b.latestVersion ?? "") {
            case .aIsBiggerThenB: return true
            case .aIsSmallerThenB: return false
            default: break
            }
            let exact = (a.architectures.contains(device), b.architectures.contains(device))
            if exact.0 != exact.1 {
                return exact.0
            }
            let kept = (a.repoRef == selected.repoRef, b.repoRef == selected.repoRef)
            if kept.0 != kept.1 {
                return kept.0
            }
            return (a.repoRef?.absoluteString ?? "") < (b.repoRef?.absoluteString ?? "")
        }
        return list.max { precedes($1, $0) }
    }
}
