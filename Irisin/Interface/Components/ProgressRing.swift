//
//  ProgressRing.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import UIKit

/// A small ring for one item's progress, the App Store's download ring
/// without the stop square: nothing here can be stopped, and a square in
/// the middle says it can. A thin track, a round-capped arc in the view's
/// tint that starts at twelve o'clock, a quarter arc going round while the
/// work cannot be measured, and a glyph in the ring's place once the item
/// has settled.
final class ProgressRing: UIView {
    enum Appearance: Equatable {
        /// The track alone: its turn has not come.
        case waiting
        case progress(Double)
        /// Work that cannot be counted, a script running: the arc keeps what
        /// was reached, never less than a quarter, and goes round.
        case working(Double)
        /// A dashed track: its turn never came.
        case skipped
        /// The ring gives way to a symbol in the view's tint.
        case glyph(String)
    }

    static let diameter: CGFloat = 26
    private static let lineWidth: CGFloat = 3

    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let glyph = UIImageView()
    private(set) var appearance = Appearance.waiting

    override init(frame: CGRect) {
        super.init(frame: frame)
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = Self.lineWidth
            self.layer.addSublayer(layer)
        }
        arc.lineCap = .round
        arc.strokeEnd = 0
        glyph.contentMode = .scaleAspectFit
        glyph.preferredSymbolConfiguration = .init(pointSize: Self.diameter - 4, weight: .semibold)
        glyph.alpha = 0
        addSubview(glyph)
        recolor()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.diameter, height: Self.diameter)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
        let inset = Self.lineWidth / 2
        // from twelve o'clock, clockwise
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: min(bounds.width, bounds.height) / 2 - inset,
            startAngle: -.pi / 2,
            endAngle: .pi * 3 / 2,
            clockwise: true
        ).cgPath
        for layer in [track, arc] {
            layer.frame = bounds
            layer.path = path
        }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        recolor()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        recolor()
    }

    /// A layer takes a colour resolved once; the view resolves it again
    /// whenever the tint or the appearance moves.
    private func recolor() {
        track.strokeColor = UIColor.progressTrack.resolvedColor(with: traitCollection).cgColor
        arc.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
        glyph.tintColor = tintColor
    }

    func set(_ next: Appearance, animated: Bool) {
        guard next != appearance else { return }
        let previous = appearance
        appearance = next

        var fraction: CGFloat = 0
        var showsRing = true
        var spins = false
        switch next {
        case .waiting, .skipped: break
        case let .progress(value): fraction = CGFloat(min(max(value, 0), 1))
        case let .working(value):
            // short of full, so the round cap still shows it going round
            fraction = CGFloat(min(max(value, 0.25), 0.9))
            spins = true
        case let .glyph(name):
            showsRing = false
            glyph.image = UIImage(systemName: name)
        }
        track.lineDashPattern = next == .skipped ? [2, 4] : nil

        // the arc moves like every other progress in the app; a new row's
        // first state just lands
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        arc.strokeEnd = fraction
        track.opacity = showsRing ? 1 : 0
        arc.opacity = showsRing ? 1 : 0
        CATransaction.commit()

        if spins {
            if arc.animation(forKey: "spin") == nil {
                arc.removeAnimation(forKey: "land")
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.byValue = CGFloat.pi * 2
                spin.duration = 1
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                arc.add(spin, forKey: "spin")
            }
        } else if arc.animation(forKey: "spin") != nil {
            // finish the turn it is on: a full turn is twelve o'clock again,
            // so the arc arrives where a counted one starts and never snaps
            let angle = (arc.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
            arc.removeAnimation(forKey: "spin")
            if animated {
                let target: CGFloat = angle > 0 ? .pi * 2 : 0
                let land = CABasicAnimation(keyPath: "transform.rotation.z")
                land.fromValue = angle
                land.toValue = target
                land.duration = Double((target - angle) / (.pi * 2))
                land.timingFunction = CAMediaTimingFunction(name: .easeOut)
                arc.add(land, forKey: "land")
            }
        }

        let settle = {
            self.glyph.alpha = showsRing ? 0 : 1
            self.glyph.transform = showsRing ? CGAffineTransform(scaleX: 0.6, y: 0.6) : .identity
        }
        // the glyph pops into the closing ring's place, once
        if animated, case .glyph = next, previous != next {
            glyph.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(
                withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction], animations: settle
            )
        } else {
            settle()
        }
    }

    /// A reused cell's ring comes back on screen with its animation gone.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, case .working = appearance else { return }
        let working = appearance
        appearance = .waiting
        set(working, animated: false)
    }
}
