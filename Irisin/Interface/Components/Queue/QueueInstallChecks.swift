//
//  QueueInstallChecks.swift
//  Irisin
//

// preconcurrency: the configuration is a plain static var upstream, only
// ever touched on the main actor here
@preconcurrency import AlertController
import AptRepository
import AptResolver
import Foundation
import IrisinProtocol
import UIKit

/// The last checks before the queue runs, for a system with no dpkg: a
/// device set up without a bootstrap, as the vphone can be. What the queue
/// installs there may need a shell that is not there yet, so the user
/// chooses Bootstrap Install, which places every file before any script
/// runs, or goes on and is told first which packages run scripts.
enum QueueInstallChecks {
    enum DpkgAnswer {
        case bootstrapInstall, installAnyway, cancel
    }

    /// Whether dpkg is among the packages the plan was solved against. The
    /// helper never needs dpkg itself; its record says a bootstrap is there.
    static func hasDpkg(_ plan: ResolutionPlan) -> Bool {
        plan.snapshot.installed.contains { $0.identity == "dpkg" }
    }

    private nonisolated static let scriptMembers: Set<String> = ["preinst", "postinst", "prerm", "postrm"]

    /// The names of the packages whose maintainer scripts the plan would
    /// run: a new file's own, and the installed version's for what it
    /// upgrades, removes or configures. Irisin's own postinst, prerm and
    /// postrm are left out, since the helper that ships with this app
    /// forgives their failure (`SelfPackage`). A file that is not on disk
    /// is not read: staging stops on it anyway.
    static func packagesRunningScripts(in plan: ResolutionPlan) async -> [String] {
        var files: [(identity: String, file: URL)] = []
        for package in plan.install {
            var file = package.fileOnDisk
            if file == nil {
                file = await Downloads.shared.downloadedFile(for: package)
            }
            if let file {
                files.append((package.identity, file))
            }
        }
        let configuring = plan.stages.flatMap { stage -> [String] in
            if case let .configure(names) = stage {
                return names
            }
            return []
        }
        let touched = Set(plan.install.map(\.identity) + plan.remove.map(\.identity) + configuring)
        let identities = await scriptedIdentities(files: files, touched: touched.sorted())
        let packages = plan.install + plan.remove
        return identities.map { identity in
            packages.first { $0.identity == identity }.map { PackageCenter.default.name(of: $0) } ?? identity
        }
    }

    @concurrent
    private nonisolated static func scriptedIdentities(
        files: [(identity: String, file: URL)],
        touched: [String]
    ) async -> [String] {
        let info = JailbreakRoot.installedPath("/Library/dpkg/info")
        var scripted = Set(touched.filter { identity in
            scriptMembers.contains { FileManager.default.fileExists(atPath: "\(info)/\(identity).\($0)") }
        })
        for (identity, file) in files {
            guard let members = try? ArchiveStream.debianControlMembers(atPath: file.path) else { continue }
            if !members.isDisjoint(with: scriptMembers) {
                scripted.insert(identity)
            }
            // a preinst of Irisin's own still stops it, and is counted
            if !members.contains("preinst"), shipsHelper(identity: identity, file: file) {
                scripted.remove(identity)
            }
        }
        return scripted.sorted()
    }

    /// The helper's own test for Irisin's package: it places the helper.
    /// Only a package named like Irisin has its listing read, since that
    /// means decoding the whole payload.
    private nonisolated static func shipsHelper(identity: String, file: URL) -> Bool {
        guard identity.hasPrefix(InstallerJob.selfIdentityPrefix),
              let contents = try? ArchiveStream.debianContents(atPath: file.path)
        else { return false }
        // spelled under the bootstrap's prefix on rootless, bare on roothide
        return contents.files.contains { $0 == IrisinWire.helperPath || $0.hasSuffix(IrisinWire.helperPath) }
    }
}

extension QueueController {
    /// Bootstrap Install (when the plan allows it), Install Anyway or
    /// Cancel. Returns once the alert is gone, so what comes next can be
    /// presented.
    func askWithoutDpkg(offersBootstrap: Bool) async -> QueueInstallChecks.DpkgAnswer {
        // a second tap while the first alert is up, or a page on its way
        // out: nothing would come up, and nothing would ever answer
        guard presentedViewController == nil, view.window != nil else { return .cancel }
        var message = String(localized: "dpkg is not installed on this system, so the tools the packages' scripts need may be missing.")
        if offersBootstrap {
            message += "\n\n" + String(localized: "Bootstrap Install places every package's files before any script runs.")
        }
        return await withCheckedContinuation { continuation in
            let alert = AlertViewController(
                title: String.LocalizationValue(String(localized: "dpkg Is Not Installed")),
                message: String.LocalizationValue(message)
            ) { context in
                if offersBootstrap {
                    context.addAction(title: "Bootstrap Install", attribute: .accent) {
                        context.dispose { continuation.resume(returning: .bootstrapInstall) }
                    }
                }
                context.addAction(title: "Install Anyway") {
                    context.dispose { continuation.resume(returning: .installAnyway) }
                }
                context.addAction(title: "Cancel") {
                    context.dispose { continuation.resume(returning: .cancel) }
                }
            }
            present(alert, animated: true)
        }
    }

    /// The packages that run scripts, before a queue with no dpkg under it
    /// goes on. `onConfirm` runs on Install Anyway.
    func warnAboutScripts(_ names: [String], onConfirm: @escaping () -> Void) {
        let list = ListFormatter.localizedString(byJoining: names)
        presentConfirmation(
            title: "Installation Likely to Fail",
            message: String.LocalizationValue(
                String(localized: "These packages run scripts that this system may not be able to run: \(list). The installation is likely to fail.")
            ),
            confirmTitle: "Install Anyway",
            destructive: true,
            onConfirm: onConfirm
        )
    }
}
