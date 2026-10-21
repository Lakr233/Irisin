//
//  TestUpdate.swift
//  Irisin
//

import Foundation

/// The newest Irisin published on GitHub, a pre-release included, in the
/// flavor this app was packaged as: how a tester gets a build before it
/// reaches a repository. The file is opened as any `.deb` handed to the
/// app is, so what installs it is the ordinary package page.
nonisolated enum TestUpdate {
    enum Failure: Error {
        /// GitHub did not answer, or the download failed.
        case unreachable
        /// The newest release has no package for this flavor.
        case noPackage
    }

    /// Newest first, pre-releases included; drafts are not listed.
    private static let releases = URL(string: "https://api.github.com/repos/Lakr233/Irisin/releases?per_page=1")!

    private struct Release: Decodable {
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// The package for `architecture`, in a directory of its own under the
    /// temporary directory and named as the release names it: the caller's
    /// to move.
    @concurrent
    static func download(architecture: String) async throws(Failure) -> URL {
        var request = URLRequest(url: releases, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let newest = try? JSONDecoder().decode([Release].self, from: data).first
        else { throw .unreachable }
        guard let asset = newest.assets.first(where: { $0.name.hasSuffix("_\(architecture).deb") }) else {
            throw .noPackage
        }
        do {
            let (downloaded, answer) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            guard (answer as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unreachable }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TestUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: downloaded, to: file)
            return file
        } catch {
            throw .unreachable
        }
    }
}
