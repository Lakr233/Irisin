//
//  ScribbleLetterView.swift
//  Irisin
//

import UIKit

/// Writes `text` out as continuous handwriting. Supports lowercase a–z with hand-tuned glyphs;
/// other Hershey characters fall back to smoothed font strokes, and unknown characters are skipped.
final class ScribbleLetterView: UIView {
    var text: String {
        didSet {
            if text != oldValue {
                rebuild()
            }
        }
    }

    var variant: ScribbleVariant = .simple {
        didSet {
            if variant != oldValue {
                rebuild()
            }
        }
    }

    /// Catmull-Rom tension for fallback glyphs. Higher values give tighter curves; values below 1 act as 1.
    var tension: Double = 4 {
        didSet {
            if tension != oldValue {
                rebuild()
            }
        }
    }

    /// Stroke width in font units. Scales with the view like the glyphs do.
    var strokeWidth: CGFloat = 2 {
        didSet {
            guard strokeWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var color: UIColor = .label {
        didSet {
            if color != oldValue {
                applyColor()
            }
        }
    }

    /// How much adjacent paths blend into each other while drawing, from 0 to 0.5.
    var overlap: Double = 0.02 {
        didSet {
            if overlap != oldValue {
                renderProgress()
            }
        }
    }

    var timing: ScribbleTiming = .default

    /// Cycles forever: draw, wait `loopPause`, un-write at half duration, draw again.
    var loops = false

    /// When `play()` or `replay()` starts from a fully drawn state, un-write to 0 before drawing.
    var rewindsBeforePlay = false

    /// Seconds to hold the drawn text before a loop un-writes it. `.infinity` holds it until playback stops.
    var loopPause: TimeInterval = 0

    /// Called at the end of every forward draw, including each loop iteration.
    var onComplete: (() -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    /// Called on every playback frame.
    var onProgressChange: ((Double) -> Void)?

    private(set) var isPlaying = false

    /// 0 hides the text and 1 shows all of it; NaN counts as 0. Setting it stops playback, like a scrubber;
    /// it doesn't call `onProgressChange`.
    var progress: Double {
        get { currentProgress }
        set {
            pause()
            currentProgress = Self.clamped(newValue)
            renderProgress()
        }
    }

    private var currentProgress: Double = 1
    private var layout = ScribbleLayout(text: "", variant: .simple, tension: 4)
    private var shapeLayers: [CAShapeLayer] = []
    private var drawTransform = CGAffineTransform.identity
    private var displayLink: CADisplayLink?
    private var animation: ActiveAnimation?
    /// Bumped whenever playback starts or stops. Callbacks can do either, so every step after one
    /// re-checks it, as do loop continuations.
    private var playbackID = 0

    init(text: String = "") {
        self.text = text
        super.init(frame: .zero)
        // Decorative like UILabel: touches go to whatever is behind it.
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        #if os(tvOS)
            // tvOS starts at 17, where `traitCollectionDidChange` is deprecated.
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _: UITraitCollection) in
                view.applyColor()
            }
        #endif
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Playback

    /// Resumes from the current progress, or draws from the start when fully drawn.
    func play() {
        runPlayback(from: currentProgress, looping: false)
    }

    func pause() {
        playbackID += 1
        animation = nil
        displayLink?.invalidate()
        displayLink = nil
        setPlaying(false)
    }

    /// Draws from the start. Only a fully drawn view un-writes first, and only with `rewindsBeforePlay`.
    func replay() {
        runPlayback(from: currentProgress >= 1 ? 1 : 0, looping: false)
    }

    /// Stops playback and shows the full text.
    func reset() {
        pause()
        setProgress(1)
    }

    private func runPlayback(from start: Double, looping: Bool) {
        playbackID += 1
        let id = playbackID
        setPlaying(true)
        guard id == playbackID else { return }

        let rewinds = start >= 1 && (looping || rewindsBeforePlay)
        guard rewinds else { return drawForward(from: start >= 1 ? 0 : start, id: id) }
        setProgress(1)
        guard id == playbackID else { return }
        animate(to: 0, timing: timing.rewinding) { [weak self] in
            self?.drawForward(from: 0, id: id)
        }
    }

    private func drawForward(from start: Double, id: Int) {
        setProgress(start)
        guard id == playbackID else { return }
        animate(to: 1, timing: timing) { [weak self] in
            self?.finishForward(id: id)
        }
    }

    private func finishForward(id: Int) {
        onComplete?()
        guard id == playbackID else { return }
        guard loops, loopPause > 0 else { return continueLoop() }
        guard loopPause.isFinite else { return }
        Task { [weak self, loopPause] in
            // Capped at about 31 years so the nanosecond count fits in UInt64.
            try? await Task.sleep(nanoseconds: UInt64(min(loopPause, 1e9) * 1e9))
            guard let self, id == playbackID else { return }
            continueLoop()
        }
    }

    /// Un-writes and draws again, unless `loops` is off, including when it was turned off during the pause.
    private func continueLoop() {
        guard loops else { return setPlaying(false) }
        runPlayback(from: 1, looping: true)
    }

    private func setPlaying(_ value: Bool) {
        guard isPlaying != value else { return }
        isPlaying = value
        onPlayingChange?(value)
    }

    private func setProgress(_ value: Double) {
        currentProgress = Self.clamped(value)
        renderProgress()
        onProgressChange?(currentProgress)
    }

    private static func clamped(_ progress: Double) -> Double {
        progress.isNaN ? 0 : min(max(progress, 0), 1)
    }

    private final class ActiveAnimation {
        let from: Double
        let to: Double
        let timing: ScribbleTiming
        let completion: () -> Void
        /// Accumulated per frame, so time spent off screen doesn't count.
        var elapsed: TimeInterval = 0
        var lastTimestamp: CFTimeInterval?

        init(from: Double, to: Double, timing: ScribbleTiming, completion: @escaping () -> Void) {
            self.from = from
            self.to = to
            self.timing = timing
            self.completion = completion
        }
    }

    /// Replaces any running animation. The old one never completes.
    private func animate(to target: Double, timing: ScribbleTiming, completion: @escaping () -> Void) {
        animation = ActiveAnimation(from: currentProgress, to: target, timing: timing, completion: completion)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayLinkTarget(view: self), selector: #selector(DisplayLinkTarget.tick))
        link.isPaused = window == nil
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Off screen, playback holds where it is instead of ticking and calling back every frame.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.isPaused = window == nil
        animation?.lastTimestamp = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let animation else { return pause() }
        let now = link.targetTimestamp
        animation.elapsed += now - (animation.lastTimestamp ?? now)
        animation.lastTimestamp = now
        let sample = animation.timing.sample(from: animation.from, to: animation.to, elapsed: animation.elapsed)
        setProgress(sample.value)
        // onProgressChange may have replaced or stopped this animation.
        guard sample.isFinished, self.animation === animation else { return }
        self.animation = nil
        animation.completion()
        guard self.animation == nil, let displayLink else { return }
        displayLink.invalidate()
        self.displayLink = nil
    }

    // MARK: Rendering

    /// The SVG viewBox: glyph bounds padded so round caps aren't clipped.
    private var viewBox: CGRect {
        layout.bounds.insetBy(dx: -(strokeWidth + 8), dy: -(strokeWidth + 8))
    }

    override var intrinsicContentSize: CGSize {
        layout.items.isEmpty ? .zero : viewBox.size
    }

    /// Aspect-fits the text into `size`. A zero or infinite dimension is unconstrained.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let natural = intrinsicContentSize
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let scale = min(
            size.width > 0 ? size.width / natural.width : .infinity,
            size.height > 0 ? size.height / natural.height : .infinity
        )
        guard scale.isFinite else { return natural }
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    private func rebuild() {
        layout = ScribbleLayout(text: text, variant: variant, tension: tension)
        shapeLayers.forEach { $0.removeFromSuperlayer() }
        shapeLayers = layout.items.map { _ in
            let shape = CAShapeLayer()
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
            return shape
        }
        accessibilityLabel = text
        applyColor()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = viewBox
        guard !layout.items.isEmpty, box.width > 0, box.height > 0 else { return }
        // Aspect-fit and center, like SVG's default preserveAspectRatio.
        let scale = min(bounds.width / box.width, bounds.height / box.height)
        drawTransform = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (item, shape) in zip(layout.items, shapeLayers) {
            shape.frame = bounds
            shape.lineWidth = strokeWidth * scale
            if item.dot == nil {
                shape.path = item.path.copy(using: &drawTransform)
            }
        }
        CATransaction.commit()
        renderProgress()
    }

    private func renderProgress() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (item, shape) in zip(layout.items, shapeLayers) {
            let offset = item.dashOffset(progress: currentProgress, overlap: overlap)
            if let dot = item.dot {
                // Dots pop in with an ease-out scale instead of being stroked.
                let t = 1 - offset
                let scale = t * (2 - t)
                let radius = dot.radius * scale
                let rect = CGRect(
                    x: dot.center.x - radius,
                    y: dot.center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                shape.isHidden = offset >= 1
                shape.path = CGPath(ellipseIn: rect, transform: &drawTransform)
                shape.opacity = Float(scale)
            } else {
                shape.isHidden = offset > 0.97
                shape.strokeEnd = 1 - offset
            }
        }
    }

    #if !os(tvOS)
        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
                applyColor()
            }
        }
    #endif

    private func applyColor() {
        let resolved = color.resolvedColor(with: traitCollection).cgColor
        for (item, shape) in zip(layout.items, shapeLayers) {
            shape.fillColor = item.dot == nil ? nil : resolved
            shape.strokeColor = item.dot == nil ? resolved : nil
        }
    }
}

/// Holds the view weakly so a running display link doesn't keep it alive.
@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var view: ScribbleLetterView?

    init(view: ScribbleLetterView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
