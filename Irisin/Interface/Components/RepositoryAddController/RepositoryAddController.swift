//
//  RepositoryAddController.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/19.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import SnapKit
import SPIndicator
import Then
import UIKit

/// The add-repository sheet. Add in the bar registers the source in the
/// field. The clipboard, read on request, and History offer sources, each
/// with its own Add that registers it on the spot, after which the bar
/// offers Done in Add's place until the field is typed in again. A source is a bare
/// address or a sources.list line (`deb URL suite components`); the last
/// row hands over to the advanced sheet for typing the latter piecewise.
class RepositoryAddController: UITableViewController {
    /// Where a section of offered sources came from. The sheet reads the
    /// clipboard itself; a link and a file hand their sources over already
    /// parsed.
    nonisolated enum Origin: Hashable {
        case clipboard
        case link
        case file
    }

    nonisolated enum Section: Hashable {
        case pending
        case paste
        case candidates(Origin)
        case history
        case advanced
    }

    nonisolated enum Row: Hashable {
        case input
        case readClipboard
        case candidate(Section, String)
        case advanced
    }

    private let initialInput: String?
    private var inputText = ""
    /// The typed source being looked up, shown under the field.
    private var probing: String?
    private var probeTask: Task<Void, Never>?
    private var added: Set<String> = []
    /// The repositories already registered when the sheet opened, plus what it
    /// registered since. Asking the center sorts its whole list, and every row
    /// asks.
    private lazy var registered: Set<URL> = Set(RepositoryCenter.default.obtainRepositoryUrls())
    private var candidates: [String] = []
    private var candidateOrigin: Origin = .clipboard
    private var history: [String] = []
    private var previews: [String: RepositoryAddCandidateCell.Preview] = [:]
    /// A row's own Add has registered a source since the field was last
    /// typed in: the bar offers Done, not Add.
    private var offersDone = false

    private lazy var addButton = UIBarButtonItem(
        title: String(localized: "Add"),
        style: .done,
        target: self,
        action: #selector(confirm)
    )

    /// In Add's place once a row has registered its source.
    private lazy var doneButton = UIBarButtonItem(
        barButtonSystemItem: .done,
        target: self,
        action: #selector(close)
    )

    /// Beside Add: a repository list or a repository this app exported.
    private lazy var importButton = UIBarButtonItem(
        title: String(localized: "Import"),
        style: .plain,
        target: self,
        action: #selector(openImport)
    )

    private lazy var dataSource = EditableTableDiffableDataSource<Section, Row>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, row in
        switch row {
        case .input:
            let cell = tableView.dequeueReusableCell(withIdentifier: "input", for: indexPath) as! RepositoryAddInputCell
            cell.field.text = inputText
            cell.onChange = { [weak self] text in self?.inputChanged(text) }
            cell.onReturn = { [weak self] in self?.confirm() }
            return cell
        case .readClipboard, .advanced:
            let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = row == .advanced
                ? String(localized: "Add Advanced Source")
                : String(localized: "Read from Clipboard")
            content.textProperties.color = .buttonNormal
            cell.contentConfiguration = content
            return cell
        case let .candidate(section, line):
            let cell = tableView
                .dequeueReusableCell(withIdentifier: "candidate", for: indexPath) as! RepositoryAddCandidateCell
            cell.configure(line: line, preview: preview(for: line), added: isRegistered(line))
            cell.showsButton = section != .pending
            cell.onAdd = { [weak self] in self?.add(line) }
            return cell
        }
    }

    /// The sheet the callers present: Cancel and Add over the list, half
    /// height on the iPhone until the list needs more.
    static func sheet(initialInput: String? = nil) -> UINavigationController {
        .halfSheet(root: RepositoryAddController(initialInput: initialInput))
    }

    /// The same sheet with sources already found for the user to pick from,
    /// in place of the row that reads the clipboard.
    static func sheet(candidates: [RepositorySource], origin: Origin) -> UINavigationController {
        .halfSheet(root: RepositoryAddController(candidates: candidates.map(\.line), origin: origin))
    }

    init(initialInput: String? = nil, candidates: [String] = [], origin: Origin = .clipboard) {
        self.initialInput = initialInput
        self.candidates = candidates
        candidateOrigin = origin
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(localized: "Add Repository")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(close)
        )
        // nothing typed yet: Add waits for a probed source
        updateAddButton()

        tableView.register(RepositoryAddInputCell.self, forCellReuseIdentifier: "input")
        tableView.register(RepositoryAddCandidateCell.self, forCellReuseIdentifier: "candidate")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        tableView.keyboardDismissMode = .onDrag
        tableView.dataSource = dataSource
        tableView.register(RepositoryAddSectionHeaderView.self, forHeaderFooterViewReuseIdentifier: "candidates")
        // the offered sources have a header view of their own, and a title
        // given here as well would be drawn over it
        dataSource.headerTitle = { section in
            if case .candidates = section { return nil }
            return Self.headerTitle(of: section)
        }
        dataSource.footerTitle = { section in
            switch section {
            case .pending: String(localized: "A repository can include apps, plugins, themes, and ringtones. Anyone can host one, and we cannot verify that its packages are safe.")
            case .paste, .candidates: nil
            case .history: String(localized: "You added these repositories before. Swipe one to forget it.")
            case .advanced: String(localized: "For repositories that need a suite and components.")
            }
        }

        loadHistory()
        applySnapshot(animatingDifferences: false)
        inputChanged(initialInput ?? "")
    }

    private static func headerTitle(of section: Section) -> String? {
        switch section {
        case .pending: String(localized: "Repository URL")
        case .paste, .candidates(.clipboard): String(localized: "Clipboard")
        case .candidates(.link): String(localized: "From Link")
        case .candidates(.file): String(localized: "From File")
        case .history: String(localized: "History")
        case .advanced: nil
        }
    }

    // MARK: - CANDIDATES

    private func loadHistory() {
        history = RepositoryCenter.default.historyRecords
            .filter { RepositorySource(line: $0) != nil && !isRegistered($0) }
            .sorted()
        if !history.isEmpty {
            Dog.shared.join(self, "found \(history.count) importable repositories in history")
        }
    }

    /// Registered already, or registered from this sheet: the row shows a
    /// checkmark and offers nothing.
    private func isRegistered(_ line: String) -> Bool {
        guard let source = RepositorySource(line: line) else { return false }
        return added.contains(line) || registered.contains(source.url)
    }

    private var sections: [Section] {
        [.pending]
            + (candidates.isEmpty ? [.paste] : [.candidates(candidateOrigin)])
            + (history.isEmpty ? [] : [.history])
            + [.advanced]
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .pending: [.input] + (probing.map { [.candidate(.pending, $0)] } ?? [])
        case .paste: [.readClipboard]
        case .candidates: candidates.map { .candidate(section, $0) }
        case .history: history.map { .candidate(.history, $0) }
        case .advanced: [.advanced]
        }
    }

    private func applySnapshot(animatingDifferences: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        for section in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(rows(in: section), toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    /// Every row showing `line`, in whichever sections it appears.
    private func reconfigure(_ line: String) {
        var snapshot = dataSource.snapshot()
        let rows = [Section.pending, .candidates(candidateOrigin), .history]
            .map { Row.candidate($0, line) }
            .filter { snapshot.indexOfItem($0) != nil }
        guard !rows.isEmpty else { return }
        snapshot.reconfigureItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - PREVIEW

    /// Kicks off the Release fetch the first time a source is shown. A
    /// source that does not answer is said so, and can still be added.
    private func preview(for line: String) -> RepositoryAddCandidateCell.Preview {
        if let known = previews[line] {
            return known
        }
        previews[line] = .loading
        Task { [weak self] in
            var info: RepositoryPreview?
            if let source = RepositorySource(line: line) {
                info = await RepositoryCenter.default.preview(of: source)
            }
            guard let self else { return }
            previews[line] = info.map { .loaded($0) } ?? .failed
            reconfigure(line)
            updateAddButton()
        }
        return .loading
    }

    // MARK: - CANDIDATE ACTIONS

    /// A row's own Add registers the source on the spot; the row keeps a
    /// checkmark for the rest of the sheet's life.
    private func add(_ line: String) {
        guard let source = RepositorySource(line: line), !isRegistered(line) else { return }
        Dog.shared.join("Repository", "user added \(source.line)", level: .info)
        RepositoryCenter.default.registerRepository(source)
        added.insert(line)
        registered.insert(source.url)
        reconfigure(line)
        updateCandidatesHeader()
        offersDone = true
        updateAddButton()
    }

    /// Add All, in the header over the offered sources: every one of them
    /// not registered yet.
    private func addAll() {
        for line in candidates {
            add(line)
        }
    }

    private var offersAddAll: Bool {
        candidates.contains { !isRegistered($0) }
    }

    /// Add All leaves with the last source it could add.
    private func updateCandidatesHeader() {
        guard let index = dataSource.snapshot().indexOfSection(.candidates(candidateOrigin)),
              let header = tableView.headerView(forSection: index) as? RepositoryAddSectionHeaderView
        else { return }
        header.showsButton = offersAddAll
    }

    /// Whatever the clipboard holds becomes a section to pick from, and the
    /// row that read it goes away.
    private func paste() {
        let found = Self.sources(in: UIPasteboard.general.string ?? "")
        guard !found.isEmpty else {
            presentNotice(
                title: "No Repositories Found",
                message: "The clipboard has no repository address."
            )
            return
        }
        candidates = found.map(\.line)
        candidateOrigin = .clipboard
        applySnapshot(animatingDifferences: true)
        SPIndicator.present(title: String(localized: "Repositories found: \(found.count)"), preset: .done)
    }

    // MARK: - IMPORT

    /// Only our own files: a repository list, or one repository whole.
    @objc
    private func openImport() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.irisinRepositoryList, .irisinRepository],
            asCopy: true
        )
        picker.delegate = self
        present(picker, animated: true)
    }

    /// The file's addresses become a section to pick from, as the
    /// clipboard's do: an import takes the addresses and nothing else.
    private func importSources(from file: URL) {
        guard let data = try? Data(contentsOf: file),
              let sources = try? RepositoryListFile.sources(in: data)
        else {
            presentNotice(title: "Unable to Import", message: "This file could not be read. Choose another file.")
            return
        }
        let fresh = sources.map(\.line).filter { !isRegistered($0) }
        guard !fresh.isEmpty else {
            presentNotice(
                title: "Nothing to Import",
                message: "This file has no new repositories to add."
            )
            return
        }
        candidates = fresh
        candidateOrigin = .file
        applySnapshot(animatingDifferences: true)
        SPIndicator.present(title: String(localized: "Repositories found: \(fresh.count)"), preset: .done)
    }

    // MARK: - INPUT

    /// A `deb` line is one source; any other line is addresses separated by
    /// whitespace.
    static func sources(in text: String) -> [RepositorySource] {
        text
            .components(separatedBy: .newlines)
            .flatMap { line -> [RepositorySource] in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("deb ") {
                    return RepositorySource(line: trimmed).map { [$0] } ?? []
                }
                return trimmed
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { RepositorySource(line: String($0)) }
            }
            .uniqued()
    }

    /// The typed source once its probe has come back, answered or not; Add
    /// waits for it so a half-typed host is not registered.
    private var readySource: RepositorySource? {
        guard let probing, let preview = previews[probing] else { return nil }
        switch preview {
        case .loading: return nil
        case .loaded, .failed: return RepositorySource(line: probing)
        }
    }

    private func updateAddButton() {
        addButton.isEnabled = readySource != nil
        let trailing = offersDone ? doneButton : addButton
        guard navigationItem.rightBarButtonItems?.first !== trailing else { return }
        navigationItem.rightBarButtonItems = [trailing, importButton]
    }

    /// Typing pauses for a moment before the source is looked up, so a
    /// half-typed host is not fetched.
    private func inputChanged(_ text: String) {
        // typing in the field brings Add back
        if text != inputText, offersDone {
            offersDone = false
            updateAddButton()
        }
        inputText = text
        probeTask?.cancel()
        let target = Self.sources(in: text).first?.line
        guard target != probing else { return }
        // a host that did not answer is asked again, not remembered
        if let target, case .failed = previews[target] {
            previews[target] = nil
        }
        // the field no longer says what was probed: Add must not register it
        probing = nil
        updateAddButton()
        applySnapshot(animatingDifferences: true)
        guard target != nil else { return }
        probeTask = Task { [weak self] in
            try? await Task.sleep(seconds: 0.6)
            guard !Task.isCancelled, let self else { return }
            probing = target
            applySnapshot(animatingDifferences: true)
            updateAddButton()
        }
    }

    // MARK: - ACTIONS

    /// Registers the source under the field.
    @objc
    private func confirm() {
        guard let source = readySource else { return }
        if let probing, isRegistered(probing) {
            presentNotice(title: "Already Added", message: "This repository is already in the list.")
            return
        }
        if let probing, case .failed = previews[probing] {
            presentConfirmation(
                title: "Add Unreachable Repository?",
                message: "This address did not respond. You can add the repository anyway and refresh it later.",
                confirmTitle: "Add"
            ) { [weak self] in
                self?.register(source)
            }
            return
        }
        register(source)
    }

    private func register(_ source: RepositorySource) {
        Dog.shared.join("Repository", "user added \(source.line)", level: .info)
        RepositoryCenter.default.registerRepository(source)
        dismiss(animated: true)
    }

    /// Cancel, and Done once a row has registered its source.
    @objc
    private func close() {
        dismiss(animated: true)
    }

    /// This sheet goes away and the advanced one takes its place on the
    /// same presenter.
    private func openAdvanced() {
        guard let presenter = presentingViewController else { return }
        dismiss(animated: true) {
            presenter.present(RepositoryAddAdvancedController.sheet(), animated: true)
        }
    }

    private func forget(_ line: String) {
        var records = RepositoryCenter.default.historyRecords
        records.remove(line)
        RepositoryCenter.default.historyRecords = records
        history.removeAll { $0 == line }
        applySnapshot(animatingDifferences: true)
    }

    // MARK: - TABLE VIEW

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .readClipboard: paste()
        case .advanced: openAdvanced()
        default: break
        }
    }

    /// The offered sources get a header with Add All; every other section
    /// keeps the data source's title.
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let identifier = dataSource.sectionIdentifier(for: section),
              case .candidates = identifier,
              let header = tableView
              .dequeueReusableHeaderFooterView(withIdentifier: "candidates") as? RepositoryAddSectionHeaderView
        else { return nil }
        header.configure(title: Self.headerTitle(of: identifier) ?? "", showsButton: offersAddAll)
        header.onAddAll = { [weak self] in self?.addAll() }
        return header
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .candidate(.history, line) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let forget = UIContextualAction(
            style: .destructive,
            title: String(localized: "Forget")
        ) { [weak self] _, _, completion in
            self?.forget(line)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [forget])
    }
}

/// A text field row: the URL field here, and the suite and component
/// fields on the advanced sheet.
final class RepositoryAddInputCell: UITableViewCell {
    let field = UITextField().then {
        $0.placeholder = "https://"
        $0.keyboardType = .URL
        $0.autocapitalizationType = .none
        $0.autocorrectionType = .no
        $0.spellCheckingType = .no
        $0.clearButtonMode = .whileEditing
        $0.returnKeyType = .done
        $0.font = .monospaced(.callout, emphasized: true)
        $0.textColor = .buttonNormal
    }

    /// An empty field starts with the scheme so only the host is typed.
    /// Off for a field that is not an address.
    var fillsScheme = true

    var onChange: ((String) -> Void)?
    var onReturn: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(field)
        field.snp.makeConstraints { x in
            x.leading.trailing.equalTo(contentView.layoutMarginsGuide)
            x.top.bottom.equalToSuperview()
            x.height.greaterThanOrEqualTo(44)
        }
        field.addTarget(self, action: #selector(began), for: .editingDidBegin)
        field.addTarget(self, action: #selector(changed), for: .editingChanged)
        field.addTarget(self, action: #selector(returned), for: .editingDidEndOnExit)
    }

    @objc
    private func began() {
        guard fillsScheme, (field.text ?? "").isEmpty else { return }
        field.text = "https://"
        changed()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    @objc
    private func changed() {
        onChange?(field.text ?? "")
    }

    @objc
    private func returned() {
        onReturn?()
    }
}

extension RepositoryAddController: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let file = urls.first else { return }
        importSources(from: file)
    }
}
