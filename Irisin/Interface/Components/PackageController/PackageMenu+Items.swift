//
//  PackageMenu+Items.swift
//  Irisin
//

import AptRepository
import AptResolver
import SPIndicator
import UIKit

extension PackageMenu {
    static let allMenuActions: [Item] = [
        .init(
            descriptor: .dequeue,
            block: { package, host, _ in
                await QueueChangeController.show(.withdraw(package.identity), from: host)
            },
            eligibleForPerform: { package in
                TaskManager.shared.isQueued(package.identity)
            }
        ),
        .init(
            descriptor: .replace,
            block: resolveInstallRequest,
            eligibleForPerform: { package in
                guard let queued = TaskManager.shared.queuedPackage(of: package.identity),
                      package.localFileURL != nil
                      || (package.isSupportedOnDevice && package.obtainDownloadLink() != PackageBadUrl),
                      let version = package.latestVersion,
                      let requested = PackageCenter.default.trim(package: package, toVersion: version)
                else { return false }
                return queued != requested
            }
        ),
        .init(
            descriptor: .directInstall,
            block: resolveInstallRequest,
            eligibleForPerform: { package in
                package.localFileURL != nil
                    && PackageCenter.default.obtainPackageInstallationInfo(with: package.identity) == nil
            }
        ),
        .init(
            descriptor: .install,
            block: resolveInstallRequest,
            eligibleForPerform: { package in
                guard package.isSupportedOnDevice,
                      package.localFileURL == nil,
                      package.obtainDownloadLink() != PackageBadUrl
                else {
                    return false
                }
                return PackageCenter
                    .default
                    .obtainPackageInstallationInfo(with: package.identity)
                    == nil
            }
        ),
        .init(
            descriptor: .update,
            block: resolveInstallRequest,
            eligibleForPerform: { package in
                if package.obtainDownloadLink() == PackageBadUrl {
                    return false
                }
                // this row is the candidate, whichever repository it is
                // from: taking it by hand is how the user moves a package
                // to another repository. A file explicitly opened by the
                // user can update even when repository updates are blocked.
                if package.localFileURL != nil || !PackageCenter.default.blockedUpdateTable.contains(package.identity),
                   let info = PackageCenter
                   .default
                   .obtainPackageInstallationInfo(with: package.identity),
                   let current = package.latestVersion
                {
                    return Package.compareVersion(current, b: info.version) == .aIsBiggerThenB
                }
                return false
            }
        ),
        .init(
            descriptor: .reinstall,
            block: resolveInstallRequest,
            eligibleForPerform: { package in
                if package.obtainDownloadLink() == PackageBadUrl {
                    return false
                }
                guard let info = PackageCenter.default.obtainPackageInstallationInfo(with: package.identity),
                      let current = package.latestVersion
                else { return false }
                return Package.compareVersion(current, b: info.version) == .aIsEqualToB
            }
        ),
        .init(
            descriptor: .downgrade,
            block: resolveInstallRequest,
            eligibleForPerform: { package in
                if package.obtainDownloadLink() == PackageBadUrl {
                    return false
                }
                guard let info = PackageCenter
                    .default
                    .obtainPackageInstallationInfo(with: package.identity),
                    let current = package.latestVersion
                else { return false }
                return Package.compareVersion(current, b: info.version) == .aIsSmallerThenB
            }
        ),
        .init(
            descriptor: .remove,
            block: { package, host, _ in
                await enqueue([.remove(package.identity)], from: host)
            },
            eligibleForPerform: { package in
                PackageCenter
                    .default
                    .obtainPackageInstallationInfo(with: package.identity)
                    != nil
            }
        ),
        .init(
            descriptor: .versionControl,
            block: { package, host, _ in
                let sheet = PackageVersionPickerController.sheet(package: package) { [weak host] picked in
                    guard let host else { return }
                    if let page = host as? PackageController {
                        // the page under the sheet becomes the chosen version
                        page.show(picked)
                    } else {
                        // opened from a list: the chosen version gets its own page
                        host.present(next: PackageController(package: picked))
                    }
                }
                host.present(sheet, animated: true)
            },
            eligibleForPerform: { _ in true }
        ),
        .init(descriptor: .blockUpdate, block: { package, _, _ in
            PackageCenter.default.blockedUpdateTable.append(package.identity)
            SPIndicator.present(
                title: String(localized: "Done"),
                message: nil,
                preset: .done,
                haptic: .success,
                from: .top,
                completion: nil
            )
        }, eligibleForPerform: { package in
            !PackageCenter.default.blockedUpdateTable.contains(package.identity)
        }),
        .init(descriptor: .unblockUpdate, block: { package, _, _ in
            PackageCenter.default.blockedUpdateTable.removeAll { $0 == package.identity }
            SPIndicator.present(
                title: String(localized: "Done"),
                message: nil,
                preset: .done,
                haptic: .success,
                from: .top,
                completion: nil
            )
        }, eligibleForPerform: { package in
            PackageCenter.default.blockedUpdateTable.contains(package.identity)
        }),
        .init(descriptor: .download, block: { package, host, anchor in
            DownloadArchiveController.start(for: package, from: host, anchor: anchor)
        }, eligibleForPerform: { package in
            package.localFileURL == nil && package.obtainDownloadLink() != PackageBadUrl
        }),
        .init(descriptor: .viewMeta, block: { package, host, _ in
            // every field the repository gave, in the order dpkg would list them
            let text = (package.latestMetadata ?? [:])
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            host.present(next: TextReaderController(title: String(localized: "Package Info"), text: text))
        }, eligibleForPerform: { _ in true }),
        .init(
            descriptor: .revealFiles,
            block: { package, host, _ in
                let path = JailbreakRoot.installedPath("/Library/dpkg/info/\(package.identity).list")
                guard FileManager.default.fileExists(atPath: path) else { return }
                host.present(next: PathListController(path: path))
            },
            eligibleForPerform: { package in
                FileManager
                    .default
                    .fileExists(atPath: JailbreakRoot.installedPath("/Library/dpkg/info/\(package.identity).list"))
            }
        ),
    ]
}
