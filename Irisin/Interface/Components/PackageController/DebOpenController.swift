//
//  DebOpenController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/27.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import UIKit

/// Takes a `.deb` handed to the app, keeps a copy of its own, reads the
/// control file in-process and opens the package page for it.
class DebOpenController: UIViewController {
    var patternLocation: URL?
    /// The file is still the user's, in their Files app: copied, not taken.
    var openedInPlace = false

    let indicator = UIActivityIndicatorView()
    let text = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground
        view.addSubview(indicator)
        indicator.snp.makeConstraints { x in
            x.centerX.equalToSuperview()
            x.centerY.equalToSuperview().offset(-10)
        }
        indicator.startAnimating()
        text.textColor = .textMuted
        text.font = .monospacedDigit(.caption, emphasized: true)
        view.addSubview(text)
        text.snp.makeConstraints { x in
            x.centerX.equalToSuperview()
            x.centerY.equalToSuperview().offset(10)
        }
        text.text = String(localized: "Unpacking Package…")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        defer {
            text.text = ""
            indicator.stopAnimating()
        }

        guard let url = patternLocation else {
            failedAndExit()
            return
        }

        let package: Package
        do {
            package = try Package(debianPackageAt: keep(url))
        } catch {
            Dog.shared.join(self, "can not read \(url.path): \(error)", level: .error)
            failedAndExit(
                with: String(localized: "This package could not be verified. Choose a different file and try again.")
            )
            return
        }

        let target = PackageController(package: package)
        if let navigator = navigationController {
            // swap this controller for the package: no pop animation to wait on
            var stack = navigator.viewControllers
            stack.removeAll { $0 === self }
            // the sheet's Close belongs to whoever is at the root
            target.navigationItem.leftBarButtonItem = navigationItem.leftBarButtonItem
            stack.append(target)
            navigator.setViewControllers(stack, animated: true)
        } else {
            let presenter = presentingViewController
            target.modalTransitionStyle = .coverVertical
            target.modalPresentationStyle = .formSheet
            // the sheet itself, with no navigator around it
            target.preferredContentSize = preferredPopOverSize
            dismiss(animated: true) {
                presenter?.present(target, animated: true, completion: nil)
            }
        }
    }

    /// Puts the file in a directory of its own under the direct-install
    /// cache, where the package keeps pointing for this session. The next
    /// launch clears it before accepting imports.
    ///
    /// An inbox copy is ours to take and is moved. A file opened in place is
    /// the user's, still listed in their Files app: it is copied under a
    /// security scope, because moving it would take it out of their folder.
    private func keep(_ url: URL) throws -> URL {
        let directory = documentsDirectory
            .appendingPathComponent("DirectInstallCache")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = directory.appendingPathComponent(url.lastPathComponent)
        guard openedInPlace else {
            try FileManager.default.moveItem(at: url, to: kept)
            return kept
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        try FileManager.default.copyItem(at: url, to: kept)
        return kept
    }

    func failedAndExit(with reason: String? = nil) {
        func callDismiss() {
            if let navigator = navigationController {
                navigator.popViewController(animated: true)
            } else {
                dismiss(animated: true, completion: nil)
            }
        }
        Dog.shared.join(self, "failed with reason: \(reason ?? "unknown")", level: .error)
        if let reason {
            presentNotice(title: "Unable to Open Package", message: reason) {
                callDismiss()
            }
        } else {
            callDismiss()
        }
    }
}
