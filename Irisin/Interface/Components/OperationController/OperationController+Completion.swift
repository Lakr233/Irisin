import AlertController
import UIKit

extension OperationController {
    /// The page's menu, at the leading edge for as long as the page lives.
    /// Built as it opens: the home screen work joins the log only once the
    /// operation has ended.
    func menuItem() -> UIBarButtonItem {
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuElements() ?? [])
                },
            ])
        )
        more.accessibilityLabel = String(localized: "More")
        return more
    }

    private func menuElements() -> [UIMenuElement] {
        let log = UIAction(title: String(localized: "View Full Log"), image: UIImage(systemName: "scroll")) { [weak self] _ in
            guard let self, let monitor else { return }
            navigationController?.pushViewController(OperationLogController(monitor: monitor), animated: true)
        }
        guard let monitor else { return [log] }
        if monitor.outcome?.succeeded == false, !isRecoveryMode {
            let ignore = UIAction(
                title: String(localized: "Ignore Configuration Errors"),
                image: UIImage(systemName: "exclamationmark.shield"),
                state: ignoresScriptFailures ? .on : .off
            ) { [weak self] _ in
                self?.toggleIgnoredScriptFailures()
            }
            return [log, UIMenu(options: .displayInline, children: [ignore])]
        }
        // home screen work follows an install that happened, not one that is running or did not
        guard monitor.outcome?.succeeded == true, !monitor.requiresExit else { return [log] }
        return [
            log,
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Rebuild Icons"),
                    image: UIImage(systemName: "square.grid.2x2")
                ) { [weak self] _ in self?.rebuildIcons() },
                UIAction(
                    title: String(localized: "Reload Home Screen"),
                    image: UIImage(systemName: "arrow.clockwise")
                ) { [weak self] _ in
                    self?.dismiss(animated: true) {
                        UIApplication.prepareForExitAndSuspend()
                        Task { await PrivilegedBackend.run(.respring) }
                    }
                },
            ]),
        ]
    }

    func finishOperation(succeeded: Bool, requiresExit: Bool) {
        // the status row says how it went; this button only says what it does
        let close = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                if requiresExit {
                    exitForUpgrade()
                } else {
                    dismiss(animated: true)
                }
            }
        )
        close.style = .done
        close.accessibilityLabel = String(localized: "Done")
        close.accessibilityValue = succeeded
            ? String(localized: "Operation completed.")
            : String(localized: "Operation failed. Try again.")
        navigationItem.rightBarButtonItems = [close]
    }

    private func rebuildIcons() {
        let progress = progressAlert(
            title: "Rebuilding Icons…",
            message: "Rebuilding home screen icons will take some time."
        )
        present(progress, animated: true) { [weak self] in
            Task { [weak self] in
                let outcome = await PrivilegedBackend.runMaintenance(.rebuildIconCache)
                progress.dismiss(animated: true) {
                    self?.report(outcome, succeeded: "Icons rebuilt", failed: "Unable to Rebuild Icons")
                }
            }
        }
    }

    private func exitForUpgrade() {
        let progress = progressAlert(
            title: "Updating App…",
            message: "Preparing the app update. The app will exit when it finishes."
        )
        present(progress, animated: true) {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                UIApplication.prepareForExitAndSuspend()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                exit(0)
            }
        }
    }
}
