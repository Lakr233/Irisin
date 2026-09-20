//
//  RepositoryAddAdvancedController.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/8.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import UIKit

/// A sources.list line typed piecewise: the address, the suite, and the
/// components. Nothing is fetched; Add lights up as soon as the three make a
/// well-formed source, and registering it starts the first update.
final class RepositoryAddAdvancedController: UITableViewController {
    nonisolated enum Section: Hashable {
        case url, suite, components
    }

    private var url = ""
    private var suite = ""
    private var components = ""

    private lazy var addButton = UIBarButtonItem(
        title: String(localized: "Add"),
        style: .done,
        target: self,
        action: #selector(confirm)
    )

    private lazy var dataSource = EditableTableDiffableDataSource<Section, Section>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, section in
        let cell = tableView.dequeueReusableCell(withIdentifier: "input", for: indexPath) as! RepositoryAddInputCell
        cell.fillsScheme = section == .url
        cell.field.keyboardType = section == .url ? .URL : .asciiCapable
        cell.field.returnKeyType = section == .components ? .done : .next
        switch section {
        case .url:
            cell.field.placeholder = "https://"
            cell.field.text = url
            cell.onChange = { [weak self] in self?.url = $0; self?.updateAddButton() }
        case .suite:
            cell.field.placeholder = "stable"
            cell.field.text = suite
            cell.onChange = { [weak self] in self?.suite = $0; self?.updateAddButton() }
        case .components:
            cell.field.placeholder = "main"
            cell.field.text = components
            cell.onChange = { [weak self] in self?.components = $0; self?.updateAddButton() }
        }
        cell.onReturn = { [weak self] in self?.confirm() }
        return cell
    }

    static func sheet() -> UINavigationController {
        .halfSheet(root: RepositoryAddAdvancedController(style: .insetGrouped))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(localized: "Advanced Source")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = addButton
        addButton.isEnabled = false

        tableView.register(RepositoryAddInputCell.self, forCellReuseIdentifier: "input")
        tableView.keyboardDismissMode = .onDrag
        tableView.dataSource = dataSource
        dataSource.headerTitle = { section in
            switch section {
            case .url: String(localized: "URL")
            case .suite: String(localized: "Suite")
            case .components: String(localized: "Components")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .url: nil
            case .suite:
                String(localized: "The distribution under dists/, or a path ending in / for a flat repository.")
            case .components: String(localized: "Separated by spaces. Leave empty for a flat repository.")
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Section>()
        for section in [Section.url, .suite, .components] {
            snapshot.appendSections([section])
            snapshot.appendItems([section], toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private var source: RepositorySource? {
        guard let url = RepositorySource.url(from: url) else { return nil }
        let suite = suite.trimmingCharacters(in: .whitespaces)
        let source = RepositorySource(
            url: url,
            distribution: suite.isEmpty ? nil : suite,
            components: components.split(whereSeparator: \.isWhitespace).map(String.init)
        )
        return source.isValid ? source : nil
    }

    private func updateAddButton() {
        addButton.isEnabled = source != nil
    }

    @objc
    private func confirm() {
        guard let source else { return }
        Dog.shared.join("Repository", "user added \(source.line)", level: .info)
        RepositoryCenter.default.registerRepository(source)
        dismiss(animated: true)
    }

    @objc
    private func cancel() {
        dismiss(animated: true)
    }
}
