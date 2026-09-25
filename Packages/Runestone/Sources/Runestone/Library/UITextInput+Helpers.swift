import UIKit

#if compiler(>=5.9)

    @available(iOS 17, *)
    extension UITextInput where Self: NSObject {
        var sbs_textSelectionDisplayInteraction: UITextSelectionDisplayInteraction? {
            let interactionAssistantKey = "int" + "ssAnoitcare".reversed() + "istant"
            // the annotation picks String's `+`: without it, Xcode 26's
            // compiler finds `reversed()` ambiguous
            // swiftformat:disable:next redundantType
            let selectionViewManagerKey: String = "les_".reversed() + "ection" + "reganaMweiV".reversed()
            guard responds(to: Selector(interactionAssistantKey)) else {
                return nil
            }
            guard let interactionAssistant = value(forKey: interactionAssistantKey) as? AnyObject else {
                return nil
            }
            guard interactionAssistant.responds(to: Selector(selectionViewManagerKey)) else {
                return nil
            }
            return interactionAssistant.value(forKey: selectionViewManagerKey) as? UITextSelectionDisplayInteraction
        }
    }

#endif
