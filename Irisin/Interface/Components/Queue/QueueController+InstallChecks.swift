//
//  QueueController+InstallChecks.swift
//  Irisin
//

import AlertController
import UIKit

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
