//
//  Downloader.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

nonisolated enum DownloadEvent: Sendable {
    /// Sampled a couple of times a second, not once per packet. `totalBytes`
    /// is zero when the server did not say how big the file is.
    case progress(completedBytes: Int64, totalBytes: Int64, bytesPerSecond: Int64)
    /// Every announced byte arrived. The file is the caller's to move or delete.
    case finished(URL)
}

/// Which of these a download tripped over is a line in the log; the person
/// sees one sentence for all of them.
nonisolated enum DownloadError: LocalizedError, Equatable {
    case malformedResponse
    case badStatus(Int)
    case truncated(expected: Int64, received: Int64)
    /// More bytes than the server announced. Something between us and the
    /// file is broken; a file that "finished" like this is not the file.
    case overrun(expected: Int64, received: Int64)

    var errorDescription: String? {
        String(localized: "Download failed. Try again.")
    }
}

/// One HTTP file download per call, delivered as a stream of events:
///
/// ```swift
/// for try await event in Downloader.download(from: url) { ... }
/// ```
///
/// Cancelling the consuming task stops the transfer. Bytes already on disk are
/// kept for a later resume **only** when the server proves it honours `Range`
/// — a 206 with `Content-Range`, or an `Accept-Ranges: bytes` header. Anything
/// else leaves nothing behind, because a partial file we cannot continue is
/// worse than no file at all: the next attempt would have to guess.
nonisolated enum Downloader {
    /// The floor between two `.progress` events.
    static let progressInterval: TimeInterval = 0.5

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 100
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// `session` is for tests; the app never passes one.
    static func download(
        from url: URL,
        headers: [String: String] = [:],
        session: URLSession? = nil
    ) -> AsyncThrowingStream<DownloadEvent, any Error> {
        let session = session ?? Self.session
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await run(url: url, headers: headers, session: session, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func run(
        url: URL,
        headers: [String: String],
        session: URLSession,
        into continuation: AsyncThrowingStream<DownloadEvent, any Error>.Continuation
    ) async throws {
        let partial = PartialDownloads.file(for: url)
        var request = URLRequest(url: url)
        // HTTP/3 packets can outgrow the reduced MTU inside a VPN tunnel and
        // abort a large download with -1005. TCP has no such trouble.
        request.assumesHTTP3Capable = false
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if onDisk > 0 {
            request.setValue("bytes=\(onDisk)-", forHTTPHeaderField: "Range")
        }

        var resumable = false
        do {
            var writer: FileHandle?
            defer { try? writer?.close() }
            var completed: Int64 = 0
            var total: Int64 = 0
            // A rate on a fixed interval, so a download wakes its reader a
            // couple of times a second instead of once per packet.
            var sampledBytes: Int64 = 0
            var sampledAt = Date()

            for try await chunk in DownloadTaskRelay.stream(for: request, in: session) {
                switch chunk {
                case let .response(response):
                    let plan = try plan(for: response, having: onDisk)
                    resumable = plan.resumable
                    completed = plan.start
                    total = plan.total
                    writer = try open(partial, truncatingTo: completed)
                    continuation.yield(.progress(completedBytes: completed, totalBytes: total, bytesPerSecond: 0))
                case let .data(data):
                    guard let writer else { throw DownloadError.malformedResponse }
                    completed += Int64(data.count)
                    // Checked before the write so the partial file never
                    // holds a byte the server did not announce.
                    if total > 0, completed > total {
                        // Whatever is on disk came from the same broken
                        // stream; nothing there is worth resuming from.
                        resumable = false
                        throw DownloadError.overrun(expected: total, received: completed)
                    }
                    try writer.write(contentsOf: data)
                    let now = Date()
                    let elapsed = now.timeIntervalSince(sampledAt)
                    if elapsed >= progressInterval {
                        continuation.yield(.progress(
                            completedBytes: completed,
                            totalBytes: total,
                            bytesPerSecond: Int64(Double(completed - sampledBytes) / elapsed)
                        ))
                        sampledBytes = completed
                        sampledAt = now
                    }
                }
            }

            // An AsyncStream ends quietly when its consumer goes away, so a
            // short file is the only tell left that this was a cancellation
            // rather than a complete download.
            try Task.checkCancellation()
            guard total <= 0 || completed == total else {
                throw DownloadError.truncated(expected: total, received: completed)
            }
            try writer?.close()
            writer = nil
            continuation.yield(.finished(partial))
        } catch {
            if !resumable {
                try? FileManager.default.removeItem(at: partial)
            }
            throw error
        }
    }

    /// Opens the partial file for writing with exactly `offset` bytes in it,
    /// creating it when this is the first attempt.
    private static func open(_ file: URL, truncatingTo offset: Int64) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()
        return handle
    }

    /// What one response commits us to: the offset its bytes start at, the
    /// size of the whole file (zero when unknown), and whether a partial file
    /// is worth keeping for a later `Range` request.
    struct Plan: Equatable {
        var start: Int64
        var total: Int64
        var resumable: Bool
    }

    /// Decides the plan from the status line and headers alone, given how many
    /// bytes were already on disk when the request went out.
    static func plan(for response: HTTPURLResponse, having onDisk: Int64) throws -> Plan {
        guard (200 ..< 300).contains(response.statusCode) else {
            throw DownloadError.badStatus(response.statusCode)
        }
        let acceptsRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        guard response.statusCode == 206 else {
            // The server sent the file from the top, whatever we asked for:
            // throw away what we had.
            return Plan(start: 0, total: max(response.expectedContentLength, 0), resumable: acceptsRanges)
        }
        // A 206 must say where its bytes go; one that does not, or that starts
        // past the end of what we have, would leave a hole in the file.
        guard let range = contentRange(response.value(forHTTPHeaderField: "Content-Range")),
              range.start <= onDisk,
              range.start <= range.total
        else { throw DownloadError.malformedResponse }
        return Plan(start: range.start, total: range.total, resumable: true)
    }

    /// `bytes 9660646-72300329/72300330` — where this response picks up and how
    /// big the whole file is.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64)? {
        guard let header,
              let total = Int64(header.components(separatedBy: "/").last ?? ""),
              let start = Int64(
                  header.components(separatedBy: "/").first?
                      .components(separatedBy: "-").first?
                      .components(separatedBy: " ").last ?? ""
              ),
              start >= 0, total >= 0
        else { return nil }
        return (start, total)
    }
}
