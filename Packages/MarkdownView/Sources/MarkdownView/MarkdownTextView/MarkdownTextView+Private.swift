//
//  MarkdownTextView+Private.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import Combine
import Foundation
import Litext

extension MarkdownTextView {
    func resetCombine() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func setupCombine() {
        resetCombine()
        if let throttleInterval {
            contentSubject
                .dropFirst()
                .throttle(for: .seconds(throttleInterval), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] content in self?.use(content) }
                .store(in: &cancellables)
        } else {
            contentSubject
                .dropFirst()
                .sink { [weak self] content in self?.use(content) }
                .store(in: &cancellables)
        }
    }

    func use(_ content: MarkdownContent) {
        assert(Thread.isMainThread)
        self.content = content
        // due to a bug in model gemini-flash
        // there might be a large of unknown empty whitespace inside the table
        // thus we hereby call the autoreleasepool to avoid large memory consumption
        autoreleasepool { updateTextExecute() }

        layoutIfNeeded()
    }
}
