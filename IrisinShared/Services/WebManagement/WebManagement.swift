//
//  WebManagement.swift
//  Irisin
//

import Combine
import Dog
import Foundation
import IrisinWeb

/// Managing this device from a browser on the local network
/// (Documentation/WebManagement.md): the server of one start, the code it
/// shows, and the owner's answers. The launchpad serves while it is open
/// and stops when it goes; every change a browser asks for is put to the
/// owner here first, one at a time, and goes ahead only on their yes.
final class WebManagement {
    static let shared = WebManagement()

    /// What the screen shows about the server.
    struct Status: Equatable {
        /// The six digits of this start; nil while nothing is served.
        var code: String?
        /// The page on each local network, the code in its fragment.
        var addresses: [String] = []
        /// Why nothing is served, in words; nil while it is, or before it
        /// was asked to.
        var problem: String?
    }

    /// A change a browser asked for, put to the owner on the device.
    struct Question: Equatable, Identifiable {
        let id = UUID()
        let title: String
        /// What it does, one line each: what installs, what goes, and what
        /// the device has to say beside it.
        let lines: [String]
        /// The button that says yes; the other always declines.
        let confirmTitle: String
        /// The yes takes something away or is likely to fail.
        let destructive: Bool
    }

    @Published private(set) var status = Status()
    /// The question on screen, nil when nothing is asked.
    @Published private(set) var question: Question?

    /// The changes browsers asked for this start, and their states.
    let requests = WebRequests()
    /// The lines of the operation a browser started last.
    let feed = OperationFeed()

    private var server: WebServer?
    private var starting: Task<Void, Never>?
    /// Which start is current: a stop and a start in quick succession leave
    /// the earlier one's task to finish on its own, owning nothing.
    private var generation = 0
    private var answer: CheckedContinuation<Bool, Never>?

    private init() {}

    /// The page `WebUI/` builds, which the Build Web UI phase copies into
    /// the bundle.
    private static var webRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("WebUI", isDirectory: true)
    }

    var isServing: Bool {
        server != nil
    }

    /// Serves with a fresh code. A server already up keeps its own.
    func start() {
        guard server == nil, starting == nil else { return }
        let server = WebServer(responder: WebCalls.Responder(), webRoot: Self.webRoot)
        generation += 1
        let current = generation
        starting = Task {
            defer {
                if generation == current {
                    starting = nil
                }
            }
            do {
                let port = try await server.start()
                guard generation == current else {
                    server.stop()
                    return
                }
                self.server = server
                requests.removeAll()
                status = Status(code: server.key.code, addresses: addresses(of: server))
                Dog.shared.join("WebManagement", "serving on port \(port)", level: .info)
            } catch {
                guard generation == current else { return }
                Dog.shared.join("WebManagement", "could not listen: \(error)", level: .error)
                status = Status(problem: String(localized: "The page could not be served: \(error.localizedDescription)"))
            }
        }
    }

    /// Stops serving. An open question is declined: nobody is there to
    /// answer it, and the browser that asked has lost its key.
    func stop() {
        generation += 1
        starting?.cancel()
        starting = nil
        server?.stop()
        server = nil
        status = Status()
        if let question {
            answer(question.id, allowed: false)
        }
        Dog.shared.join("WebManagement", "stopped serving", level: .info)
    }

    /// Reads the device's addresses again, after the network changed.
    func refreshAddresses() {
        guard let server else { return }
        let addresses = addresses(of: server)
        if addresses != status.addresses {
            status.addresses = addresses
        }
    }

    private func addresses(of server: WebServer) -> [String] {
        LocalAddress.current().map { server.url(host: $0) }
    }

    /// Puts a change to the owner and returns their answer. One question at
    /// a time; while one is open, or with nothing served, the answer is no.
    func ask(_ question: Question) async -> Bool {
        guard self.question == nil, server != nil else { return false }
        self.question = question
        return await withCheckedContinuation { answer = $0 }
    }

    /// The owner's answer to the question on screen.
    func answer(_ id: Question.ID, allowed: Bool) {
        guard question?.id == id else { return }
        question = nil
        let waiting = answer
        answer = nil
        waiting?.resume(returning: allowed)
    }
}
