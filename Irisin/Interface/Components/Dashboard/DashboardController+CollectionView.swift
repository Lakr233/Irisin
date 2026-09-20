//
//  DashboardController+CollectionView.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

private let kCellLineLimit = 6

extension DashboardController {
    // MARK: - CELL SIZE

    /// Before the collection view lays out, never after it: a size that
    /// arrives a turn late leaves a frame of `PackageListRow.minimumSize` cells.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if collectionView.frame.size == collectionViewFrameCache,
           traitCollection.preferredContentSizeCategory == collectionViewTextSizeCache
        {
            return
        }
        collectionViewFrameCache = collectionView.frame.size
        collectionViewTextSizeCache = traitCollection.preferredContentSizeCategory
        updateCellSize()
    }

    func updateCellSize() {
        let inset = collectionView.contentInset.left + collectionView.contentInset.right
        let layout = PackageListRow.layout(inWidth: view.frame.width - inset)
        collectionViewCellSizeCache = layout.size
        collectionView.collectionViewLayout.invalidateLayout()

        let limit = layout.itemsPerRow * kCellLineLimit
        guard limit != cellLimit else { return }
        cellLimit = limit
        // the row limit follows the width: re-cut every section, no motion,
        // and in this pass: off a window the detail column has no sidebar
        // beside it, so the width that counts arrives with the first frame
        guard !dataSource.isEmpty else { return }
        applySnapshot(animatingDifferences: false)
    }

    // MARK: - DELEGATE

    func collectionView(
        _: UICollectionView,
        layout _: UICollectionViewLayout,
        referenceSizeForHeaderInSection _: Int
    ) -> CGSize {
        CGSize(width: 300, height: 60)
    }

    /// The footnote hangs off the last section only.
    func collectionView(
        _: UICollectionView,
        layout _: UICollectionViewLayout,
        referenceSizeForFooterInSection section: Int
    ) -> CGSize {
        guard section == diffableDataSource.snapshot().numberOfSections - 1 else { return .zero }
        return CGSize(width: 300, height: DashboardFooterView.height)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch diffableDataSource.itemIdentifier(for: indexPath) {
        case let .package(_, data):
            let target = PackageController(package: data)
            present(next: target)
        case nil:
            return
        }
    }

    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt _: IndexPath) -> CGSize {
        collectionViewCellSizeCache
    }

    override func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) {
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
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              case let .package(_, data) = diffableDataSource.itemIdentifier(for: indexPath)
        else {
            return nil
        }
        return PackageMenu.contextMenu(
            for: data,
            from: self,
            anchor: collectionView.cellForItem(at: indexPath)
        )
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration _: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        packagePreview(in: collectionView, at: indexPath)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration _: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        packagePreview(in: collectionView, at: indexPath)
    }

    /// A dashboard cell draws its icon at its own edge, so the preview gives
    /// back the 4pt a package row keeps on either side.
    private func packagePreview(in collectionView: UICollectionView, at indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(
            roundedRect: cell.bounds.insetBy(dx: -4, dy: 0),
            cornerRadius: 8
        )
        return UITargetedPreview(view: cell, parameters: parameters)
    }

    override func collectionView(
        _: UICollectionView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        show(preview: animator)
    }
}
