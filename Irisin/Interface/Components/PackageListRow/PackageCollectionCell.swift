//
//  PackageCollectionCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/18.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import SDWebImage
import UIKit

class PackageCollectionCell: UICollectionViewCell {
    let originalCell = PackageListRow()

    var horizontalPadding: CGFloat {
        get {
            originalCell.horizontalPadding
        }
        set {
            originalCell.horizontalPadding = newValue
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        originalCell.prepareForReuse()
    }

    func loadValue(package: Package) {
        originalCell.loadValue(package: package)
    }

    func overrideIndicator(with icon: UIImage, and color: UIColor) {
        originalCell.overrideIndicator(with: icon, and: color)
    }

    override init(frame _: CGRect) {
        super.init(frame: CGRect())
        contentView.addSubview(originalCell)
        originalCell.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
