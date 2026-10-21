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

/// `PackageListRow` in a list cell, which is what slides aside for a swipe
/// in a list section. It draws no ground of its own, selected or not.
class PackageCollectionCell: UICollectionViewListCell {
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
        backgroundConfiguration = .clear()
        // the section has the page's inset already
        preservesSuperviewLayoutMargins = false
        directionalLayoutMargins = .zero
        contentView.preservesSuperviewLayoutMargins = false
        contentView.directionalLayoutMargins = .zero
        contentView.addSubview(originalCell)
        originalCell.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// The ground stays clear through every state: the page's own shows.
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = .clear()
    }

    /// A list section measures its rows; a row is as tall as
    /// `PackageListRow` at the text size in use, as a grid's are.
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        layoutAttributes.size.height = max(PackageListRow.rowHeight, PackageListRow.minimumSize.height)
        return layoutAttributes
    }
}
