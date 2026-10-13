//
//  LockedState.swift
//  Irisin
//

import os

/// A value behind an `os_unfair_lock`, for iOS 15, which has no
/// `OSAllocatedUnfairLock`. The lock lives in memory of its own, never
/// inside a Swift property, which may move.
nonisolated final class LockedState<State>: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var state: State

    init(initialState: State) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        state = initialState
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body(&state)
    }
}
