//
//  LogViewerController+Menu.swift
//  Irisin
//

import Dog
import UIKit

extension LogViewerController {
    func setupNavigationItems() {
        let menuButton = UIButton(type: .system)
        menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        menuButton.tintColor = .textTitle
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.createMenu().children ?? [])
            },
        ])
        menuButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: menuButton)
    }

    private func createMenu() -> UIMenu {
        let levelActions = [Dog.DogLevel.verbose, .info, .warning, .error, .critical].map { level in
            UIAction(
                title: level.rawValue,
                image: selectedLevels.contains(level) ? UIImage(systemName: "checkmark") : nil,
                handler: { [weak self] _ in
                    self?.toggleLevel(level)
                }
            )
        }
        let levelMenu = UIMenu(
            title: String(localized: "Filter by Level"),
            image: UIImage(systemName: "slider.horizontal.3"),
            children: levelActions
        )

        var categoryActions: [UIAction] = []
        let categories = allCategories
        if !categories.isEmpty {
            categoryActions.append(UIAction(
                title: String(localized: "All Categories"),
                image: selectedCategories.isEmpty ? UIImage(systemName: "checkmark") : nil,
                handler: { [weak self] _ in
                    self?.selectedCategories.removeAll()
                    self?.applyFilters(stickToBottom: false)
                }
            ))
            categoryActions.append(contentsOf: categories.sorted().map { category in
                UIAction(
                    title: category,
                    image: selectedCategories.contains(category) ? UIImage(systemName: "checkmark") : nil,
                    handler: { [weak self] _ in
                        self?.toggleCategory(category)
                    }
                )
            })
        }
        let emptyCategories = [UIAction(title: String(localized: "No Categories"), handler: { _ in })]
        let categoryMenu = UIMenu(
            title: String(localized: "Filter by Category"),
            image: UIImage(systemName: "tag"),
            children: categoryActions.isEmpty ? emptyCategories : categoryActions
        )

        let onlyFailuresAction = UIAction(
            title: String(localized: "Errors Only"),
            image: UIImage(systemName: "exclamationmark.triangle"),
            state: selectedLevels == [.error, .critical] ? .on : .off,
            handler: { [weak self] _ in
                guard let self else { return }
                selectedLevels = selectedLevels == [.error, .critical]
                    ? [.verbose, .info, .warning, .error, .critical]
                    : [.error, .critical]
                applyFilters(stickToBottom: false)
            }
        )

        let shareAction = UIAction(
            title: String(localized: "Share"),
            image: UIImage(systemName: "square.and.arrow.up"),
            handler: { [weak self] _ in
                self?.shareLog()
            }
        )

        let clearAction = UIAction(
            title: String(localized: "Clear"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive,
            handler: { [weak self] _ in
                self?.clearLog()
            }
        )

        return UIMenu(children: [
            levelMenu,
            categoryMenu,
            UIMenu(options: .displayInline, children: [onlyFailuresAction]),
            UIMenu(options: .displayInline, children: [shareAction, clearAction]),
        ])
    }

    private func toggleLevel(_ level: Dog.DogLevel) {
        if selectedLevels.contains(level) {
            selectedLevels.remove(level)
        } else {
            selectedLevels.insert(level)
        }
        applyFilters(stickToBottom: false)
    }

    private func toggleCategory(_ category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
        applyFilters(stickToBottom: false)
    }

    /// Shares the log as a file. A support report is a `.log` attachment, not
    /// half a megabyte pasted into a message field.
    @objc private func shareLog() {
        let name = "irisin-\(Int(Date().timeIntervalSince1970)).log"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let items: [Any] = if (try? logText().write(to: file, atomically: true, encoding: .utf8)) != nil {
            [file]
        } else {
            [logText()]
        }
        // the bar button is a custom view, and that view is the anchor
        ShareSheet.present(
            items,
            anchor: navigationItem.rightBarButtonItem?.customView.map { PopoverAnchor($0) },
            from: self
        )
    }

    @objc private func clearLog() {
        hiddenPrefixCount = Dog.shared.obtainCurrentLogContent().count
        reload()
    }

    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let logLine = dataSource.itemIdentifier(for: indexPath)?.line else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyAction = UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = logLine.fullText
            }

            let copyMessageAction = UIAction(
                title: String(localized: "Copy Message"),
                image: UIImage(systemName: "text.quote")
            ) { _ in
                UIPasteboard.general.string = logLine.message
            }

            return UIMenu(children: [copyAction, copyMessageAction])
        }
    }
}
