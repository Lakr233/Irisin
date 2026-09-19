//
//  RepositoryCenter+Downloader.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/6.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Foundation

/// The headers, timeout and logging switch a repository download runs with.
/// Read off the center when an update is dispatched, so the download itself
/// never touches main-actor state.
struct NetworkingConfiguration: Sendable {
    let headers: [String: String]
    let timeout: Int
    let verboseLogging: Bool
}

extension RepositoryCenter {
    // MARK: - Downloader

    /// What asking for a file came to. A file the server says it does not
    /// have and a request that never got an answer are different news: only
    /// the first is a reason to forget what an earlier refresh found.
    enum Download: Sendable {
        case data(Data)
        /// the server answered, and not with the file (4xx)
        case absent
        /// no answer, or the server's own failure
        case failed

        var data: Data? {
            if case let .data(data) = self { data } else { nil }
        }
    }

    /// What looking for an optional part of a repository came to.
    enum Detected<Value: Sendable>: Sendable {
        case found(Value)
        /// the repository has none: forget the one remembered
        case absent
        /// nobody answered: what is remembered stays
        case unanswered
    }

    /// download data, header is injected from networkingHeaders, timeout is used with networkingTimeout
    /// - Parameter fromUrl: data url
    /// - Returns: data if success
    nonisolated static func downloadData(fromUrl: URL, networking: NetworkingConfiguration) async -> Data? {
        await download(fromUrl: fromUrl, networking: networking).data
    }

    /// `downloadData`, saying why there is none.
    nonisolated static func download(fromUrl: URL, networking: NetworkingConfiguration) async -> Download {
        var request = URLRequest(
            url: fromUrl,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: TimeInterval(networking.timeout)
        )
        for (key, value) in networking.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if networking.verboseLogging {
            aptLog(Self.self, "requesting \(fromUrl.absoluteString)", level: .verbose)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // A repository that answers 404 for its Packages index looks
                // exactly like one that is merely empty unless this says so.
                let code = (response as? HTTPURLResponse)?.statusCode
                aptLog(
                    Self.self,
                    "\(fromUrl.absoluteString) answered HTTP \(code.map(String.init) ?? "no status")",
                    level: .error
                )
                return code.map { (400 ..< 500).contains($0) } == true ? .absent : .failed
            }
            return .data(data)
        } catch {
            aptLog(
                Self.self,
                "request to \(fromUrl.absoluteString) failed: \(error.localizedDescription)",
                level: .error
            )
            return .failed
        }
    }

    /// download release metadata from repo
    /// - Parameter withUrl: target url
    /// - Returns: release metadata if success
    nonisolated static func downloadUpdateRelease(withUrl: URL, networking: NetworkingConfiguration) async -> String? {
        guard let data = await downloadData(fromUrl: withUrl, networking: networking) else { return nil }
        return IndexText.decode(data)
    }

    /// detect if this repo supports commercial package
    /// - Parameter withUrl: target url, we will append payment_endpoint inside the function
    /// - Returns: the endpoint, that there is none, or that nobody answered
    nonisolated static func detectPaymentEndpoint(
        withUrl: URL,
        networking: NetworkingConfiguration
    ) async -> Detected<URL> {
        switch await download(fromUrl: withUrl.appendingPathComponent("payment_endpoint"), networking: networking) {
        case let .data(data):
            String(data: data, encoding: .utf8).flatMap { URL(string: $0) }.map { .found($0) } ?? .absent
        case .absent:
            .absent
        case .failed:
            .unanswered
        }
    }

    /// detect if this repo supports featured package and returns json data
    /// - Parameter withUrl: target url, we will append featured.json inside the function
    /// - Returns: the json string, that there is none, or that nobody answered
    nonisolated static func detectFeaturedMetadata(
        withUrl: URL,
        networking: NetworkingConfiguration
    ) async -> Detected<String> {
        switch await download(fromUrl: withUrl.appendingPathComponent("sileo-featured.json"), networking: networking) {
        case let .data(data):
            if let str = String(data: data, encoding: .utf8), str.contains("FeaturedBannersView") {
                .found(str)
            } else {
                .absent
            }
        case .absent:
            .absent
        case .failed:
            .unanswered
        }
    }

    /// One index file as the server sent it, still compressed: what a
    /// Release's digest is a digest of.
    struct FetchedIndex: Sendable {
        let url: URL
        let data: Data
    }

    /// download one package index, as served
    /// - Parameters:
    ///   - withBaseUrl: base url
    ///   - suffix: url path extension
    /// - Returns: the file if success
    nonisolated static func downloadUpdatePackage(
        withBaseUrl: URL,
        suffix: String,
        networking: NetworkingConfiguration
    ) async -> FetchedIndex? {
        let targetUrl = withBaseUrl.appendingPathExtension(suffix)
        guard let data = await downloadData(fromUrl: targetUrl, networking: networking) else { return nil }
        return FetchedIndex(url: targetUrl, data: data)
    }

    /// the text of a downloaded package index, decompressed if needed
    /// - Parameters:
    ///   - index: the file as served
    ///   - suffix: the path extension it was asked for with
    /// - Returns: package metadata if success
    nonisolated static func decodeUpdatePackage(_ index: FetchedIndex, suffix: String) -> String? {
        switch suffix {
        case "":
            return IndexText.decode(index.data)
        case "bz", "bz2", "gz", "gz2", "lzma", "lzma2", "xz", "xz2", "zst", "zstd", "lz4":
            // libarchive picks the filter from the bytes, so the suffix only
            // decides whether an index is expected to be compressed at all.
            do {
                return try IndexText.decode(ArchiveStream.decompress(index.data))
            } catch {
                aptLog(Self.self, "\(index.url.absoluteString) could not be decompressed: \(error)", level: .error)
            }
        default:
            aptLog(Self.self, "unknown archive path extension \(suffix)", level: .error)
        }
        return nil
    }
}
