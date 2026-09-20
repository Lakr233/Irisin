//
//  InstalledController+CollectionView.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension InstalledController {
    // MARK: - COLLECTION VIEW

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isEditing else {
            updateSelectionItems()
            return
        }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let data = diffableDataSource.itemIdentifier(for: indexPath) else { return }
        let target = PackageController(package: data)
        present(next: target)
    }

    func configureCell(
        _ collectionView: UICollectionView,
        at indexPath: IndexPath,
        for fetch: Package
    ) -> UICollectionViewCell {
        let cell = collectionView
            .dequeueReusableCell(withReuseIdentifier: cellId, for: indexPath) as! InstalledPackageCell
        cell.originalCell.loadValue(package: fetch)

        if identitiesWithUpdate.contains(fetch.identity) {
            cell.originalCell.overrideIndicator(with: .fluent(.arrowUpCircle24Filled), and: .updateAvailable)
        }

        // PackageCell holds its icon 4 in from the edge; here, as on the
        // dashboard, the icon starts at the inset
        cell.originalCell.horizontalPadding = -4
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        // a row being ticked stays where it is
        if !isEditing, let cell = collectionView.cellForItem(at: indexPath) {
            UIView.animate(
                withDuration: 0.5,
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 1,
                options: .curveEaseInOut,
                animations: {
                    cell.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
                }
            ) { _ in
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) {
            UIView.animate(
                withDuration: 0.5,
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 1,
                options: .curveEaseInOut,
                animations: {
                    cell.transform = .identity
                }
            ) { _ in
            }
        }
    }

    override func collectionView(
        _: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isEditing, let data = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return InterfaceBridge.packageContextMenuConfiguration(for: data, from: self)
    }

    override func collectionView(
        _: UICollectionView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        show(preview: animator)
    }

    // MARK: COLLECTION VIEW -
}

/// The one centered line a list ends with: the installed packages, the
/// repository page, the iPad sidebar's repositories and an operation that
/// is finishing.
final class FootnoteView: UICollectionReusableView {
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
