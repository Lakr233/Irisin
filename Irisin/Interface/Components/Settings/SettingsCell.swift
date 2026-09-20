//
//  SettingsCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import GlyphixTextFx
import SnapKit
import Then
import UIKit

/// One row of Settings: what it shows and what it does. The closures read
/// and write the live value; the row itself carries no state.
struct SettingsItem {
    enum Kind {
        /// an arrow; tapping runs `action`, or opens `menu` when there is one
        case disclosure
        /// a value on the right; tapping the row opens `menu`
        case value
        /// a switch showing `isOn`; flipping it calls `setOn`
        case toggle
    }

    let id: String
    let icon: String
    let title: String
    let kind: Kind
    var value: (() -> String)?
    var isOn: (() -> Bool)?
    var setOn: ((Bool) -> Void)?
    var menu: (() -> [UIMenuElement])?
    var action: (() -> Void)?
}

/// The shape every row shares: an icon, a title, and a container on the
/// trailing edge that the subclass fills. Alignment lives here once.
class SettingsCell: UITableViewCell {
    let iconView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(.body)
    }

    let titleLabel = UILabel().then {
        $0.font = .body
        $0.textColor = .label
        // a title is never cut: it wraps and the row grows around it
        $0.numberOfLines = 0
    }

    let operationContainer = UIView()

    /// Covers the row for kinds that open a menu on tap.
    let menuButton = UIButton().then {
        $0.showsMenuAsPrimaryAction = true
        $0.isHidden = true
    }

    private(set) var item: SettingsItem?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(operationContainer)
        contentView.addSubview(menuButton)

        iconView.snp.makeConstraints { x in
            x.leading.equalTo(contentView.layoutMarginsGuide)
            x.centerY.equalToSuperview()
            x.size.equalTo(24)
        }
        operationContainer.setContentHuggingPriority(.required, for: .horizontal)
        operationContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        operationContainer.snp.makeConstraints { x in
            x.trailing.equalTo(contentView.layoutMarginsGuide)
            x.centerY.equalToSuperview()
            x.top.greaterThanOrEqualToSuperview().offset(12)
        }
        titleLabel.snp.makeConstraints { x in
            x.leading.equalTo(iconView.snp.trailing).offset(12)
            x.trailing.lessThanOrEqualTo(operationContainer.snp.leading).offset(-12)
            x.centerY.equalToSuperview()
            x.top.greaterThanOrEqualToSuperview().offset(16)
        }
        menuButton.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func configure(with item: SettingsItem) {
        self.item = item
        iconView.image = UIImage(systemName: item.icon)
        titleLabel.text = item.title
        if let menu = item.menu {
            menuButton.isHidden = false
            menuButton.menu = UIMenu(children: [
                UIDeferredMenuElement.uncached { completion in completion(menu()) },
            ])
        } else {
            menuButton.isHidden = true
            menuButton.menu = nil
        }
        refresh()
    }

    /// Reads the live value again. Called on configure and on `.SettingsDidChange`.
    func refresh() {}
}

/// A row that leads somewhere.
final class SettingsDisclosureCell: SettingsCell {
    private let arrow = UIImageView(image: .fluent(.arrowRightCircle24Filled)).then {
        $0.contentMode = .scaleAspectFit
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        operationContainer.addSubview(arrow)
        arrow.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.size.equalTo(20)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}

/// A row showing a value; the row opens the menu that changes it.
final class SettingsValueCell: SettingsCell {
    private let valueLabel = GlyphixTextLabel().then {
        $0.clipsToBounds = false
        $0.font = UIFont.rounded(.body, emphasized: true).monospacedDigitFont
        $0.textColor = .secondaryLabel
        $0.textAlignment = .trailing
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        operationContainer.addSubview(valueLabel)
        valueLabel.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.height.equalTo(TypeSize.body.metrics.scaledValue(for: 24))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func refresh() {
        valueLabel.text = item?.value?() ?? ""
    }
}

/// A row with a switch. The switch shows the stored value: a change the
/// item turns down is put back by the next refresh.
final class SettingsToggleCell: SettingsCell {
    private let toggle = UISwitch()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        operationContainer.addSubview(toggle)
        toggle.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        toggle.addTarget(self, action: #selector(flipped), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func refresh() {
        toggle.accessibilityLabel = item?.title
        toggle.setOn(item?.isOn?() ?? false, animated: window != nil)
    }

    @objc
    private func flipped() {
        item?.setOn?(toggle.isOn)
    }
}
