//
//  RepositoryRow.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/20.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import SnapKit
import Then
import UIKit

class RepositoryRow: UIView {
    private var subscriptions = Set<AnyCancellable>()

    var title = UILabel().then {
        $0.font = .bodyEmphasized
        $0.clipsToBounds = false
        $0.textColor = .textTitle
    }

    let subtitle = UILabel().then {
        $0.font = .footnote
        $0.lineBreakMode = .byTruncatingTail
        $0.textColor = .textSubtitle
    }

    var icon = UIImageView().then {
        $0.image = UIImage(named: "RepositoryTableCell.Missing")
        $0.layer.cornerRadius = 8
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFit
    }

    let arrow = UIImageView(image: UIImage(named: "RepositoryTableCell.Right")).then {
        $0.contentMode = .scaleAspectFit
    }

    let indicator = UIView().then {
        $0.backgroundColor = .clear
        $0.layer.cornerRadius = 4
        $0.clipsToBounds = true
    }

    var repoUrl: URL?

    let contentView = UIView()

    init() {
        super.init(frame: CGRect())

        addSubview(contentView)
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        let text = UIStackView(arrangedSubviews: [title, subtitle]).then {
            $0.axis = .vertical
            $0.spacing = 2
        }
        contentView.addSubview(icon)
        contentView.addSubview(text)
        contentView.addSubview(arrow)
        contentView.addSubview(indicator)

        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // Tall enough for the icon or the two lines, whichever needs more.
        icon.snp.remakeConstraints { x in
            x.centerY.equalTo(contentView.snp.centerY)
            x.top.greaterThanOrEqualToSuperview().offset(8)
            x.leading.equalTo(contentView.snp.leading).offset(4)
            x.height.equalTo(33)
            x.width.equalTo(33)
        }

        indicator.snp.makeConstraints { x in
            x.centerX.equalTo(icon.snp.right).offset(-2)
            x.centerY.equalTo(icon.snp.bottom).offset(-2)
            x.height.equalTo(8)
            x.width.equalTo(8)
        }

        text.snp.makeConstraints { x in
            x.centerY.equalTo(contentView.snp.centerY)
            x.top.greaterThanOrEqualToSuperview().offset(6)
            x.leading.equalTo(icon.snp.trailing).offset(8)
            x.trailing.equalTo(arrow.snp.leading).offset(-10)
        }

        arrow.snp.makeConstraints { x in
            x.centerY.equalTo(contentView.snp.centerY)
            x.trailing.equalTo(contentView.snp.trailing).offset(-4)
            x.height.equalTo(16)
            x.width.equalTo(16)
        }

        NotificationCenter.default.publisher(for: RepositoryCenter.metadataUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in self?.updateRepoMetadata(withNotification: notification) }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .RepositoryQueueChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIndicator() }
            .store(in: &subscriptions)
    }

    func updateRepoMetadata(withNotification: Notification) {
        guard let updateOn = withNotification.object as? RepositoryCenter.UpdateNotification,
              let url = repoUrl, url == updateOn.repository
        else { return }
        setRepository(withUrl: url)
    }

    func updateIndicator() {
        if let url = repoUrl {
            setRepository(withUrl: url)
        }
    }

    /// Draws the repository at `withUrl` as the center holds it now. What a
    /// row says lives there and not in the address, so this draws every
    /// field every time, and nothing wipes the row first: a redraw in place
    /// goes from one full picture to the next.
    func setRepository(withUrl: URL) {
        arrow.isHidden = false
        repoUrl = withUrl
        let repo = RepositoryCenter.default.obtainImmutableRepository(withUrl: withUrl)
        title.text = repo?.nickName ?? ""
        subtitle.text = repo.map(Self.summary(of:)) ?? ""
        // one stop per repository, opened as a button; the arrow is drawn,
        // not read, and the dot is read as words
        let health = RepositoryCenter.default.refreshHealth(withUrl: withUrl)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = describe(health)
        showAvatar(repo?.avatar ?? Data(), of: withUrl)
        indicator.backgroundColor = switch health {
        case .pending: .repositoryPending
        case .ready: .repositoryReady
        case .degraded: .repositoryDegraded
        case .failed: .repositoryFailed
        case nil: .clear
        }
    }

    /// The repository whose avatar `icon` shows, nil for the stand-in.
    private var iconUrl: URL?
    private var iconTask: Task<Void, Never>?

    /// A row redrawn for its own repository keeps its picture while a new
    /// avatar is made; one reused for another shows the stand-in until then.
    private func showAvatar(_ data: Data, of url: URL) {
        iconTask?.cancel()
        iconTask = nil
        if let icon = data.isEmpty ? .some(nil) : RepositoryAvatar.cached(for: url, data: data) {
            setIcon(icon, of: url)
            return
        }
        if iconUrl != url {
            setIcon(nil, of: nil)
        }
        iconTask = Task { [weak self] in
            let icon = await RepositoryAvatar.icon(for: url, data: data)
            guard !Task.isCancelled, let self, repoUrl == url else { return }
            setIcon(icon, of: url)
        }
    }

    private func setIcon(_ image: UIImage?, of url: URL?) {
        let image = image ?? UIImage.fluent(.bookCompass24Filled)
        iconUrl = url
        // the same picture handed back is not a new one to commit
        if icon.image !== image {
            icon.image = image
        }
    }

    func setNoRepoAvailable() {
        repoUrl = nil
        indicator.backgroundColor = .clear
        arrow.isHidden = true
        title.text = String(localized: "No repositories")
        subtitle.text = String(localized: "Use the add button above to add a repository.")
        iconTask?.cancel()
        iconTask = nil
        setIcon(nil, of: nil)
        // the hint opens nothing: read as one line, not as a button
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = describe()
    }

    /// The row's two lines as one label, the way a cell reads elsewhere,
    /// and what the dot says when it says something is wrong.
    private func describe(_ health: RepositoryHealth? = nil) -> String {
        let state: String? = switch health {
        case .degraded: String(localized: "Partly available")
        case .failed: String(localized: "Unavailable")
        case .pending, .ready, nil: nil
        }
        return ([title.text, subtitle.text, state] as [String?])
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// What the repository says about itself; its address without the
    /// scheme until it has said anything.
    nonisolated static func summary(of repo: Repository) -> String {
        if let description = repo.repositoryDescription, !description.isEmpty {
            return description
        }
        var address = (repo.url.host ?? "") + repo.url.path
        while address.hasSuffix("/") {
            address.removeLast()
        }
        return address
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
