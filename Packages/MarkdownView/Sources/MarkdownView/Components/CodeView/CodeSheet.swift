//
//  CodeSheet.swift
//  MarkdownView
//

import Foundation
import UIKit

/// The text a code block's sheet shows: its code, titled by its
/// language, and what its menu copies and saves.
struct CodeSheetContent {
    let title: String
    let code: NSAttributedString
    /// The code as copied and saved.
    let text: String
    let fileName: String

    @MainActor
    init(_ codeView: CodeView) {
        let language = codeView.language
        // The fence's word as written, with only its first letter raised:
        // "swift" reads as "Swift", and "objectiveC" keeps its inner capital.
        title = language.isEmpty ? CodeSheetText.code : language.prefix(1).uppercased() + language.dropFirst()
        code = codeView.textView.attributedText
        text = codeView.content
        fileName = CodeFileName.fileName(forLanguage: codeView.language)
    }

    /// Copy, Download and Close for the sheet showing this code from `view`.
    @MainActor
    func menuActions(from view: @escaping () -> UIView?, close: @escaping () -> Void) -> SheetMenuActions {
        let text = text
        let fileName = fileName
        return SheetMenuActions(
            copy: {
                FileExporter.copy(text)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            },
            download: {
                guard let view = view() else { return }
                FileExporter.export(Data(text.utf8), fileName: fileName, from: view)
            },
            close: close
        )
    }
}

enum CodeSheetText {
    static var code: String {
        String(localized: "Code", comment: "Title of a code block's sheet when it names no language.")
    }
}

@MainActor
enum CodeSheetPresenter {
    /// Presents `codeView`'s code in a half-height sheet that can be
    /// pulled up to full height.
    static func present(_ codeView: CodeView) {
        guard let presenter = codeView.topPresentingViewController else { return }
        let controller = CodeSheetViewController(content: CodeSheetContent(codeView))
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }
}

/// A code block's text in a selectable text view.
final class CodeSheetViewController: UIViewController {
    let textView = UITextView()
    private let content: CodeSheetContent

    init(content: CodeSheetContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        title = content.title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.attributedText = content.code
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        navigationItem.rightBarButtonItem = .sheetMenu(content.menuActions(
            from: { [weak self] in self?.view },
            close: { [weak self] in self?.dismiss(animated: true) }
        ))
    }
}
