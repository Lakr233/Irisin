//
//  Throttler.swift
//  AptRepository
//

import Combine
import Foundation

/// Coalesces bursts of work on the main actor. The first job runs straight
/// away; while calls keep arriving inside `minimumDelay` only the most recent
/// one survives to run at the end of the window.
@MainActor
public final class Throttler {
    private let subject = PassthroughSubject<@MainActor () -> Void, Never>()
    private var cancellable: AnyCancellable?

    public init(minimumDelay: TimeInterval) {
        cancellable = subject
            .throttle(for: .seconds(minimumDelay), scheduler: DispatchQueue.main, latest: true)
            .sink { job in MainActor.assumeIsolated { job() } }
    }

    public func throttle(_ job: @escaping @MainActor () -> Void) {
        subject.send(job)
    }
}
