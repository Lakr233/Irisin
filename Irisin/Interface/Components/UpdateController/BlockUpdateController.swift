//
//  BlockUpdateController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import SPIndicator
import UIKit

class BlockUpdateController: PackageCollectionController {
    override func viewDidLoad() {
        title = String(localized: "Blocked Updates")
        super.viewDidLoad()
        let clearItem = UIBarButtonItem(
            image: .fluent(.delete24Filled),
            style: .plain,
            target: self,
            action: #selector(clearBlock)
        )
        clearItem.accessibilityLabel = String(localized: "Clear")
        navigationItem.rightBarButtonItem = clearItem
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadBlockedItem()
    }

    @objc
    func clearBlock() {
        guard !PackageCenter.default.blockedUpdateTable.isEmpty else {
            SPIndicator.present(title: String(localized: "No blocked updates"), preset: .done)
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        presentConfirmation(
            title: "Clear Blocked Updates?",
            message: "This cannot be undone.",
            confirmTitle: "Clear",
            destructive: true
        ) { [self] in
            PackageCenter.default.blockedUpdateTable = []
            reloadBlockedItem()
            if let navigator = navigationController {
                navigator.popViewController(animated: true)
            } else {
                dismiss(animated: true, completion: nil)
            }
        }
    }

    func reloadBlockedItem() {
        var builder = [Package]()
        let blocker = PackageCenter
            .default
            .blockedUpdateTable
        for blockItem in blocker {
            let summary = PackageCenter
                .default
                .obtainPackageSummary(with: blockItem)
            if let candidate = PackageCenter
                .default
                .newestPackage(of: [Package](summary.values))
            {
                builder.append(candidate)
            } else if let installed = PackageCenter
                .default
                .obtainPackageInstallationInfo(with: blockItem)?
                .representObject
            {
                builder.append(installed)
            } else {
                builder.append(Package(
                    identity: blockItem,
                    payload: ["99.0": [
                        "package": blockItem,
                        "version": "99.0",
                        "description": String(localized: "This package is no longer available."),
                    ]]
                ))
            }
        }
        dataSource = builder.sorted(by: { a, b in
            PackageCenter.default.name(of: a)
                < PackageCenter.default.name(of: b)
        })
    }
}
