//
//  WelcomeFeatureRow.swift
//  Irisin
//

import SnapKit
import UIKit

/// The feature row from FlowDown's welcome page, with Irisin's content.
final class WelcomeFeatureRow: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let hStack = UIStackView()
    private let contentStack = UIStackView()

    init(feature: WelcomeController.Feature) {
        super.init(frame: .zero)

        hStack.axis = .horizontal
        hStack.spacing = 14
        hStack.alignment = .center

        contentStack.axis = .vertical
        contentStack.spacing = 2
        contentStack.alignment = .leading

        addSubview(hStack)
        hStack.addArrangedSubview(iconView)
        hStack.addArrangedSubview(contentStack)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(detailLabel)

        hStack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        iconView.contentMode = .scaleAspectFit
        iconView.snp.makeConstraints { make in
            make.width.height.equalTo(28)
        }

        titleLabel.font = WelcomeStyle.featureTitleFont
        titleLabel.textColor = WelcomeStyle.titleColor
        titleLabel.numberOfLines = 1

        detailLabel.font = WelcomeStyle.detailFont
        detailLabel.textColor = WelcomeStyle.detailColor
        detailLabel.numberOfLines = 0

        iconView.image = UIImage(systemName: feature.symbol)?
            .applyingSymbolConfiguration(WelcomeStyle.featureSymbol)
        iconView.tintColor = .buttonNormal
        titleLabel.text = String(resolving: feature.title)
        detailLabel.text = String(resolving: feature.detail)
        accessibilityElements = [titleLabel, detailLabel]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}
