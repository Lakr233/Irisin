//
//  DownloadTaskRelay.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// One data task's delegate callbacks as an async sequence: the response,
/// then every chunk of the body as it arrives. `URLSession.bytes(for:)` would
/// do the same one byte at a time, which is too slow for a .deb.
///
/// `URLSession` retains a per-task delegate until the task ends, and the
/// continuation's termination handler holds this one for as long as anyone is
/// reading. Dropping the reader cancels the task.
final nonisolated class DownloadTaskRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Chunk: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    private let continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    private var task: URLSessionDataTask?

    static func stream(for request: URLRequest, in session: URLSession) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            _ = DownloadTaskRelay(request: request, session: session, continuation: continuation)
        }
    }

    private init(
        request: URLRequest,
        session: URLSession,
        continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) {
        self.continuation = continuation
        super.init()

        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        // Capturing self is what keeps this relay alive while anyone reads.
        continuation.onTermination = { [self] _ in self.task?.cancel() }
        task.resume()
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: DownloadError.malformedResponse)
            return .cancel
        }
        continuation.yield(.response(response))
        return .allow
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}
