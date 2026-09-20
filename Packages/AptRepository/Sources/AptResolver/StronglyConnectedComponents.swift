/// Iterative Kosaraju traversal: long dependency chains do not consume the
/// Swift call stack. Returns dependencies before their dependants.
enum StronglyConnectedComponents {
    static func components(_ graph: [Int: [Int]]) -> [Set<Int>] {
        var visited = Set<Int>()
        var order: [Int] = []
        for node in graph.keys.sorted() where !visited.contains(node) {
            var stack: [(Int, Bool)] = [(node, false)]
            while let (current, finish) = stack.popLast() {
                if finish {
                    order.append(current); continue
                }
                guard visited.insert(current).inserted else { continue }
                stack.append((current, true))
                for next in (graph[current] ?? []).reversed() where graph[next] != nil && !visited.contains(next) {
                    stack.append((next, false))
                }
            }
        }
        var reverse: [Int: [Int]] = [:]
        for (node, edges) in graph {
            for next in edges {
                reverse[next, default: []].append(node)
            }
        }
        visited.removeAll(keepingCapacity: true)
        var result: [Set<Int>] = []
        for node in order.reversed() where !visited.contains(node) {
            var component = Set<Int>()
            var stack = [node]
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                component.insert(current)
                stack += reverse[current] ?? []
            }
            result.append(component)
        }
        return result.reversed()
    }
}
