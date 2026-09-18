//
//  Task.swift
//  Irisin
//

import Foundation

nonisolated extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async throws {
        try await sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

extension Task where Failure == Never {
    /// Waits for the task to finish, but no longer than `budget`; the task
    /// runs on either way. A page's first load gets about twelve frames this
    /// way before the page is pushed, so a quick one lands with it and only
    /// a slow one animates in after. A task's value cannot be cancelled and
    /// a task group waits for every child, so the sleep is what is cut short.
    func wait(upTo budget: Duration) async {
        let timer = Task<Void, Error> { try await Task<Never, Never>.sleep(for: budget) }
        let answer = Task<Void, Never> {
            _ = await value
            timer.cancel()
        }
        _ = try? await timer.value
        answer.cancel()
    }
}
