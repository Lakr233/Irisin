//
//  ListFootnoteView.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import SnapKit
import Then
import UIKit

/// The one centered line a list ends with: the installed packages, the
/// repository page, the iPad sidebar's repositories and an operation that
/// is finishing. A list may put an underlined link under it, as the
/// operation page puts Try Again under its rows.
final class ListFootnoteView: UICollectionReusableView {
    static let height: CGFloat = 52

    let label = UILabel().then {
        $0.font = .footnote
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }

    /// The second line, hidden while `linkTitle` is nil.
    private let link = UIButton(type: .system).then {
        $0.titleLabel?.numberOfLines = 0
        $0.titleLabel?.textAlignment = .center
        $0.isHidden = true
    }

    /// What the link says; nil takes the line away.
    var linkTitle: String? {
        didSet {
            guard linkTitle != oldValue else { return }
            link.isHidden = linkTitle == nil
            link.setAttributedTitle(linkTitle.map {
                NSAttributedString(string: $0, attributes: [
                    .font: UIFont.footnote,
                    .foregroundColor: UIColor.buttonNormal,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ])
            }, for: .normal)
        }
    }

    /// What a tap on the link does.
    var linkAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [label, link])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20))
        }
        link.addAction(UIAction { [weak self] _ in self?.linkAction?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
