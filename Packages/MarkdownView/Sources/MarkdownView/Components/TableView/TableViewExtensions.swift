//
//  TableViewExtensions.swift
//  MarkdownView
//
//  Created by ktiays on 2025/1/27.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext
import UIKit

// MARK: - TextLabel.AttachmentRepresentable Extension

extension TableView: TextLabel.AttachmentRepresentable {
    func attributedStringRepresentation() -> NSAttributedString {
        let attributedString = NSMutableAttributedString()

        for (index, row) in contents.enumerated() {
            let rowString = NSMutableAttributedString()

            for cell in row {
                rowString.append(cell)
                rowString.append(NSAttributedString(string: "\t"))
            }

            attributedString.append(rowString)

            if index != contents.count - 1 {
                attributedString.append(NSAttributedString(string: "\n"))
            }
        }

        return attributedString
    }
}
