//
//  FeaturedBanner.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import UIKit

/// One entry of a repository's `sileo-featured.json`: a picture, a title,
/// and the package it opens.
final class FeaturedBanner: UIView {
    let button = UIButton()
    let name = UILabel()
    let artwork = PackageArtworkView()
    let package: Package

    /// The banner entries of a repository's featured json; none when it
    /// cannot be read.
    nonisolated static func entries(in repo: Repository) -> [[String: Any]] {
        guard let featured = repo.attachment[.featured],
              let data = featured.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments),
              let decoded = json as? [String: Any],
              decoded["class"] as? String == "FeaturedBannersView",
              let banners = decoded["banners"] as? [[String: Any]]
        else {
            return []
        }
        return banners
    }

    /// The package a banner entry points at, when the repository has it.
    static func package(for banner: [String: Any], inside repo: Repository) -> Package? {
        guard let identity = banner["package"] as? String else { return nil }
        return PackageCenter.default.obtainPackage(with: identity.lowercased(), in: repo.url)
    }

    init?(banner: [String: Any], inside repo: Repository) {
        guard let url = URL(string: banner["url"] as? String ?? ""),
              let title = banner["title"] as? String,
              let read = Self.package(for: banner, inside: repo)
        else {
            Dog.shared.join("FeaturedBanner", "broken metadata found when loading banner item")
            return nil
        }

        package = read

        super.init(frame: CGRect())

        addSubview(artwork)
        addSubview(name)
        addSubview(button)
        button.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        name.text = title
        name.font = .captionEmphasized
        name.alpha = 0.5
        name.textAlignment = .center
        name.snp.makeConstraints { x in
            x.leading.equalToSuperview()
            x.trailing.equalToSuperview()
            x.bottom.equalToSuperview()
            x.height.equalTo(30)
        }

        artwork.layer.cornerRadius = 8
        artwork.write(nameOf: package)
        artwork.load(url)
        artwork.snp.makeConstraints { x in
            x.leading.equalToSuperview()
            x.trailing.equalToSuperview()
            x.bottom.equalTo(name.snp.top).offset(4)
            x.top.equalToSuperview()
        }

        button.addTarget(self, action: #selector(openPackage), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    @objc
    func openPackage() {
        let target = PackageController(package: package)
        parentViewController?.present(next: target)
    }
}
