//
//  SidebarCard.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/19.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import GlyphixTextFx
import UIKit

class SidebarCard: UIView {
    var cardClosure: (() -> Void)?

    private var icon = UIImageView()
    private var title = UILabel()
    private var button = UIButton()

    var badgeText: String? {
        set {
            badgeLabel.text = newValue
        }
        get {
            badgeLabel.text
        }
    }

    private var badgeLabel = GlyphixTextLabel()

    private let selectTitleColor: UIColor = .onAccent
    private let unselectTitleColor: UIColor = .textMuted
    private let selectBackgroundColor: UIColor = .buttonNormal
    private let unselectBackgroundColor: UIColor = .cardBackground

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// `symbol` is an SF Symbol name; it is drawn white on the selected card
    /// and in the card's color otherwise.
    required init(
        text: String,
        symbol: String,
        defaultSelected: Bool = false
    ) {
        super.init(frame: CGRect())

        addSubview(icon)
        addSubview(title)
        addSubview(button)
        addSubview(badgeLabel)

        layer.cornerRadius = 12
        icon.contentMode = .scaleAspectFit
        icon.image = UIImage(systemName: symbol)
        icon.preferredSymbolConfiguration = .init(.icon, emphasized: true)

        if defaultSelected {
            select()
        } else {
            deselect()
        }

        title.text = text
        title.font = .headline
        title.textAlignment = .left

        badgeLabel.textAlignment = .trailing
        badgeLabel.font = UIFont.rounded(.caption, emphasized: true).monospacedDigitFont

        title.snp.makeConstraints { x in
            x.left.equalTo(self.snp.left).offset(16)
            x.height.equalTo(28)
            x.right.lessThanOrEqualTo(badgeLabel.snp.left).offset(-4)
            x.bottom.equalTo(self.snp.bottom).offset(-8)
        }
        badgeLabel.isUserInteractionEnabled = false // the whole card is the button
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeLabel.snp.makeConstraints { x in
            x.right.equalTo(self.snp.right).offset(-10)
            x.width.lessThanOrEqualTo(60)
            x.centerY.equalTo(title.snp.centerY).offset(2)
        }

        icon.snp.makeConstraints { x in
            x.left.equalTo(self.snp.left).offset(18)
            x.bottom.equalTo(title.snp.top).offset(-10)
            x.width.equalTo(28)
            x.height.equalTo(28)
        }
        button.snp.makeConstraints { x in
            x.edges.equalTo(self.snp.edges)
        }

        button.addTarget(self, action: #selector(touched), for: .touchUpInside)
    }

    @objc
    func touched() {
        Task {
            cardClosure?()
        }
    }

    func select() {
        icon.tintColor = .onAccent
        title.textColor = selectTitleColor
        badgeLabel.textColor = title.textColor
        backgroundColor = selectBackgroundColor
    }

    func deselect() {
        icon.tintColor = selectBackgroundColor
        title.textColor = unselectTitleColor
        badgeLabel.textColor = title.textColor
        backgroundColor = unselectBackgroundColor
    }
}
