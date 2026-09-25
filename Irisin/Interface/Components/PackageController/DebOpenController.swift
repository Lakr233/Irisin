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
        // an alert over this page brings it back here once it is dismissed
        guard opening == nil else { return }

        guard let url = patternLocation else {
            failedAndExit()
            return
        }
        opening = Task {
            await open(url)
            text.text = ""
            indicator.stopAnimating()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // left before the file arrived: the download stops with the page
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            opening?.cancel()
        }
    }

    private var opening: Task<Void, Never>?

    private func open(_ url: URL) async {
        let kept: URL
        do {
            kept = try await Self.keep(url, inPlace: openedInPlace)
        } catch {
            guard !Task.isCancelled else { return }
            Dog.shared.join(self, "can not copy \(url.path): \(error)", level: .error)
            failedAndExit(with: String(localized: "This file could not be read. Choose another file."))
            return
        }

        let package: Package
        do {
            package = try await Self.read(kept)
        } catch {
            Dog.shared.join(self, "can not read \(kept.path): \(error)", level: .error)
            failedAndExit(
                with: String(localized: "This package could not be verified. Choose a different file and try again.")
            )
            return
        }
        guard !Task.isCancelled else { return }

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
    /// the user's, still listed in their Files app: it is copied through a
    /// coordinated read, because moving it would take it out of their folder.
    ///
    /// Off the main actor: a file in iCloud Drive may have to download first.
    @concurrent
    private static func keep(_ url: URL, inPlace: Bool) async throws -> URL {
        let directory = documentsDirectory
            .appendingPathComponent("DirectInstallCache")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = directory.appendingPathComponent(url.lastPathComponent)
        do {
            if inPlace {
                try await url.readingCoordinated { readable in
                    try FileManager.default.copyItem(at: readable, to: kept)
                }
            } else {
                try FileManager.default.moveItem(at: url, to: kept)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return kept
    }

    /// The control file and the digest of the whole archive, off the main
    /// actor: a large package takes a moment to hash.
    @concurrent
    private static func read(_ kept: URL) async throws -> Package {
        try Package(debianPackageAt: kept)
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
