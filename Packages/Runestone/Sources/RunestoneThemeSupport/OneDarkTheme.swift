import Runestone
import UIKit

/// One Dark, from Runestone's example themes.
public final class OneDarkTheme: EditorTheme {
    private enum Palette {
        static let aqua = UIColor(rgb: 0x56B6C2)
        static let background = UIColor(rgb: 0x282C34)
        static let blue = UIColor(rgb: 0x61AFEF)
        static let comment = UIColor(rgb: 0x787D87)
        static let currentLine = UIColor(rgb: 0x363941)
        static let foreground = UIColor(rgb: 0xABB2BF)
        static let green = UIColor(rgb: 0x98C379)
        static let purple = UIColor(rgb: 0xC678DD)
        static let red = UIColor(rgb: 0xE06C75)
        static let yellow = UIColor(rgb: 0xE5C07B)
    }

    public let backgroundColor = Palette.background
    public let userInterfaceStyle: UIUserInterfaceStyle = .dark

    public let font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    public let textColor = Palette.foreground

    public let gutterBackgroundColor = Palette.currentLine
    public let gutterHairlineColor: UIColor = .opaqueSeparator

    public let lineNumberColor = Palette.foreground.withAlphaComponent(0.5)
    public let lineNumberFont: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)

    public let selectedLineBackgroundColor = Palette.currentLine
    public let selectedLinesLineNumberColor = Palette.foreground
    public let selectedLinesGutterBackgroundColor: UIColor = .clear

    public let invisibleCharactersColor = Palette.foreground.withAlphaComponent(0.7)

    public let pageGuideHairlineColor = Palette.foreground
    public let pageGuideBackgroundColor = Palette.currentLine

    public let markedTextBackgroundColor = Palette.foreground.withAlphaComponent(0.1)
    public let markedTextBackgroundCornerRadius: CGFloat = 4

    public init() {}

    public func textColor(for rawHighlightName: String) -> UIColor? {
        guard let highlightName = HighlightName(rawHighlightName) else {
            return nil
        }
        switch highlightName {
        case .comment:
            return Palette.comment
        case .operator, .punctuation:
            return Palette.foreground.withAlphaComponent(0.75)
        case .property:
            return Palette.aqua
        case .function:
            return Palette.blue
        case .string:
            return Palette.green
        case .number:
            return Palette.yellow
        case .keyword:
            return Palette.purple
        case .variableBuiltin:
            return Palette.red
        }
    }

    public func fontTraits(for rawHighlightName: String) -> FontTraits {
        HighlightName(rawHighlightName) == .keyword ? .bold : []
    }
}
