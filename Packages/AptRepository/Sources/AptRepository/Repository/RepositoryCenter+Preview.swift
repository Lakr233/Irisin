//
//  RepositoryCenter+Preview.swift
//  AptRepository
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// What a repository looks like before it is registered: the label and
/// description from its Release file, and its icon.
public struct RepositoryPreview: Sendable {
    public let name: String
    public let description: String?
    public let avatar: Data?
}

public extension RepositoryCenter {
    /// Fetches the Release file and the icon of a source that is not
    /// registered. Nil when the address does not answer as a repository.
    func preview(of source: RepositorySource) async -> RepositoryPreview? {
        let repository = Repository(source: source)
        return await Self.fetchPreview(
            releaseUrl: repository.metaReleaseUrl,
            avatarUrls: repository.avatarUrls,
            networking: networkingConfiguration
        )
    }

    internal nonisolated static func fetchPreview(
        releaseUrl: URL,
        avatarUrls: [URL],
        networking: NetworkingConfiguration
    ) async -> RepositoryPreview? {
        async let avatar = downloadAvatar(from: avatarUrls, networking: networking)
        guard let release = await downloadData(fromUrl: releaseUrl, networking: networking),
              let meta = ReleaseFile.read(IndexText.decode(release))?.fields
        else {
            return nil
        }
        return await RepositoryPreview(
            name: meta["label"] ?? meta["origin"] ?? releaseUrl.host ?? "repo",
            description: meta["description"] ?? meta["version"],
            avatar: avatar
        )
    }
}
