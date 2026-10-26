//
//  WebRequests.swift
//  Irisin
//

import Foundation
import IrisinWeb

/// The changes browsers asked for: each waits for the owner's answer on the
/// device, then for its run, and the page polls its state
/// (`Packages/IrisinWeb/README.md`, Requests). Kept for this server start
/// only; a request the page never polls again is dropped after a while.
final class WebRequests {
    enum State: String {
        case asking, declined, running, done, failed

        var isFinished: Bool {
            self == .declined || self == .done || self == .failed
        }
    }

    struct Request {
        let id: UUID
        var state: State
        var detail: String?
        var updated: Date
    }

    private var requests: [UUID: Request] = [:]
    /// A finished request is kept this long for the page to read.
    private static let kept: TimeInterval = 600

    func add() -> UUID {
        prune()
        let id = UUID()
        requests[id] = Request(id: id, state: .asking, detail: nil, updated: Date())
        return id
    }

    func update(_ id: UUID, _ state: State, detail: String? = nil) {
        requests[id]?.state = state
        requests[id]?.detail = detail
        requests[id]?.updated = Date()
    }

    /// Whether a request is still waiting for the owner or its run: the
    /// device asks one thing at a time.
    var hasOpen: Bool {
        requests.values.contains { !$0.state.isFinished }
    }

    func json(_ id: UUID) -> JSONValue? {
        requests[id].map(Self.json)
    }

    static func json(_ request: Request) -> JSONValue {
        .object([
            "id": .string(request.id.uuidString),
            "state": .string(request.state.rawValue),
            "detail": request.detail.map(JSONValue.string) ?? .null,
        ])
    }

    func removeAll() {
        requests = [:]
    }

    private func prune() {
        let now = Date()
        requests = requests.filter { !$0.value.state.isFinished || now.timeIntervalSince($0.value.updated) < Self.kept }
    }
}
