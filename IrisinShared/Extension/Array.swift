//
//  Array.swift
//  Irisin
//

nonisolated extension Array where Element: Hashable {
    /// Each element once, where it first appears: a snapshot aborts on a
    /// duplicated identifier, and a list of addresses names each once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
