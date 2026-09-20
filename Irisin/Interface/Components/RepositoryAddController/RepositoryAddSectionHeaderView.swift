//
//  RepositoryAddSectionHeaderView.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/20.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import SnapKit
import Then
import UIKit

/// The header over a section of offered sources: the list's own header
/// text, and Add All at the trailing edge while a row under it still
/// offers Add.
final class RepositoryAddSectionHeaderView: UITableViewHeaderFooterView {
    /// What the list's own header is drawn with: a label of ours wears it,
    /// so the button has a baseline to sit on.
    private static let style = UIListContentConfiguration.groupedHeader()

    private let label = UILabel().then {
        let properties = RepositoryAddSectionHeaderView.style.textProperties
        $0.font = properties.font
        $0.textColor = properties.resolvedColor()
        $0.adjustsFontForContentSizeCategory = true
        $0.numberOfLines = 0
    }

    private let button = UIButton().then {
        // text alone, ending where the rows' own buttons end
        var configuration = UIButton.Configuration.plain()
        configuration.buttonSize = .small
        configuration.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 0)
        configuration.baseForegroundColor = .buttonNormal
        configuration.title = String(localized: "Add All")
        $0.configuration = configuration
    }

    var onAddAll: (() -> Void)?

    /// Off once every source under the header is registered.
    var showsButton = true {
        didSet { button.isHidden = !showsButton }
    }

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)

        contentView.addSubview(label)
        contentView.addSubview(button)

        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let margins = Self.style.directionalLayoutMargins
        label.snp.makeConstraints { x in
            x.leading.equalTo(contentView.layoutMarginsGuide)
            x.top.equalToSuperview().inset(margins.top)
            x.bottom.equalToSuperview().inset(margins.bottom)
            x.trailing.lessThanOrEqualTo(button.snp.leading)
        }
        button.snp.makeConstraints { x in
            x.trailing.equalTo(contentView.layoutMarginsGuide)
            x.firstBaseline.equalTo(label)
        }
        button.addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func configure(title: String, showsButton: Bool) {
        label.text = switch Self.style.textProperties.transform {
        case .uppercase: title.localizedUppercase
        case .lowercase: title.localizedLowercase
        case .capitalized: title.localizedCapitalized
        default: title
        }
        self.showsButton = showsButton
    }

    @objc
    private func tapped() {
        onAddAll?()
    }
}
