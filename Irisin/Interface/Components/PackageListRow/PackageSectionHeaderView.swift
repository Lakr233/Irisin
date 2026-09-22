//
//  PackageSectionHeaderView.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/18.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import SnapKit
import UIKit

class PackageSectionHeaderView: UICollectionReusableView {
    let label = UILabel()
    var horizontalPadding: CGFloat = 10 {
        didSet {
            updateSnapKitConstraints()
        }
    }

    override init(frame _: CGRect) {
        super.init(frame: CGRect())
        label.font = .rounded(.caption, emphasized: true)
        label.textColor = .textMuted
        label.accessibilityTraits = .header
        addSubview(label)
        updateSnapKitConstraints()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func loadText(_ str: String) {
        label.text = str
    }

    func updateSnapKitConstraints() {
        label.snp.remakeConstraints { x in
            x.leading.equalToSuperview().offset(horizontalPadding)
            x.trailing.equalToSuperview().offset(-horizontalPadding)
            x.centerY.equalToSuperview()
        }
    }
}
