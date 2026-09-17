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

    /// download data, header is injected from networkingHeaders, timeout is used with networkingTimeout
    /// - Parameter fromUrl: data url
    /// - Returns: data if success
    nonisolated static func downloadData(fromUrl: URL, networking: NetworkingConfiguration) async -> Data? {
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
                return nil
            }
            return data
        } catch {
            aptLog(
                Self.self,
                "request to \(fromUrl.absoluteString) failed: \(error.localizedDescription)",
                level: .error
            )
            return nil
        }
    }

    /// download release metadata from repo, re-encode if isoLatin1 found
    /// - Parameter withUrl: target url
    /// - Returns: release metadata if success
    nonisolated static func downloadUpdateRelease(withUrl: URL, networking: NetworkingConfiguration) async -> String? {
        guard let data = await downloadData(fromUrl: withUrl, networking: networking) else { return nil }
        guard let original = String(data: data, encoding: .utf8) else {
            aptLog(Self.self, "\(withUrl.absoluteString) is not text, \(data.count) bytes", level: .error)
            return nil
        }
        return repaired(original)
    }

    /// Text that is UTF-8 read as Latin-1, read again as UTF-8; anything else unchanged.
    private nonisolated static func repaired(_ text: String) -> String {
        if let decode = text.data(using: .isoLatin1, allowLossyConversion: false),
           let reEncoded = String(data: decode, encoding: .utf8)
        {
            return reEncoded
        }
        return text
    }

    /// detect if this repo supports commercial package
    /// - Parameter withUrl: target url, we will append payment_endpoint inside the function
    /// - Returns: endpoint if success
    nonisolated static func detectPaymentEndpoint(withUrl: URL, networking: NetworkingConfiguration) async -> String? {
        guard let data = await downloadData(
            fromUrl: withUrl.appendingPathComponent("payment_endpoint"),
            networking: networking
        )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// detect if this repo supports featured package and returns json data
    /// - Parameter withUrl: target url, we will append featured.json inside the function
    /// - Returns: json string if success
    nonisolated static func detectFeaturedMetadata(withUrl: URL, networking: NetworkingConfiguration) async -> String? {
        guard let data = await downloadData(
            fromUrl: withUrl.appendingPathComponent("sileo-featured.json"),
            networking: networking
        ),
            let str = String(data: data, encoding: .utf8),
            str.contains("FeaturedBannersView")
        else {
            return nil
        }
        return str
    }

    /// download the package, decompress if needed
    /// - Parameters:
    ///   - withBaseUrl: base url
    ///   - suffix: url path extension
    /// - Returns: package metadata if success
    nonisolated static func downloadUpdatePackage(
        withBaseUrl: URL,
        suffix: String,
        networking: NetworkingConfiguration
    ) async -> String? {
        let targetUrl = withBaseUrl.appendingPathExtension(suffix)
        guard let data = await downloadData(fromUrl: targetUrl, networking: networking) else { return nil }
        var resultBuilder: String?
        switch suffix {
        case "":
            resultBuilder = String(data: data, encoding: .utf8)
        case "bz", "bz2", "gz", "gz2", "lzma", "lzma2", "xz", "xz2", "zst", "zstd", "lz4":
            // libarchive picks the filter from the bytes, so the suffix only
            // decides whether an index is expected to be compressed at all.
            do {
                let decompress = try ArchiveStream.decompress(data)
                if let str = String(data: decompress, encoding: .utf8) {
                    resultBuilder = str
                } else if let str = String(data: decompress, encoding: .ascii) {
                    resultBuilder = str
                } else {
                    aptLog(
                        Self.self,
                        "\(targetUrl.absoluteString) decompressed to \(decompress.count) bytes of neither utf8 nor ascii",
                        level: .error
                    )
                }
            } catch {
                aptLog(Self.self, "\(targetUrl.absoluteString) could not be decompressed: \(error)", level: .error)
            }
        default:
            aptLog(Self.self, "unknown archive path extension \(suffix)", level: .error)
        }
        return resultBuilder.map(repaired)
    }
}
