import CoreGraphics
import Foundation
@testable import irisin
import Testing
import UIKit

// Expected values come from the JS reference (kumailnanji/letters e4ba2d1, framer-motion 12.38):
// layoutTextSegmented + computeRenderItems + computeItemOffsets(progress 0.5, overlap 0.02).
// Rows: start, end, path bounding box (minX, minY, maxX, maxY), dash offset at 0.5.
private let reference: [(text: String, variant: ScribbleVariant, bounds: CGRect, items: [[Double]])] = [
    ("hi 2u", .simple, CGRect(x: 0, y: -12, width: 68, height: 21), [
        [0, 0.1154, 0, -12, 10.5999, 9, 0],
        [0.1154, 0.1251, -0.25, 9, 0, 11, 0],
        [0.1251, 0.209, 0, -0.4509, 15, 9.8752, 0],
        [0.209, 0.2833, 14.0969, -0.4838, 22, 9.2642, 0],
        [0.2833, 0.2848, 17.3, -6.4, 20.5, -3.2, 0],
        [0.2848, 0.4526, 22, -12.25, 50.25, 9.25, 0],
        [0.4526, 0.5858, 33, -12.25, 50.25, 9, 0.5846],
        [0.5858, 0.6565, 33, -12, 46, 9, 1],
        [0.6565, 0.7102, 40, -17, 49.75, 1, 1],
        [0.7102, 0.7345, 34, 1, 40, 7, 1],
        [0.7345, 0.7811, 32.75, 5, 48, 8.5, 1],
        [0.7811, 0.8128, 37, 4.75, 48, 6, 1],
        [0.8128, 0.8535, 35.5, 5, 48, 9.75, 1],
        [0.8535, 0.8902, 52.5, -0.5, 62, 9.25, 1],
        [0.8902, 0.8965, 62, -0.75, 63.25, 3, 1],
        [0.8965, 0.9254, 60.5, 0, 68, 9.25, 1],
        [0.9254, 0.9685, 50.0671, 0, 61.9482, 10.4837, 1],
        [0.9685, 0.9734, 61.8231, -0.1545, 63.0936, 3.3683, 1],
        [0.9734, 1, 60.1902, 0, 68, 9.4788, 1],
    ]),
    ("zq", .complex, CGRect(x: 0, y: 0, width: 29, height: 21), [
        [0, 0.4017, -3.3746, -0.9186, 14.0028, 23.5221, 0],
        [0.4017, 0.5798, 12.2349, -1.2843, 22, 9.74, 0.4147],
        [0.5798, 0.6354, 20, 0, 23, 8, 1],
        [0.6354, 1, 15.391, -1.25, 28, 22.0221, 1],
    ]),
]

@Test func layoutMatchesJavaScriptReference() {
    for (text, variant, bounds, expected) in reference {
        let layout = ScribbleLayout(text: text, variant: variant, tension: 4)
        #expect(layout.bounds == bounds, "\(text)")
        #expect(layout.items.count == expected.count, "\(text)")
        for (item, row) in zip(layout.items, expected) {
            let box = item.dot.map {
                CGRect(x: $0.center.x - $0.radius, y: $0.center.y - $0.radius, width: $0.radius * 2, height: $0.radius * 2)
            } ?? item.path.boundingBox
            let actual = [item.start, item.end, box.minX, box.minY, box.maxX, box.maxY, item.dashOffset(progress: 0.5, overlap: 0.02)]
            // JS path data is rounded to 2 decimals, reference rows to 4.
            #expect(zip(actual, row).allSatisfy { abs($0 - $1) < 0.011 }, "\(text): \(actual) vs \(row)")
        }
    }
}

@Test func unsupportedTextIsEmpty() {
    #expect(ScribbleLayout(text: " \u{1F600} ", variant: .simple, tension: 4).items.isEmpty)
    // A combining mark is skipped; its base letter still draws.
    let decomposed = ScribbleLayout(text: "cafe\u{301}", variant: .simple, tension: 4)
    #expect(decomposed.items.count == ScribbleLayout(text: "cafe", variant: .simple, tension: 4).items.count)
}

@Test func fullProgressDrawsEveryItem() {
    for overlap in [0, 0.02, 0.5] {
        let items = ScribbleLayout(text: "a", variant: .simple, tension: 4).items
        #expect(items.allSatisfy { $0.dashOffset(progress: 1, overlap: overlap) == 0 }, "overlap \(overlap)")
    }
}

@Test func tensionBelowOneActsAsOne() {
    func boxes(_ tension: Double) -> [CGRect] {
        ScribbleLayout(text: "H2", variant: .simple, tension: tension).items.map(\.path.boundingBox)
    }
    #expect(boxes(0) == boxes(1))
}

@Test func timingMatchesFramerMotion() {
    let tween = ScribbleTiming.tween(duration: 2)
    // framer-motion stops bisecting after 12 steps, so its easeInOut(0.25) = 0.1289 is ~3e-4 off.
    #expect(abs(tween.sample(from: 0, to: 1, elapsed: 0.5).value - 0.1289) < 0.0005)
    #expect(tween.sample(from: 1, to: 0, elapsed: 2) == (0, true))
    #expect(ScribbleTiming.tween(curve: .linear).sample(from: 0, to: 1, elapsed: 2) == (1, true))

    let spring = ScribbleTiming.spring(.bouncy)
    #expect(abs(spring.sample(from: 0, to: 1, elapsed: 0.3).value - 1.1763) < 0.0001)
    let settle = (0 ... 2000).first { spring.sample(from: 0, to: 1, elapsed: Double($0) / 1000).isFinished }
    #expect(settle == 965)

    // Damping ratio 10: still well short of the target after 3 s.
    let overdamped = ScribbleTiming.spring(.init(damping: 200)).sample(from: 0, to: 1, elapsed: 3)
    #expect(abs(overdamped.value - 0.7771) < 0.0001 && !overdamped.isFinished)
    #expect(ScribbleTiming.spring(.init(stiffness: 0)).sample(from: 0, to: 1, elapsed: 0) == (1, true))
}

@Test func svgPathParsing() {
    let parsed = svgPath("M 0 0 L 3 4 C 3 4, 3 4, 3 4 Z", transform: CGAffineTransform(translationX: 10, y: 0))
    #expect(parsed.estimatedLength == 5)
    #expect(parsed.path.boundingBox == CGRect(x: 10, y: 0, width: 3, height: 4))
}

@MainActor
@Test func rendersInkOnlyWhenDrawn() {
    let view = ScribbleLetterView(text: "hello")
    view.frame.size = view.sizeThatFits(CGSize(width: 0, height: 80))
    #expect(abs(view.frame.width / view.frame.height - view.intrinsicContentSize.width / view.intrinsicContentSize.height) < 0.001)

    func inkCoverage() -> Double {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { view.layer.render(in: $0.cgContext) }
        let data = image.cgImage!.dataProvider!.data! as Data
        let alphas = stride(from: 3, to: data.count, by: 4).map { data[$0] }
        return Double(alphas.filter { $0 > 0 }.count) / Double(alphas.count)
    }

    view.progress = 0
    #expect(inkCoverage() == 0)
    view.progress = 1
    #expect(inkCoverage() > 0.05)
}

@MainActor
@Test func playbackRunsToCompletion() async {
    let view = ScribbleLetterView(text: "hi")
    // Playback only ticks on screen.
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    window.addSubview(view)
    view.timing = .tween(duration: 0.1)
    var playing: [Bool] = []
    var completions = 0
    view.onPlayingChange = { playing.append($0) }
    view.onComplete = { completions += 1 }
    view.play()
    #expect(view.progress == 0)
    try? await Task.sleep(nanoseconds: 500_000_000)
    #expect(view.progress == 1)
    #expect(playing == [true, false])
    #expect(completions == 1)
    withExtendedLifetime(window) {}
}
