//
//  Task.swift
//  Irisin
//

import Foundation

nonisolated extension Task where Success == Never, Failure == Never {
    static func sleep(seconds: Double) async throws {
        try await sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// `sleep(for: .seconds(seconds))`, which counts while the device
    /// sleeps, on iOS 16 and later. iOS 15 has no `Duration`, and there it
    /// is the uptime clock's nanoseconds, which stop with the device.
    static func sleep(continuousSeconds seconds: Double) async throws {
        if #available(iOS 16, *) {
            try await sleep(for: .seconds(seconds))
        } else {
            try await sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    }
}

/// A moment on the clock that counts while the device sleeps, as
/// `ContinuousClock` does: `CLOCK_MONOTONIC_RAW` is the clock it reads on
/// Darwin, and it is there on iOS 15 too.
nonisolated struct ContinuousDeadline: Sendable, Comparable {
    private let nanoseconds: UInt64

    static var now: ContinuousDeadline {
        ContinuousDeadline(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }

    static func + (deadline: ContinuousDeadline, seconds: TimeInterval) -> ContinuousDeadline {
        ContinuousDeadline(nanoseconds: deadline.nanoseconds + UInt64(max(0, seconds) * 1_000_000_000))
    }

    static func < (lhs: ContinuousDeadline, rhs: ContinuousDeadline) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Sleeps until the deadline, at once when it has passed.
    func sleep() async throws {
        let now = ContinuousDeadline.now.nanoseconds
        guard nanoseconds > now else { return }
        try await Task<Never, Never>.sleep(continuousSeconds: Double(nanoseconds - now) / 1_000_000_000)
    }
}

extension Task where Failure == Never {
    /// Waits for the task to finish, but no longer than `budget`; the task
    /// runs on either way. A page's first load gets about twelve frames this
    /// way before the page is pushed, so a quick one lands with it and only
    /// a slow one animates in after. A task's value cannot be cancelled and
    /// a task group waits for every child, so the sleep is what is cut short.
    func wait(upTo budget: TimeInterval) async {
        let timer = Task<Void, Error> { try await Task<Never, Never>.sleep(continuousSeconds: budget) }
        let answer = Task<Void, Never> {
            _ = await value
            timer.cancel()
        }
        _ = try? await timer.value
        answer.cancel()
    }
}
