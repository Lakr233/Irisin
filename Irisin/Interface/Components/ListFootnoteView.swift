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
/// is finishing.
final class ListFootnoteView: UICollectionReusableView {
    static let height: CGFloat = 52

    let label = UILabel().then {
        $0.font = .footnote
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        label.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
