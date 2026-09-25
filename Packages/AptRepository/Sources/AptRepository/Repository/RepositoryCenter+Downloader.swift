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
    /// Called whenever a download of this update hears from the server: an
    /// answer, or bytes, at most once a second per request. How the refresh
    /// queue tells a slow source from a dead one.
    var activity: @Sendable () -> Void = {}
}

extension RepositoryCenter {
    // MARK: - Downloader

    /// What asking for a file came to. A file the server says it does not
    /// have, a server that is broken and one that never answered are
    /// different news: only the first is a reason to forget what an earlier
    /// refresh found, and only the last two say anything about the host.
    enum Download: Sendable {
        case data(Data)
        /// the server answered, and not with the file (4xx)
        case absent
        /// the server answered with its own failure (5xx, or anything else
        /// that is not 200)
        case serverError(Int)
        /// no answer: the host was not found, the connection or its TLS
        /// failed, or it timed out or dropped; nil for a failure that is
        /// not URL loading's own
        case unreachable(URLError.Code?)
        /// cancelled because the update made no progress
        case stalled

        var data: Data? {
            if case let .data(data) = self {
                data
            } else {
                nil
            }
        }

        /// The server answered, whatever it said.
        var reachedServer: Bool {
            switch self {
            case .data, .absent, .serverError: true
            case .unreachable, .stalled: false
            }
        }

        var isStalled: Bool {
            if case .stalled = self {
                true
            } else {
                false
            }
        }

        /// No answer because this device has no network: nothing said
        /// about the host.
        var deviceOffline: Bool {
            if case .unreachable(.notConnectedToInternet) = self {
                true
            } else {
                false
            }
        }

        /// For a log line: `unreachable (timed out)`.
        var summary: String {
            switch self {
            case .data: "ok"
            case .absent: "absent"
            case let .serverError(code): "server error (HTTP \(code))"
            case let .unreachable(code): "unreachable (\(RepositoryCenter.reason(for: code)))"
            case .stalled: "stalled"
            }
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

    /// `downloadData`, saying why there is none. The body is read as it
    /// arrives, so `networking.activity` hears of a slow server that is
    /// still sending and not of one that went quiet.
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
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            networking.activity()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                bytes.task.cancel()
                // A repository that answers 404 for its Packages index looks
                // exactly like one that is merely empty unless this says so.
                let code = (response as? HTTPURLResponse)?.statusCode
                aptLog(
                    Self.self,
                    "\(fromUrl.absoluteString) answered HTTP \(code.map(String.init) ?? "no status")",
                    level: .error
                )
                guard let code else { return .serverError(0) }
                return (400 ..< 500).contains(code) ? .absent : .serverError(code)
            }
            return try await .data(read(bytes, expected: response.expectedContentLength, activity: networking.activity))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return .stalled
            }
            let code = (error as? URLError)?.code
            let reason = code.map(Self.reason(for:)) ?? String(describing: error)
            aptLog(Self.self, "request to \(fromUrl.absoluteString) failed: \(reason)", level: .error)
            return .unreachable(code)
        }
    }

    /// The body, collected in blocks. The clock is read every 512 bytes, so
    /// a trickle is heard of and a byte costs no clock read.
    private nonisolated static func read(
        _ bytes: URLSession.AsyncBytes,
        expected: Int64,
        activity: @Sendable () -> Void
    ) async throws -> Data {
        var data = Data()
        if expected > 0 {
            data.reserveCapacity(Int(min(expected, 64 << 20)))
        }
        var block = [UInt8]()
        block.reserveCapacity(1 << 16)
        var reported = Date()
        for try await byte in bytes {
            block.append(byte)
            guard block.count & 0x1FF == 0 else { continue }
            let now = Date()
            if now.timeIntervalSince(reported) >= 1 {
                activity()
                reported = now
            }
            if block.count == 1 << 16 {
                data.append(contentsOf: block)
                block.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: block)
        return data
    }

    /// A few words on why a request got no answer, for the log.
    nonisolated static func reason(for code: URLError.Code?) -> String {
        guard let code else { return "failed" }
        return switch code {
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "host not found"
        case .cannotConnectToHost: "cannot connect"
        case .networkConnectionLost: "connection lost"
        case .notConnectedToInternet: "offline"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            "TLS failed"
        default: "URL error \(code.rawValue)"
        }
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
        case .serverError, .unreachable, .stalled:
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
        case .serverError, .unreachable, .stalled:
            .unanswered
        }
    }

    /// One index file as the server sent it, still compressed: what a
    /// Release's digest is a digest of.
    struct FetchedIndex: Sendable {
        let url: URL
        let data: Data
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
