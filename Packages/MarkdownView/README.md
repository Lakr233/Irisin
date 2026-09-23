# MarkdownView

The markdown a depiction writes, drawn by `DepictionMarkdownView`. Vendored
from [Lakr233/MarkdownView](https://github.com/Lakr233/MarkdownView) 4.3.2
(`Sources/MarkdownView` and `Sources/MarkdownParser`; MIT, `LICENSE`) and cut
down to what a depiction uses. Upstream drew math through SwiftMath, which
brings fourteen OpenType math fonts (7 MB), and coloured code through
Highlightr, which brings highlight.js and 270 stylesheets (2 MB). A package's
description has neither.

## What changed from upstream

- **No math.** The parser no longer rewrites `$…$` and `$$…$$` into
  placeholders before cmark reads the text, so a dollar sign is a dollar sign.
  `MarkdownInlineNode.math`, `ParseResult.mathContext`, `MathRenderer`, the
  tap-to-preview sheet and the rendered-image map on `MarkdownContent`
  (`rendered`, `RenderedTextContent`) are gone.
- **No highlighting.** A code block keeps its view, line numbers and Copy
  button, and draws its text in the theme's code font and colour
  (`CodeViewConfiguration.attributedCode`). `CodeHighlighter`, its
  notification, `MarkdownContent.highlightMaps` and
  `MarkdownTheme.codeHighlightTheme` are gone.
- **UIKit alone.** Every `#if` is resolved for iOS and removed: the AppKit
  branches, the macOS-only `HorizontalScrollView`, the visionOS and
  NaturalLanguage checks, and the `Platform*` type aliases, which are now the
  UIKit types they named.
- **Only the two library targets.** The watchOS view, the benchmark, the
  tests, the example app and the empty string catalog were not copied.
