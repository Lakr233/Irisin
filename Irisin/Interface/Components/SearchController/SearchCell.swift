//
//  SearchCell.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/13.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import SDWebImage
import Then
import UIKit

class SearchCell: UITableViewCell {
    let image = UIImageView().then {
        $0.image = UIImage.fluent(.bookNumber24Filled)
        $0.layer.cornerRadius = 8
        $0.tintColor = .buttonNormal
        $0.clipsToBounds = true
        $0.contentMode = .scaleAspectFit
    }

    let title = UILabel().then {
        $0.font = .bodyEmphasized
        $0.clipsToBounds = false
        $0.textColor = .textTitle
    }

    let subtitle = UILabel().then {
        $0.font = .footnote
        $0.lineBreakMode = .byTruncatingTail
        $0.textColor = .textSubtitle
    }

    let describe = UILabel().then {
        $0.font = .caption
        $0.lineBreakMode = .byTruncatingTail
        $0.textColor = .textSubtitle
    }

    var displayToken: UUID = .init()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .gray

        let text = UIStackView(arrangedSubviews: [title, subtitle, describe]).then {
            $0.axis = .vertical
            $0.spacing = 1
        }
        contentView.addSubview(image)
        contentView.addSubview(text)

        backgroundColor = .clear
        contentView.backgroundColor = .clear

        image.snp.makeConstraints { x in
            x.centerY.equalTo(contentView.snp.centerY)
            x.leading.equalTo(contentView.snp.leading).offset(12)
            x.height.equalTo(33)
            x.width.equalTo(33)
        }

        text.snp.makeConstraints { x in
            x.leading.equalTo(image.snp.trailing).offset(8)
            x.trailing.equalToSuperview().offset(-10)
            x.top.bottom.equalToSuperview().inset(6)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func prepareNewValue() -> UUID {
        image.image = nil
        title.text = ""
        title.textColor = .textTitle
        subtitle.text = ""
        describe.text = ""
        describe.attributedText = nil
        describe.textColor = .textSubtitle
        let token = UUID()
        displayToken = token
        return token
    }

    func makeEmptyHinter() {
        image.image = UIImage.fluent(.documentNone24Regular)
        title.text = String(localized: "No results found")
        subtitle.text = String(localized: "Try a different search or refresh your repositories.")
        describe.text = ""
    }

    func insertValue(with result: SearchResult, token: UUID) {
        switch result.associatedValue {
        // MARK: - AUTHOR

        case let .author(name):
            title.text = name
            subtitle.text = String(localized: "Packages by this author")
            image.image = UIImage.fluent(.peopleSearch24Regular)

        // MARK: - INSTALLED

        case let .installed(package):
            insertPackageValue(package, withToken: token)

        // MARK: - PACKAGE

        case let .package(identity, repository):
            guard let package = PackageCenter.default.obtainPackage(with: identity, in: repository) else {
                // the index still remembers a row the repository no longer has
                image.image = UIImage.fluent(.documentNone24Regular)
                title.text = identity
                subtitle.text = String(localized: "No longer available in this repository")
                return
            }
            insertPackageValue(package, withToken: token)

        // MARK: - REPO

        case let .repository(url):
            let repo = RepositoryCenter
                .default
                .obtainImmutableRepository(withUrl: url)
            title.text = repo?.nickName
            subtitle.text = url.absoluteString
            if let data = repo?.avatar, let img = UIImage(data: data) {
                image.image = img
            } else {
                image.image = UIImage.fluent(.bookCompass24Filled)
            }
        }

        // MARK: - SEARCH HIGHLIGHT

        let description = result
            .searchText
            .components(separatedBy: "\n")
            .filter { $0.contains(result.underKey) }
            .first
        describe.text = description
        describe.limitedLeadingHighlight(text: result.underKey, color: .buttonNormal)
    }

    private func insertPackageValue(_ package: Package, withToken token: UUID) {
        if package.latestMetadata?["tag"]?.contains("cydia::commercial") ?? false {
            title.textColor = .paidPackage
        }
        title.text = PackageCenter.default.name(of: package)
        let description = PackageCenter.default.description(of: package)
        if let repoUrl = package.repoRef,
           let repo = RepositoryCenter.default.obtainImmutableRepository(withUrl: repoUrl)
        {
            subtitle.text = "[\(repo.nickName)] \(description)"
        } else {
            subtitle.text = description
        }
        image.image = UIImage(named: "PackageDefaultIcon")
        if let iconUrl = PackageCenter.default.avatarUrl(with: package) {
            SDWebImageManager
                .shared
                .loadImage(
                    with: iconUrl,
                    options: .highPriority,
                    progress: nil
                ) { [weak self] img, _, _, _, _, _ in
                    if let img, self?.displayToken == token {
                        self?.image.image = img
                    }
                }
        }
    }
}
