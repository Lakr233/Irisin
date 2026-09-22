//
//  EmptyStateView.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

/// What a list shows in place of rows: a line of subtitle text, with an
/// icon above it when the screen has one. Fills whatever it is put in and
/// centres the content, so it serves as a collection view's `backgroundView`
/// as is.
final class EmptyStateView: UIView {
    private let icon = UIImageView()
    private let caption = UILabel()

    var text: String? {
        get { caption.text }
        set {
            caption.text = newValue
            accessibilityLabel = newValue
        }
    }

    init(icon image: FluentIcon? = nil, text: String? = nil) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        icon.image = image.map(UIImage.fluent)
        icon.isHidden = image == nil
        icon.tintColor = .textSubtitle
        icon.contentMode = .scaleAspectFit
        icon.snp.makeConstraints { $0.width.height.equalTo(48) }
        caption.font = .body
        caption.textColor = .textSubtitle
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.text = text
        // the line is the whole of it; the icon above says the same again
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = text
        let stack = UIStackView(arrangedSubviews: [icon, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.width.lessThanOrEqualToSuperview().inset(32)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
