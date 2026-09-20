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
                    heightDimension: .absolute(ListFootnoteView.height)
                ),
                elementKind: UICollectionView.elementKindSectionFooter,
                alignment: .bottom
            ),
        ]
        return UICollectionViewCompositionalLayout(
            sectionProvider: { [weak self] index, environment in
                self?.makeSection(at: index, in: environment)
            },
            configuration: configuration
        )
    }

    private func makeSection(
        at index: Int,
        in environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width - Self.horizontalInset * 2
        let (cellSize, itemsPerRow) = PackageListRow.layout(inWidth: width)
        let rowHeight = InstalledPackageCell.rowHeight

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
            // the next date stands off these rows as far as they stand off
            // each other; after the last of them comes the footer
            bottom: showsHeaders && index < dataSource.count - 1
                ? Self.rowSpacing : 0,
            trailing: Self.horizontalInset
        )
        if showsHeaders {
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(20)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            // list and grid alike: the date is measured from the page's edge
            // and starts where the rows do, whatever either kind of section
            // would make of its own insets
            section.supplementaryContentInsetsReference = .none
            header.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: Self.horizontalInset,
                bottom: 0,
                trailing: Self.horizontalInset
            )
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
        let (package, actions) = PackageMenu.swipeActions(forInstalled: row)
        guard !actions.isEmpty else { return nil }
        let configuration = UISwipeActionsConfiguration(actions: actions.map { action in
            let removes = action.descriptor == .remove || action.descriptor == .dequeue
            let item = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
                completion(true)
                guard let self else { return }
                // the row, for an action that ends in a popover
                let anchor = collectionView.cellForItem(at: indexPath).map { PopoverAnchor($0) }
                Task { await action.block(package, self, anchor) }
            }
            // the menu's own symbol and name, as the sidebar's rows swipe
            item.image = action.descriptor.icon()
            item.accessibilityLabel = action.descriptor.describe()
            item.backgroundColor = removes ? .swipeDelete : .swipeRefresh
            return item
        })
        // a request is never made by a swipe that went too far
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    // MARK: - TEXT SIZE

    /// A row is as tall as its text: a new text size is a new layout, for
    /// the grid too, whose rows are a number the layout was given.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }
}
