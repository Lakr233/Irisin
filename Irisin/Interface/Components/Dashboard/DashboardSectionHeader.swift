//
//  DashboardSectionHeader.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

class DashboardSectionHeader: UICollectionReusableView {
    let label = UILabel()
    let button = UIButton()
    var overrideButtonAction: (@MainActor @Sendable (UIViewController?) -> Void)?

    var representSection: DashboardController.Section?
    /// The section as it is now: a header on screen outlives many
    /// snapshots, and the full list must show what the rows under it show.
    var currentSection: (() -> DashboardController.Section?)?
    var horizontalPadding: CGFloat = 0 {
        didSet {
            updateLayout()
        }
    }

    override init(frame _: CGRect) {
        super.init(frame: CGRect())
        label.font = .headline
        addSubview(label)
        button.setImage(.fluent(.arrowRightCircle24Filled), for: .normal)
        button.addTarget(self, action: #selector(presentFullPackage), for: .touchUpInside)
        addSubview(button)
        updateLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func updateLayout() {
        label.snp.remakeConstraints { x in
            x.leading.equalToSuperview().offset(horizontalPadding)
            x.trailing.equalTo(button.snp.leading).offset(-5)
//            x.centerY.equalToSuperview()
            x.bottom.equalToSuperview().offset(-15)
        }
        button.snp.remakeConstraints { x in
            x.centerY.equalTo(label)
            x.trailing.equalToSuperview().offset(-horizontalPadding)
            x.width.equalTo(33)
            x.height.equalTo(33)
        }
    }

    func loadSection(data: DashboardController.Section) {
        representSection = data
        label.text = data.title
    }

    @objc
    func presentFullPackage() {
        if let override = overrideButtonAction {
            override(parentViewController)
            return
        }
        let section = currentSection?() ?? representSection
        let target = PackageCollectionController()
        target.title = section?.title
        target.dataSource = section?.packages ?? []
        parentViewController?.present(next: target)
    }
}
