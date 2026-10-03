//
//  Created by ktiays on 2025/1/31.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import DequeModule
import UIKit

@MainActor
private class ObjectPool<T: Equatable & Hashable> {
    private let factory: () -> T
    private lazy var objects: Deque<T> = .init()

    init(_ factory: @escaping () -> T) {
        self.factory = factory
    }

    func acquire() -> T {
        if let object = objects.popFirst() {
            object
        } else {
            factory()
        }
    }

    func stash(_ object: T) {
        objects.append(object)
    }

    /// Takes `object` out of the pool, so nothing else can acquire it.
    /// Returns whether it was there to take.
    func withdraw(_ object: T) -> Bool {
        guard let index = objects.firstIndex(where: { $0 == object }) else { return false }
        objects.remove(at: index)
        return true
    }

    func reorder(matching sequence: [T]) {
        var current = Set(objects)
        objects.removeAll()
        for content in sequence where current.contains(content) {
            objects.append(content)
            current.remove(content)
        }
        for reset in current {
            objects.append(reset) // stash the rest
        }
    }
}

@MainActor
public final class ReusableViewProvider {
    private let codeViewPool: ObjectPool<CodeView> = .init {
        CodeView(frame: .zero)
    }

    private let tableViewPool: ObjectPool<TableView> = .init {
        TableView(frame: .zero)
    }

    public init() {}

    func acquireCodeView() -> CodeView {
        codeViewPool.acquire()
    }

    func stashCodeView(_ codeView: CodeView) {
        codeViewPool.stash(codeView)
    }

    func acquireTableView() -> TableView {
        tableViewPool.acquire()
    }

    func stashTableView(_ tableView: TableView) {
        tableViewPool.stash(tableView)
    }

    /// Takes a view a cached block brings back out of the pool before any
    /// other block can acquire it.
    ///
    /// Returns false when the view is not in the pool — someone else holds
    /// it — and the block then has to be built again rather than share it.
    func withdraw(_ view: UIView) -> Bool {
        if let codeView = view as? CodeView {
            return codeViewPool.withdraw(codeView)
        }
        if let tableView = view as? TableView {
            return tableViewPool.withdraw(tableView)
        }
        return false
    }

    func reorderViews(matching sequence: [UIView]) {
        // we adjust the sequence of stashed views to match the order
        // afterwards when TextBuilder visit a node requesting new view
        // it will follow the order to avoid glitch

        let orderedCodeView = sequence.compactMap { $0 as? CodeView }
        let orderedTableView = sequence.compactMap { $0 as? TableView }

        codeViewPool.reorder(matching: orderedCodeView)
        tableViewPool.reorder(matching: orderedTableView)
    }
}
