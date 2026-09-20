//
//  RepositoriesController+Table.swift
//  Irisin
//

import AptRepository
import UIKit

extension RepositoriesController: UITableViewDelegate {
    func url(at indexPath: IndexPath) -> URL? {
        guard case let .repository(url) = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return url
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshControl.listDidScroll(scrollView)
    }

    func tableView(_: UITableView, shouldBeginMultipleSelectionInteractionAt _: IndexPath) -> Bool {
        true
    }

    func tableView(_: UITableView, didBeginMultipleSelectionInteractionAt _: IndexPath) {
        setEditing(true, animated: true)
    }

    func tableView(_: UITableView, didDeselectRowAt _: IndexPath) {
        updateSelectionItems()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateSelectionItems()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        guard let value = url(at: indexPath),
              let repo = RepositoryCenter
              .default
              .obtainImmutableRepository(withUrl: value)
        else {
            return
        }
        present(next: RepositoryDetailController(withRepo: repo))
    }

    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt index: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let url = url(at: index) else { return nil }
        let deleteItem = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete")
        ) { [weak self] _, _, completion in
            self?.delete([url])
            // the swipe's own transaction has to end for the row to slide out
            completion(true)
        }
        deleteItem.backgroundColor = .swipeDelete
        let reloadItem = UIContextualAction(
            style: .normal,
            title: String(localized: "Refresh")
        ) { [weak self] _, _, completion in
            self?.refreshRepository(url)
            completion(true)
        }
        reloadItem.backgroundColor = .swipeRefresh
        return UISwipeActionsConfiguration(actions: [reloadItem, deleteItem])
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt index: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let url = url(at: index) else { return nil }
        let copyItem = UIContextualAction(
            style: .normal,
            title: String(localized: "Share")
        ) { [weak self] _, _, completion in
            completion(true)
            self?.share(url, from: tableView.cellForRow(at: index))
        }
        copyItem.backgroundColor = .swipeShare
        return UISwipeActionsConfiguration(actions: [copyItem])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !tableView.isEditing, let url = url(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIMenu(options: .displayInline, children: [
                    UIAction(
                        title: String(localized: "Refresh"),
                        image: UIImage(systemName: "arrow.clockwise")
                    ) { _ in self?.refreshRepository(url) },
                    UIAction(
                        title: String(localized: "Share"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { _ in self?.share(url, from: tableView.cellForRow(at: indexPath)) },
                    ExportFile.exportRepositoryAction(
                        url,
                        host: { self },
                        anchor: { tableView.cellForRow(at: indexPath).map { PopoverAnchor($0) } }
                    ),
                ]),
                UIAction(
                    title: String(localized: "Delete"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in self?.delete([url]) },
            ])
        }
    }
}
