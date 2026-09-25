import Foundation

/// Approach for highlighting the selected line.
public enum LineSelectionDisplayType {
    /// Do not highlight the selected line.
    case disabled
    /// Highlight the entire selected line.
    case line
    /// Only highlight the selected line fragment. A line may span multiple line fragments if line wrapping is enabled.
    case lineFragment
}

extension LineSelectionDisplayType {
    var shouldShowLineSelection: Bool {
        switch self {
        case .disabled:
            false
        case .line, .lineFragment:
            true
        }
    }
}
