//
//  InterfaceBridge.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import UIKit

enum InterfaceBridge {
    // MARK: - Engine calls

    /// Re-reads dpkg's status file; the parse runs off the main actor and this
    /// returns once the new list is in place.
    static func reloadLocalPackages() async {
        await PackageCenter.default.reloadLocalPackages()
    }

    /// Drops a repository and everything cached for it.
    static func deleteRepository(_ url: URL) {
        // first: the sign-in record is found through the repository, which
        // must still be registered
        PaymentManager.shared.deleteSignInRecord(for: url)
        Dog.shared.join("Repository", "user removed \(url.absoluteString)", level: .info)
        RepositoryCenter.default.deleteRepository(withUrl: url)
    }
}
