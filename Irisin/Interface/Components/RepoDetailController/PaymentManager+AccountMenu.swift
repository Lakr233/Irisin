//
//  PaymentManager+AccountMenu.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/25.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AlertController
import AptRepository
import Dog
import SPIndicator
import UIKit

extension PaymentManager {
    /// The vendor account of a repository as a menu: sign in while there is
    /// no account, sign out or list the purchases once there is one. Shared
    /// by the repository page and the Settings row.
    @MainActor
    func accountMenu(for repo: Repository, in controller: @escaping () -> UIViewController?) -> [UIMenuElement] {
        guard obtainStoredTokenInfomation(for: repo) != nil else {
            return [UIAction(
                title: String(localized: "Sign In"),
                image: UIImage(systemName: "person.crop.circle")
            ) { _ in
                let host = controller()
                PaymentManager.shared.startUserAuthenticate(
                    window: host?.view.window ?? UIWindow(),
                    controller: host,
                    repoUrl: repo.url
                ) {}
            }]
        }
        return [
            UIAction(title: String(localized: "Purchased"), image: UIImage(systemName: "bag")) { _ in
                guard let host = controller() else { return }
                let alert = progressAlert(
                    title: "Loading Purchases…",
                    message: "Checking with the vendor…"
                )
                host.present(alert, animated: true, completion: nil)
                Task {
                    // the request times out on its own; nothing waits forever
                    guard let account = await PaymentManager.shared.obtainUserAccountInfo(for: repo.url) else {
                        // jsonReply said why; this says the user saw nothing at all.
                        Dog.shared.join(
                            "Payment",
                            "no account info from \(repo.url.absoluteString), purchases cannot be listed",
                            level: .error
                        )
                        alert.dismiss(animated: true) {
                            host.presentNotice(
                                title: "Unable to Load Purchases",
                                message: "The vendor did not answer. Try again."
                            )
                        }
                        return
                    }
                    Dog.shared.join(
                        "Payment",
                        "\(repo.url.absoluteString) lists \(account.item.count) purchase(s)",
                        level: .info
                    )
                    let purchased = account.item.compactMap {
                        PackageCenter.default.obtainPackage(with: $0, in: repo.url)
                    }
                    let target = PackageCollectionController()
                    target.dataSource = purchased.sorted(by: { a, b in
                        PackageCenter.default.name(of: a) < PackageCenter.default.name(of: b)
                    })
                    target.title = String(localized: "Purchased")
                    alert.dismiss(animated: true) {
                        host.present(next: target)
                    }
                }
            },
            UIAction(
                title: String(localized: "Sign Out"),
                image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                attributes: .destructive
            ) { _ in
                PaymentManager.shared.deleteSignInRecord(for: repo.url)
                SPIndicator.present(
                    title: String(localized: "Signed out"),
                    message: nil,
                    preset: .done,
                    from: .top,
                    completion: nil
                )
            },
        ]
    }
}
