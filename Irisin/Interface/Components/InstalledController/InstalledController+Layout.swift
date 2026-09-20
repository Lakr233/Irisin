//
//  InstalledController+Layout.swift
//  Irisin
//

import AptRepository
import UIKit

extension InstalledController {
    /// The dashboard's edge: icons and date headers start 20 in.
    static let horizontalInset: CGFloat = 20
    /// The gap between two rows, the flow layout's own before this one.
    static let rowSpacing: CGFloat = 10

    /// One column is a list, whose rows swipe; a width that fits more is
    /// the grid every package page lays out, where a long press has the
    /// same actions. The count is the layout's own footer, after the last
    /// section whichever that is.
    func makeLayout() -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(FootnoteView.height)
                ),
                elementKind: UICollectionView.elementKindSectionFooter,
                alignment: .bottom
            ),
        ]
        return UICollectionViewCompositionalLayout(
            sectionProvider: { [weak self] _, environment in
                self?.makeSection(in: environment)
            },
            configuration: configuration
        )
    }

    private func makeSection(in environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width - Self.horizontalInset * 2
        let (cellSize, itemsPerRow) = InterfaceBridge.calculatesPackageCellSize(availableWidth: width)
        let rowHeight = InstalledPackageCell.rowHeight(for: environment.traitCollection)

        let section: NSCollectionLayoutSection
        if itemsPerRow < 2 {
            var list = UICollectionLayoutListConfiguration(appearance: .plain)
            list.showsSeparators = false
            list.backgroundColor = .clear
            list.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            section = .list(using: list, layoutEnvironment: environment)
        } else {
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(cellSize.width),
                heightDimension: .fractionalHeight(1)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(rowHeight)
                ),
                subitems: [item]
            )
            // what is left of the width goes between the columns
            group.interItemSpacing = .flexible(0)
            section = NSCollectionLayoutSection(group: group)
        }
        section.interGroupSpacing = Self.rowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Self.horizontalInset,
            bottom: 0,
            trailing: Self.horizontalInset
        )
        if sortOption == .lastModification {
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(20)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            if itemsPerRow < 2 {
                // a list section leaves its header at the edge, a grid insets it
                header.contentInsets = section.contentInsets
            }
            section.boundarySupplementaryItems = [header]
        }
        return section
    }

    // MARK: - SWIPE

    /// Remove, and Update or Reinstall when a repository has the version:
    /// the package menu's own actions, run as the menu runs them. A queued
    /// package leaves the queue instead, as its page would have it.
    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isEditing, let row = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        let (package, actions) = PackageMenuAction.swipeActions(forInstalled: row)
        guard !actions.isEmpty else { return nil }
        return UISwipeActionsConfiguration(actions: actions.map { action in
            let removes = action.descriptor == .remove || action.descriptor == .dequeue
            let item = UIContextualAction(
                style: .normal,
                title: action.descriptor.describe()
            ) { [weak self] _, _, completion in
                completion(true)
                guard let self else { return }
                Task { await action.block(package, self) }
            }
            item.backgroundColor = removes ? .swipeDelete : .swipeRefresh
            return item
        })
    }
}
