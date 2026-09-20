//
//  DashboardFooterView.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//

import UIKit

/// Under the last section: the device, the system and this build.
final class DashboardFooterView: UICollectionReusableView {
    static let height: CGFloat = 96
    private static let gap: CGFloat = 32

    /// The studio line is a brand and stays as written in every language.
    private let label = UILabel().then {
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "Irisin"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineHeightMultiple = 1.5
        $0.attributedText = NSAttributedString(
            string: """
            \(DeviceIdentity.machine) · iOS \(DeviceIdentity.firmware) · \(name) \(version) (\(build))
            OwnGoal Studio × AI
            """,
            attributes: [
                .font: UIFont.rounded(.caption),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph,
            ]
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        label.snp.makeConstraints { x in
            x.centerX.equalToSuperview()
            x.top.equalToSuperview().offset(Self.gap)
            x.left.greaterThanOrEqualToSuperview()
            x.right.lessThanOrEqualToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
