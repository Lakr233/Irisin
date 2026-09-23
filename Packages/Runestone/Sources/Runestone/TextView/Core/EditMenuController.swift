import UIKit

protocol EditMenuControllerDelegate: AnyObject {
    func editMenuController(_ controller: EditMenuController, highlightedRangeFor range: NSRange) -> HighlightedRange?
    func editMenuController(_ controller: EditMenuController, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool
    func editMenuController(_ controller: EditMenuController, caretRectAt location: Int) -> CGRect
    func editMenuControllerShouldReplaceText(_ controller: EditMenuController)
    func selectedRange(for controller: EditMenuController) -> NSRange?
}

final class EditMenuController: NSObject {
    weak var delegate: EditMenuControllerDelegate?

    private var editMenuInteraction: UIEditMenuInteraction?

    func setupEditMenu(in view: UIView) {
        let editMenuInteraction = UIEditMenuInteraction(delegate: self)
        self.editMenuInteraction = editMenuInteraction
        view.addInteraction(editMenuInteraction)
    }

    func dismissEditMenu() {
        editMenuInteraction?.dismissMenu()
    }

    func presentEditMenu(from view: UIView, forTextIn range: NSRange) {
        let startCaretRect = caretRect(at: range.location)
        let endCaretRect = caretRect(at: range.location + range.length)
        let menuWidth = min(endCaretRect.maxX - startCaretRect.minX, view.frame.width)
        let menuRect = CGRect(x: startCaretRect.minX, y: startCaretRect.minY, width: menuWidth, height: startCaretRect.height)
        let point = CGPoint(x: menuRect.midX, y: menuRect.minY)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        configuration.preferredArrowDirection = .down
        editMenuInteraction?.presentEditMenu(with: configuration)
    }

    func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let textRange = textRange as? IndexedRange, let replaceAction = replaceActionIfAvailable(for: textRange.range) else {
            return UIMenu(children: suggestedActions)
        }
        return UIMenu(children: suggestedActions + [replaceAction])
    }
}

private extension EditMenuController {
    private func highlightedRange(for range: NSRange) -> HighlightedRange? {
        delegate?.editMenuController(self, highlightedRangeFor: range)
    }

    private func canReplaceText(in highlightedRange: HighlightedRange) -> Bool {
        delegate?.editMenuController(self, canReplaceTextIn: highlightedRange) ?? false
    }

    private func caretRect(at location: Int) -> CGRect {
        delegate?.editMenuController(self, caretRectAt: location) ?? .zero
    }

    private func replaceActionIfAvailable(for range: NSRange) -> UIAction? {
        guard let highlightedRange = highlightedRange(for: range), canReplaceText(in: highlightedRange) else {
            return nil
        }
        return UIAction(title: L10n.Menu.ItemTitle.replace) { [weak self] _ in
            if let self = self {
                self.delegate?.editMenuControllerShouldReplaceText(self)
            }
        }
    }
}

extension EditMenuController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if let selectedRange = delegate?.selectedRange(for: self), let replaceAction = replaceActionIfAvailable(for: selectedRange) {
            return UIMenu(children: [replaceAction] + suggestedActions)
        } else {
            return UIMenu(children: suggestedActions)
        }
    }
}
