//
//  GlyphData.swift
//  Irisin
//
//  Glyph tables ported from kumailnanji/letters. The data lives in the
//  GlyphData+Simple, GlyphData+Complex and GlyphData+Custom extensions.
//

nonisolated enum GlyphData {
    struct Glyph: Sendable {
        let left: Double
        let right: Double
        let strokes: [[(x: Double, y: Double)]]
    }

    struct Dot: Sendable {
        let cx: Double
        let cy: Double
        let r: Double
    }

    struct CustomPath: Sendable {
        /// SVG path data. Commands and coordinates may be separated by any whitespace.
        let d: String
        let dot: Dot?
        /// Overrides the path-length timeline weight, e.g. for the t crossbar.
        let drawWeight: Double?

        init(_ d: String, drawWeight: Double? = nil) {
            self.d = d
            dot = nil
            self.drawWeight = drawWeight
        }

        init(dot: Dot) {
            d = ""
            self.dot = dot
            drawWeight = nil
        }
    }
}
