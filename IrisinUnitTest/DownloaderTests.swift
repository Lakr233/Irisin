//
//  DownloaderTests.swift
//  IrisinUnitTest
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
@testable import irisin
import XCTest

/// The downloader's byte accounting, against a stubbed server. The invariant
/// under test: the count of bytes on disk never passes the count the server
/// announced, and a bar built from the two never passes full.
final class DownloaderTests: XCTestCase {
    private var url: URL!
    private let body = Data("0123456789".utf8)

    override func setUp() {
        super.setUp()
        url = URL(string: "https://stub.test/\(UUID().uuidString).deb")
        PartialDownloads.discard(url)
    }

    override func tearDown() {
        PartialDownloads.discard(url)
        StubServer.respond = nil
        super.tearDown()
    }

    // MARK: - Pure policy

    /// A repository controls the last path component of its download links.
    /// Whatever it puts there, the partial file lands inside the directory.
    func testPartialFileNamesCannotEscapeTheDirectory() throws {
        let url = try XCTUnwrap(URL(string: "https://repo.example/../../../etc/passwd"))
        let file = PartialDownloads.file(for: url)
        XCTAssertEqual(file.deletingLastPathComponent().path, PartialDownloads.directory.path)
        XCTAssertFalse(file.lastPathComponent.contains(".."))
    }

    /// The bar never goes past full, whatever the numbers say: the total is
    /// the repository's guess until the server names one.
    func testProgressNeverReportsMoreThanEverything() {
        func fraction(_ completed: Int64, of total: Int64) -> Double {
            DownloadCenter.Status(
                package: Package(identity: "wiki.qaq.test"),
                url: url,
                completedBytes: completed,
                totalBytes: total
            ).fractionCompleted
        }
        XCTAssertEqual(fraction(5, of: 10), 0.5)
        XCTAssertEqual(fraction(10, of: 10), 1)
        XCTAssertEqual(fraction(12, of: 10), 1)
        XCTAssertEqual(fraction(5, of: 0), 0)
    }

    func testContentRangeCarriesTheOffsetAndTheWholeSize() {
        let range = Downloader.contentRange("bytes 9660646-72300329/72300330")
        XCTAssertEqual(range?.start, 9_660_646)
        XCTAssertEqual(range?.total, 72_300_330)

        XCTAssertNil(Downloader.contentRange(nil))
        XCTAssertNil(Downloader.contentRange("bytes */72300330"))
        XCTAssertNil(Downloader.contentRange("bytes 0-9/*"))
        XCTAssertNil(Downloader.contentRange("bytes 0-9/-1"))
        XCTAssertNil(Downloader.contentRange("garbage"))
    }

    func testPlanForAPlainResponseStartsFromTheTop() throws {
        // Even with bytes on disk: a 200 means the server ignored the Range.
        let plain = try Downloader.plan(for: response(200, ["Content-Length": "10"]), having: 4)
        XCTAssertEqual(plain, .init(start: 0, total: 10, resumable: false))

        let ranged = try Downloader.plan(
            for: response(200, ["Content-Length": "10", "Accept-Ranges": "bytes"]),
            having: 0
        )
        XCTAssertEqual(ranged, .init(start: 0, total: 10, resumable: true))

        let unsized = try Downloader.plan(for: response(200, [:]), having: 0)
        XCTAssertEqual(unsized, .init(start: 0, total: 0, resumable: false))
    }

    func testPlanForAPartialResponseContinuesWhereTheFileEnds() throws {
        let plan = try Downloader.plan(
            for: response(206, ["Content-Range": "bytes 4-9/10", "Content-Length": "6"]),
            having: 4
        )
        XCTAssertEqual(plan, .init(start: 4, total: 10, resumable: true))

        // Starting earlier than we have is fine: the file is cut back to there.
        let earlier = try Downloader.plan(for: response(206, ["Content-Range": "bytes 2-9/10"]), having: 4)
        XCTAssertEqual(earlier.start, 2)
    }

    func testPlanRejectsAPartialResponseThatWouldLeaveAHole() {
        XCTAssertThrowsError(try Downloader.plan(for: response(206, ["Content-Range": "bytes 6-9/10"]), having: 4)) {
            XCTAssertEqual($0 as? DownloadError, .malformedResponse)
        }
        XCTAssertThrowsError(try Downloader.plan(for: response(206, ["Content-Length": "6"]), having: 4)) {
            XCTAssertEqual($0 as? DownloadError, .malformedResponse)
        }
        XCTAssertThrowsError(try Downloader.plan(for: response(206, ["Content-Range": "bytes 12-9/10"]), having: 12)) {
            XCTAssertEqual($0 as? DownloadError, .malformedResponse)
        }
    }

    func testPlanRejectsAnythingButSuccess() {
        for status in [301, 404, 416, 500] {
            XCTAssertThrowsError(try Downloader.plan(for: response(status, [:]), having: 0)) {
                XCTAssertEqual($0 as? DownloadError, .badStatus(status))
            }
        }
    }

    // MARK: - End to end, against the stubbed server

    func testTheFinishedFileHoldsExactlyTheAnnouncedBytes() async throws {
        StubServer.respond = { _ in (200, ["Content-Length": "10"], [Data("0123".utf8), Data("456789".utf8)]) }
        let file = try await finish(collect())
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    /// The server promised ten bytes and sent twelve. That is not a longer
    /// file, it is a broken stream: the download fails and nothing of it is
    /// kept for a resume, however range-capable the server claims to be.
    func testMoreBytesThanAnnouncedFailsAndLeavesNothingBehind() async throws {
        StubServer.respond = { _ in
            (200, ["Content-Length": "10", "Accept-Ranges": "bytes"], [Data("012345".utf8), Data("6789ab".utf8)])
        }
        await XCTAssertThrowsErrorAsync(try await collect()) {
            XCTAssertEqual($0 as? DownloadError, .overrun(expected: 10, received: 12))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialDownloads.file(for: url).path))
    }

    func testFewerBytesThanAnnouncedFailsAndKeepsThePartialOnlyForARangeServer() async throws {
        StubServer.respond = { _ in (200, ["Content-Length": "10"], [Data("01234".utf8)]) }
        await XCTAssertThrowsErrorAsync(try await collect()) {
            XCTAssertEqual($0 as? DownloadError, .truncated(expected: 10, received: 5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: PartialDownloads.file(for: url).path))

        StubServer.respond = { _ in (200, ["Content-Length": "10", "Accept-Ranges": "bytes"], [Data("01234".utf8)]) }
        await XCTAssertThrowsErrorAsync(try await collect()) {
            XCTAssertEqual($0 as? DownloadError, .truncated(expected: 10, received: 5))
        }
        XCTAssertEqual(try Data(contentsOf: PartialDownloads.file(for: url)), body.prefix(5))
    }

    func testAPartialFileIsResumedWithARangeRequest() async throws {
        try body.prefix(4).write(to: PartialDownloads.file(for: url))
        StubServer.respond = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-")
            return (206, ["Content-Range": "bytes 4-9/10", "Content-Length": "6"], [Data("456789".utf8)])
        }
        let file = try await finish(collect())
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    /// A server that answers a Range request with a plain 200 sends the whole
    /// file again. Appending that to the partial would make a file bigger
    /// than the file; the partial is overwritten instead.
    func testAServerThatIgnoresTheRangeRestartsFromTheTop() async throws {
        try body.prefix(4).write(to: PartialDownloads.file(for: url))
        StubServer.respond = { [body] _ in (200, ["Content-Length": "10"], [body]) }
        let file = try await finish(collect())
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testAPartialResponseThatSkipsAheadIsRejected() async throws {
        try body.prefix(4).write(to: PartialDownloads.file(for: url))
        StubServer.respond = { _ in (206, ["Content-Range": "bytes 6-9/10"], [Data("6789".utf8)]) }
        await XCTAssertThrowsErrorAsync(try await collect()) {
            XCTAssertEqual($0 as? DownloadError, .malformedResponse)
        }
    }

    // MARK: - Helpers

    private func response(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    /// Runs one download through the stub and checks, on every progress
    /// event, that the count never passes the total.
    private func collect() async throws -> [DownloadEvent] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        var events = [DownloadEvent]()
        for try await event in Downloader.download(from: url, session: URLSession(configuration: configuration)) {
            if case let .progress(completed, total, _) = event, total > 0 {
                XCTAssertLessThanOrEqual(completed, total)
            }
            events.append(event)
        }
        return events
    }

    private func finish(_ events: [DownloadEvent]) throws -> URL {
        guard case let .finished(file)? = events.last else {
            XCTFail("download ended without finishing: \(events)")
            throw DownloadError.malformedResponse
        }
        return file
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (any Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}

/// One canned HTTP exchange per test, served through `URLProtocol` so the
/// real `URLSession` machinery sits between the stub and the downloader.
private final class StubServer: URLProtocol {
    typealias Reply = (status: Int, headers: [String: String], chunks: [Data])
    nonisolated(unsafe) static var respond: ((URLRequest) -> Reply)?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let reply = Self.respond?(request),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
