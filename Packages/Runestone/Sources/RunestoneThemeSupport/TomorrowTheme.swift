import Runestone
import UIKit

/// Tomorrow, from Runestone's example themes; the light palette only.
public final class TomorrowTheme: EditorTheme {
    private enum Palette {
        static let aqua = UIColor(rgb: 0x3E999F)
        static let background = UIColor(rgb: 0xFFFFFF)
        static let blue = UIColor(rgb: 0x4271AE)
        static let comment = UIColor(rgb: 0x8E908C)
        static let currentLine = UIColor(rgb: 0xEFEFEF)
        static let foreground = UIColor(rgb: 0x4D4D4C)
        static let green = UIColor(rgb: 0x718C00)
        static let orange = UIColor(rgb: 0xF5871F)
        static let purple = UIColor(rgb: 0x8959A8)
        static let red = UIColor(rgb: 0xC82829)
    }

    public let backgroundColor = Palette.background
    public let userInterfaceStyle: UIUserInterfaceStyle = .light

    public let font: UIFont
    public let textColor = Palette.foreground

    public let gutterBackgroundColor = Palette.currentLine
    public let gutterHairlineColor = Palette.comment

    public let lineNumberColor = Palette.foreground.withAlphaComponent(0.5)
    public let lineNumberFont: UIFont

    public let selectedLineBackgroundColor = Palette.currentLine
    public let selectedLinesLineNumberColor = Palette.foreground
    public let selectedLinesGutterBackgroundColor: UIColor = .clear

    public let invisibleCharactersColor = Palette.foreground.withAlphaComponent(0.25)

    public let pageGuideHairlineColor = Palette.foreground
    public let pageGuideBackgroundColor = Palette.currentLine

    public let markedTextBackgroundColor = Palette.foreground.withAlphaComponent(0.1)
    public let markedTextBackgroundCornerRadius: CGFloat = 4

    public init(size: CGFloat = 14) {
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: size, weight: .regular)
    }

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
            return Palette.orange
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
