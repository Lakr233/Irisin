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
        if let data = repo?.avatar,
           let image = UIImage(data: data)
        {
            icon.image = image
        } else {
            icon.image = UIImage.fluent(.bookCompass24Filled)
        }
        guard let ready = RepositoryCenter.default.isRepositoryReadyForUse(withUrl: withUrl) else {
            indicator.backgroundColor = .clear
            return
        }
        if RepositoryCenter.default.isRepositoryPreparedForUpdate(withUrl: withUrl) {
            indicator.backgroundColor = .repositoryPending
        } else {
            indicator.backgroundColor = ready ? .repositoryReady : .repositoryFailed
        }
    }

    func setNoRepoAvailable() {
        repoUrl = nil
        indicator.backgroundColor = .clear
        arrow.isHidden = true
        title.text = String(localized: "No repositories")
        subtitle.text = String(localized: "Use the add button above to add a repository.")
        icon.image = UIImage.fluent(.bookCompass24Filled)
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
