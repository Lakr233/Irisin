//
//  ScribbleLayout.swift
//  Irisin
//
//  Swift port of kumailnanji/letters: Hershey script fonts supply kerning and
//  stroke order, hand-tuned Bézier glyphs replace a–z. Glyph data lives in
//  the GlyphData extensions, generated from the JS package's data files.
//
//  The handwritten name a package with no icon is drawn with
//  (PackageArtworkView). Moved into the app from
//  yellowplushq/ScribbleLetterView 0.1.1, ours, with ScribbleLetterView.swift
//  beside it and Glyphs/; its SwiftUI wrapper, unused here, was left behind.
//
//  MIT License
//
//  Copyright (c) 2026 Lakr233
//  Copyright (c) 2026 Kumail Nanji (original letters library: glyph data, layout and animation logic)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import CoreGraphics
import Foundation

nonisolated enum ScribbleVariant: String, Sendable {
    case simple
    case complex
}

/// framer-motion's tween and spring, reimplemented so the package runs on iOS 15.
nonisolated enum ScribbleTiming: Hashable, Sendable {
    case tween(duration: TimeInterval = 2, curve: Curve = .easeInOut)
    case spring(Spring)

    static let `default` = ScribbleTiming.tween()

    /// A CSS-style `cubic-bezier(x1, y1, x2, y2)` easing curve.
    struct Curve: Hashable, Sendable {
        var x1: Double
        var y1: Double
        var x2: Double
        var y2: Double

        init(x1: Double, y1: Double, x2: Double, y2: Double) {
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
        }

        static let linear = Curve(x1: 0, y1: 0, x2: 1, y2: 1)
        static let easeIn = Curve(x1: 0.42, y1: 0, x2: 1, y2: 1)
        static let easeOut = Curve(x1: 0, y1: 0, x2: 0.58, y2: 1)
        static let easeInOut = Curve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

        func value(at x: Double) -> Double {
            func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
                ((1 + 3 * p1 - 3 * p2) * t + (3 * p2 - 6 * p1)) * t * t + 3 * p1 * t
            }
            // Bisection: x(t) is monotonic when x1 and x2 are in 0...1.
            var low = 0.0
            var high = 1.0
            for _ in 0 ..< 30 {
                let mid = (low + high) / 2
                if bezier(mid, x1, x2) < x {
                    low = mid
                } else {
                    high = mid
                }
            }
            return bezier((low + high) / 2, y1, y2)
        }
    }

    struct Spring: Hashable, Sendable {
        var stiffness: Double
        var damping: Double
        var mass: Double

        init(stiffness: Double = 100, damping: Double = 10, mass: Double = 1) {
            self.stiffness = stiffness
            self.damping = damping
            self.mass = mass
        }

        static let gentle = Spring(stiffness: 100, damping: 20, mass: 1)
        static let snappy = Spring(stiffness: 300, damping: 30, mass: 0.8)
        static let bouncy = Spring(stiffness: 200, damping: 12, mass: 1)
        static let smooth = Spring(stiffness: 150, damping: 40, mass: 1.2)

        /// Position of a spring released at rest from 0 toward 1, `t` seconds in.
        func value(at t: Double) -> Double {
            let omega = (stiffness / mass).squareRoot()
            let zeta = damping / (2 * (stiffness * mass).squareRoot()) // damping ratio
            if zeta < 1 {
                let damped = omega * (1 - zeta * zeta).squareRoot()
                return 1 - exp(-zeta * omega * t) * (zeta * omega / damped * sin(damped * t) + cos(damped * t))
            }
            if zeta == 1 {
                return 1 - exp(-omega * t) * (1 + omega * t)
            }
            // Overdamped: a slow and a fast decay. The sinh/cosh form overflows for large t.
            let root = zeta + (zeta * zeta - 1).squareRoot()
            let slow = omega / root
            let fast = omega * root
            return 1 - (fast * exp(-slow * t) - slow * exp(-fast * t)) / (fast - slow)
        }
    }

    /// The animated value `elapsed` seconds into an animation from `from` to `to`.
    func sample(from: Double, to: Double, elapsed: TimeInterval) -> (value: Double, isFinished: Bool) {
        switch self {
        case let .tween(duration, curve):
            let t = duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
            // The bisected curve lands a hair short of 1, which would leave play() resuming instead of redrawing.
            guard t < 1 else { return (to, true) }
            return (from + (to - from) * curve.value(at: t), false)
        case let .spring(spring):
            let delta = to - from
            let value = from + delta * spring.value(at: elapsed)
            // Zero or negative stiffness or mass has no motion to animate.
            guard value.isFinite else { return (to, true) }
            let h = 1e-4
            let before = max(elapsed - h, 0)
            let velocity = delta * (spring.value(at: elapsed + h) - spring.value(at: before)) / (elapsed + h - before)
            // framer-motion's rest thresholds for deltas under 5 units, in units and units per second.
            let settled = abs(to - value) <= 0.005 && abs(velocity) <= 0.01
            return (settled ? to : value, settled)
        }
    }

    /// Un-writing from fully drawn back to 0 takes half the forward duration.
    var rewinding: ScribbleTiming {
        guard case let .tween(duration, curve) = self else { return self }
        return .tween(duration: max(0.05, duration / 2), curve: curve)
    }
}

nonisolated struct ScribbleLayout {
    struct Dot {
        var center: CGPoint
        var radius: CGFloat
    }

    struct Item {
        var path: CGPath
        var dot: Dot?
        /// Slice of the 0–1 timeline this item draws in.
        var start: Double
        var end: Double

        /// SVG `stroke-dashoffset` on a unit-length path: 1 hides the item, 0 shows all of it.
        func dashOffset(progress: Double, overlap: Double) -> Double {
            let adjustedStart = start * (1 - overlap)
            // Capped so every item is fully drawn by progress 1; the reference formula overshoots early items.
            let span = min((end - start) * (1 + overlap), 1 - adjustedStart)
            if progress <= adjustedStart {
                return 1
            }
            if progress >= adjustedStart + span {
                return 0
            }
            return 1 - (progress - adjustedStart) / span
        }
    }

    var items: [Item] = []
    /// Glyph extent in font units, before stroke padding.
    var bounds: CGRect = .zero

    /// `tension` below 1 is treated as 1: control points divide by it.
    init(text: String, variant: ScribbleVariant, tension: Double) {
        let font = variant == .simple ? GlyphData.simple : GlyphData.complex
        let tension = tension >= 1 ? tension : 1

        struct Stroke {
            var points: [CGPoint]
            var length: Double
            var isDetail: Bool {
                length < 2.5 || (points.count <= 5 && length < 5)
            }
        }
        var letters: [(char: String, originX: Double, strokes: [Stroke])] = []
        var cursorX = 0.0
        var minY = Double.infinity
        var maxY = -Double.infinity

        // Code points, like the JS for...of: a combining mark is skipped instead of hiding its base letter.
        for scalar in text.unicodeScalars {
            if scalar == " " {
                cursorX += 10
                continue
            }
            let char = String(scalar)
            guard let glyph = font[char] else { continue }
            let offsetX = cursorX - glyph.left
            let strokes = glyph.strokes.map { raw in
                let points = raw.map { CGPoint(x: $0.x + offsetX, y: $0.y) }
                let length = polylineLength(points)
                for point in points {
                    minY = min(minY, point.y)
                    maxY = max(maxY, point.y)
                }
                return Stroke(points: points, length: length)
            }
            letters.append((char, cursorX, strokes))
            cursorX += glyph.right - glyph.left
        }

        // Hershey segments: bodies and connections in writing order, then dots and ticks.
        typealias Segment = (path: CGPath, length: Double, position: Int)
        var bodies: [Segment] = []
        var details: [Segment] = []
        var previous: (last: CGPoint, secondLast: CGPoint?)?
        for (position, letter) in letters.enumerated() {
            var isFirstBody = true
            for stroke in letter.strokes {
                let points = stroke.points
                if stroke.isDetail {
                    details.append((catmullRom(points, tension), stroke.length, position))
                    continue
                }
                if let previous, isFirstBody {
                    if let entry = letterEntry(points, after: previous.last, previous.secondLast, tension) {
                        bodies.append((entry.path, entry.length, position))
                    }
                    bodies.append((catmullRom(points, tension), stroke.length, position))
                } else if let previous {
                    let context = [previous.secondLast, previous.last].compactMap(\.self)
                    let all = context + points
                    let gap = hypot(points[0].x - previous.last.x, points[0].y - previous.last.y)
                    bodies.append((
                        catmullRom(all, tension, from: context.count - 1, to: context.count),
                        max(gap, 0.5),
                        position
                    ))
                    bodies.append((catmullRom(all, tension, from: context.count), stroke.length, position))
                } else {
                    bodies.append((catmullRom(points, tension), stroke.length, position))
                }
                isFirstBody = false
                previous = (points[points.count - 1], points.count >= 2 ? points[points.count - 2] : nil)
            }
        }
        let segments = bodies + details

        // Hershey lengths set each letter's share of the timeline; custom glyphs split their share by path weight.
        var order: [Int] = []
        for segment in segments where !order.contains(segment.position) {
            order.append(segment.position)
        }
        let groups = Dictionary(grouping: segments, by: \.position)
        let totalLength = segments.reduce(0) { $0 + $1.length }
        guard totalLength > 0 else { return }

        var cursor = 0.0
        for position in order {
            let group = groups[position] ?? []
            let letterLength = group.reduce(0) { $0 + $1.length }
            let share = letterLength / totalLength
            let letter = letters[position]

            let parts: [(path: CGPath, dot: Dot?, weight: Double)]
            if let custom = GlyphData.custom[letter.char], !custom.isEmpty {
                let shift = CGAffineTransform(translationX: letter.originX, y: 0)
                parts = custom.map { path in
                    let parsed = svgPath(path.d, transform: shift)
                    let dot = path.dot.map { Dot(center: CGPoint(x: $0.cx + letter.originX, y: $0.cy), radius: $0.r) }
                    let weight = dot != nil ? 0.5 : path.drawWeight.map { max($0, 0.1) } ?? max(parsed.estimatedLength, 0.5)
                    return (parsed.path, dot, weight)
                }
            } else {
                parts = group.map { ($0.path, nil, $0.length) }
            }

            let weightSum = parts.reduce(0) { $0 + $1.weight }
            var start = cursor
            for part in parts {
                // A letter with no length has no share to split.
                let end = start + (weightSum > 0 ? part.weight / weightSum * share : 0)
                items.append(Item(path: part.path, dot: part.dot, start: start, end: end))
                start = end
            }
            cursor += share
        }

        bounds = CGRect(x: 0, y: minY, width: cursorX, height: maxY - minY)
    }
}

// MARK: - Geometry

private nonisolated func polylineLength(_ points: [CGPoint]) -> Double {
    zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
}

/// Moves to `points[start]` and adds a Catmull-Rom curve for each span up to `points[end]`,
/// taking tangents from the neighbouring points, including those before `start`.
private nonisolated func catmullRom(_ points: [CGPoint], _ tension: Double, from start: Int = 0, to end: Int? = nil) -> CGPath {
    let path = CGMutablePath()
    guard points.indices.contains(start) else { return path }
    path.move(to: points[start])
    guard points.count > 2 else {
        // No neighbours to take tangents from: a straight line, as in the reference.
        if start == 0, points.count == 2 {
            path.addLine(to: points[1])
        }
        return path
    }
    let last = points.count - 1
    for i in start ..< (end ?? last) {
        let p0 = points[max(i - 1, 0)]
        let p1 = points[i]
        let p2 = points[i + 1]
        let p3 = points[min(i + 2, last)]
        path.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x + (p2.x - p0.x) / tension, y: p1.y + (p2.y - p0.y) / tension),
            control2: CGPoint(x: p2.x - (p3.x - p1.x) / tension, y: p2.y - (p3.y - p1.y) / tension)
        )
    }
    return path
}

/// Joins the previous letter's exit to its nearest point on `points`, then runs back along the stroke to its start.
private nonisolated func letterEntry(
    _ points: [CGPoint],
    after last: CGPoint,
    _ secondLast: CGPoint?,
    _ tension: Double
) -> (path: CGPath, length: Double)? {
    func distanceSquared(_ p: CGPoint) -> CGFloat {
        (p.x - last.x) * (p.x - last.x) + (p.y - last.y) * (p.y - last.y)
    }
    guard let closest = points.indices.min(by: { distanceSquared(points[$0]) < distanceSquared(points[$1]) }) else { return nil }
    let isSamePoint = abs(last.x - points[closest].x) < 0.5 && abs(last.y - points[closest].y) < 0.5
    let connection = (isSamePoint ? [] : [last]) + points[...closest].reversed()
    guard connection.count > 1 else { return nil }
    let context = isSamePoint ? [] : [secondLast].compactMap(\.self)
    return (catmullRom(context + connection, tension, from: context.count), max(polylineLength(connection), 0.5))
}

/// Parses the absolute `M` / `L` / `C` / `Z` subset of SVG path data used by the glyphs.
/// `estimatedLength` is the reference implementation's crude weight: a polyline through every
/// coordinate pair, control points included.
nonisolated func svgPath(_ d: String, transform: CGAffineTransform = .identity) -> (path: CGPath, estimatedLength: Double) {
    let path = CGMutablePath()
    var coordinates: [CGPoint] = []
    var command = "M"
    var pending: [Double] = []
    for token in d.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
        guard let number = Double(token) else {
            command = String(token)
            pending = []
            if command == "Z" {
                path.closeSubpath()
            }
            continue
        }
        pending.append(number)
        guard pending.count.isMultiple(of: 2) else { continue }
        let point = CGPoint(x: pending[pending.count - 2], y: pending[pending.count - 1])
        coordinates.append(point)
        switch (command, pending.count) {
        case ("M", 2):
            path.move(to: point, transform: transform)
            command = "L" // Extra pairs after M are implicit line-tos.
            pending = []
        case ("L", 2):
            path.addLine(to: point, transform: transform)
            pending = []
        case ("C", 6):
            let c = Array(coordinates.suffix(3))
            path.addCurve(to: c[2], control1: c[0], control2: c[1], transform: transform)
            pending = []
        default:
            break
        }
    }
    return (path, polylineLength(coordinates))
}
