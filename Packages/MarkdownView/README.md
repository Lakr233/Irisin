# MarkdownView

The markdown a depiction writes, drawn by `DepictionMarkdownView`. Vendored
from [Lakr233/MarkdownView](https://github.com/Lakr233/MarkdownView) 4.7.0
(`Sources/MarkdownView` and `Sources/MarkdownParser`; MIT, `LICENSE`) and cut
down to what a depiction uses. Upstream draws math through SwiftMath, which
brings fourteen OpenType math fonts (7 MB), and colours code with a lexer of
its own and a grammar per language. A package's description needs neither.

## What changed from upstream

- **No math.** The parser no longer rewrites `$…$` and `$$…$$` into
  placeholders before cmark reads the text, so a dollar sign is a dollar sign.
  `MarkdownInlineNode.math`, `ParseResult.mathContext`, `MathRenderer`, the
  tap-to-preview sheet and the rendered-image map on `MarkdownContent`
  (`rendered`, `RenderedTextContent`) are gone.
- **No highlighting.** A code block keeps its view, line numbers, its bar
  (Copy, Expand) and its sheet, and draws its text in the theme's code font
  and colour (`CodeViewConfiguration.attributedCode`). `CodeHighlighter`, its
  notification, `MarkdownContent.highlightMaps`, `MarkdownTheme.syntax`,
  `MarkdownTheme+Code.swift` and `Components/CodeView/Syntax/` are gone.
- **UIKit alone.** Every `#if` is resolved for iOS and removed: the AppKit
  branches, the macOS-only `HorizontalScrollView`, the visionOS and
  NaturalLanguage checks, and the `Platform*` type aliases, which are now the
  UIKit types they named.
- **Only the two library targets.** The watchOS view, the benchmark, the
  catalog app, the tests and the example app were not copied.
- **No string catalog.** The labels of the code and table bars and sheets
  ("Copy", "Download", "Expand", "Table", ...) are `String(localized:)` with
  no bundle, so they resolve against the app's `Localizable.xcstrings`, where
  they are `manual` keys. Upstream's catalog, with its `bundle: .module`, was
  not copied.

## Updating

Apply the cuts to both upstream versions first, then merge: resolve every
`#if` for iOS and spell the `Platform*` aliases as UIKit types in the old
tag and the new one, format both with the repository's `.swiftformat`, and
three-way merge each file (`git merge-file` with this tree as ours, the old
tag as base). What is left in conflict is math or highlighting, and new
files that need either are left out.
