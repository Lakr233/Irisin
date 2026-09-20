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
        } else {
            cell.originalCell.clearOverrideIndicator()
        }

        // PackageListRow holds its icon 4 in from the edge; here, as on the
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
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isEditing, let data = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return PackageMenu.contextMenu(
            for: data,
            from: self,
            anchor: collectionView.cellForItem(at: indexPath)
        )
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
