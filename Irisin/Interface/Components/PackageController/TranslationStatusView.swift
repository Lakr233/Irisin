//
//  TranslationStatusView.swift
//  Irisin
//

import SnapKit
import Then
import UIKit

/// The line under a package page's banner that says how Auto Translate is
/// going: a spinner while the page is with the translator, then that the
/// page is translated, or that it could not be. It only reports: the
/// Translate menu is the page's.
///
/// The page owns one for its whole life, outside the depiction, so a
/// depiction that is rendered again or another version of the package
/// leaves it where it is. It is a row of the page's list, there only while
/// it has something to say.
final class TranslationStatusView: UIView {
    enum Status {
        /// Nothing to say: the page reads as written.
        case none
        case translating
        case translated
        case failed
    }

    private(set) var status: Status = .none

    /// The page says whether this is seen: the words cross-dissolve on a
    /// page that is on show and are simply there on one still arriving.
    func show(_ status: Status, animated: Bool) {
        guard status != self.status else { return }
        self.status = status
        guard animated else { return apply() }
        UIView.transition(
            with: self,
            duration: 0.25,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) { self.apply() }
    }

    private let spinner = UIActivityIndicatorView(style: .medium).then {
        $0.color = .textSubtitle
        $0.hidesWhenStopped = true
        // the system's smallest spinner is a size above a footnote
        $0.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
    }

    private let symbol = UIImageView().then {
        $0.tintColor = .textSubtitle
        $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: .footnote)
    }

    private let caption = UILabel().then {
        $0.font = .footnote
        $0.textColor = .textSubtitle
        $0.numberOfLines = 0
    }

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        // the spinner and the symbol share a slot: the words do not move
        // when one gives way to the other
        let slot = UIView()
        addSubview(slot)
        addSubview(caption)
        slot.addSubview(spinner)
        slot.addSubview(symbol)

        // in line with the banner's icon above. A symbol has a baseline of
        // its own, which sits it on the words' as the system would; the
        // spinner has none and takes the middle of their capitals
        slot.snp.makeConstraints { x in
            x.leading.equalToSuperview().offset(15)
            x.top.bottom.equalTo(caption)
            x.width.equalTo(16)
        }
        symbol.snp.makeConstraints { x in
            // a symbol draws a little inside its own box
            x.leading.equalToSuperview().offset(-1.5)
            x.firstBaseline.equalTo(caption.snp.firstBaseline)
        }
        spinner.snp.makeConstraints { x in
            x.centerX.equalToSuperview()
            x.centerY.equalTo(caption.snp.firstBaseline).offset(-UIFont.footnote.capHeight / 2)
        }
        // the banner leaves 15 points under its icon; the line sits in them
        caption.snp.makeConstraints { x in
            x.leading.equalTo(slot.snp.trailing).offset(6)
            x.trailing.lessThanOrEqualToSuperview().offset(-20)
            x.top.equalToSuperview()
            x.bottom.equalToSuperview().offset(-8)
        }
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func apply() {
        switch status {
        case .none:
            break // the words stay while the row leaves
        case .translating:
            caption.text = String(localized: "Translating…")
        case .translated:
            caption.text = String(localized: "This page is translated.")
            symbol.image = UIImage(systemName: "character.bubble")
        case .failed:
            caption.text = String(localized: "Unable to translate this page.")
            symbol.image = UIImage(systemName: "exclamationmark.bubble")
        }
        if status == .translating {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        symbol.isHidden = status == .translating
        accessibilityLabel = status == .none ? nil : caption.text
    }
}
