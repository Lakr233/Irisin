import Foundation

final class TreeSitterPredicate {
    enum Step {
        case capture(UInt32)
        case string(String)
    }

    let name: String
    let steps: [Step]

    init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }
}

extension TreeSitterPredicate: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterPredicate name=\(name) steps=\(steps)]"
    }
}

extension TreeSitterPredicate.Step: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case let .capture(id):
            "[TreeSitterPredicate.Step capture=\(id)]"
        case let .string(string):
            "[TreeSitterPredicate.Step string=\(string)]"
        }
    }
}
