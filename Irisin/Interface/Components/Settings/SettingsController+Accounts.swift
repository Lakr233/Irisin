//
//  SettingsController+Accounts.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/28.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import SnapKit
import UIKit

extension SettingsController {
    /// Every repository with a vendor to sign in to, by name.
    static func paidRepositories() -> [Repository] {
        RepositoryCenter.default.repositories.values
            .filter { $0.endpoint != nil }
            .sorted { $0.nickName.lowercased() < $1.nickName.lowercased() }
    }
}

/// A repository's vendor account as one row: the repository's icon and name,
/// an arrow while there is no account (tapping signs in), a check once there
/// is one (tapping opens the purchases and sign-out menu).
final class SettingsAccountCell: SettingsCell {
    private let indicator = UIImageView().then {
        $0.contentMode = .scaleAspectFit
    }

    private(set) var repo: Repository?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        iconView.layer.cornerRadius = 4
        iconView.clipsToBounds = true
        operationContainer.addSubview(indicator)
        indicator.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.size.equalTo(20)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func configure(repo: Repository) {
        self.repo = repo
        iconView.image = UIImage(data: repo.avatar) ?? UIImage(named: "RepositoryTableCell.Missing")
        titleLabel.text = repo.nickName
        // the row's own configure never runs here: the button covering a
        // signed-in row takes its name from the repository
        menuButton.accessibilityLabel = repo.nickName
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(VendorAccount.shared.accountMenu(for: repo) { self?.parentViewController })
            },
        ])
        refresh()
    }

    override func refresh() {
        guard let repo else { return }
        let signedIn = VendorAccount.shared.storedToken(for: repo) != nil
        menuButton.isHidden = !signedIn
        indicator.image = signedIn ? .fluent(.checkmarkCircle24Filled) : .fluent(.arrowRightCircle24Filled)
        indicator.tintColor = signedIn ? .signedIn : nil
    }
}
