//
//  InstalledPackageCell.swift
//  Irisin
//

import AptRepository
import SnapKit
import UIKit

/// A row of the Installed page: `PackageCell` in a list cell, which is what
/// slides aside for a swipe and shows the selection mark while the list is
/// being edited. It draws no ground of its own, selected or not.
final class InstalledPackageCell: UICollectionViewListCell {
    let originalCell = PackageCell()

    /// A row is as tall as `PackageCell` at the text size in use. Measured
    /// once per text size: a list section asks every row for its height.
    private static var heights: [UIContentSizeCategory: CGFloat] = [:]

    static func rowHeight(for traits: UITraitCollection) -> CGFloat {
        let category = traits.preferredContentSizeCategory
        if let known = heights[category] {
            return known
        }
        let height = max(PackageCell.rowHeight, InterfaceBridge.minimumPackageCellSize.height)
        heights[category] = height
        return height
    }

    override init(frame _: CGRect) {
        super.init(frame: CGRect())
        backgroundConfiguration = .clear()
        accessories = [.multiselect(displayed: .whenEditing)]
        contentView.addSubview(originalCell)
        originalCell.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        originalCell.prepareForReuse()
    }

    /// The ground stays clear through every state: the page's own shows.
    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        backgroundConfiguration = .clear()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        layoutAttributes.size.height = Self.rowHeight(for: traitCollection)
        return layoutAttributes
    }
}
