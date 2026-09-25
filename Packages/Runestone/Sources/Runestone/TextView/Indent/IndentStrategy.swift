import Foundation

/// Strategy to use when indenting text.
public enum IndentStrategy: Equatable {
    /// Indent using tabs. The specified length is used to determine the width of the tab measured in space characers.
    case tab(length: Int)
    /// Indent using a number of spaces.
    case space(length: Int)
}

extension IndentStrategy {
    var tabLength: Int {
        switch self {
        case let .tab(length):
            length
        case let .space(length):
            length
        }
    }

    func string(indentLevel: Int) -> String {
        switch self {
        case .tab:
            String(repeating: Symbol.Character.tab, count: indentLevel)
        case let .space(length):
            String(repeating: Symbol.Character.space, count: length * indentLevel)
        }
    }
}
