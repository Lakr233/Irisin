//
//  UIViewController+Alert.swift
//  Irisin
//

// preconcurrency: the configuration is a plain static var upstream, only
// ever touched on the main actor here
@preconcurrency import AlertController
import UIKit

/// Two shapes cover nearly every alert in the app: a notice you acknowledge and
/// a question you answer.
///
/// AlertController runs `String(localized:)` on every title and message it is
/// given, resolving against `Bundle.main` — which is this app's
/// `Localizable.xcstrings`. Pass the English catalog key (`"Error"`), not an
/// already-localized string: that would be looked up a second time, miss, and
/// only survive by accident. The `String` overloads exist for genuinely
/// dynamic text — an error description, a package name — which misses the
/// catalog and comes back unchanged, as intended.
extension UIViewController {
    func presentNotice(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        dismissTitle: String.LocalizationValue = "Dismiss",
        onDismiss: @escaping () -> Void = {}
    ) {
        present(AlertViewController(title: title, message: message) { context in
            context.addAction(title: dismissTitle) {
                context.dispose { onDismiss() }
            }
        }, animated: true)
    }

    @_disfavoredOverload
    func presentNotice(
        title: String.LocalizationValue,
        message: String,
        dismissTitle: String.LocalizationValue = "Dismiss",
        onDismiss: @escaping () -> Void = {}
    ) {
        presentNotice(
            title: title,
            message: String.LocalizationValue(message),
            dismissTitle: dismissTitle,
            onDismiss: onDismiss
        )
    }

    func presentNotice(
        title: String.LocalizationValue,
        dismissTitle: String.LocalizationValue = "Dismiss",
        onDismiss: @escaping () -> Void = {}
    ) {
        presentNotice(title: title, message: String(), dismissTitle: dismissTitle, onDismiss: onDismiss)
    }

    /// `destructive` paints the sheet in the delete colour: the filled
    /// confirming button and the outlined Cancel. The alert library has one
    /// accent for all and reads it while the sheet is built, so the swap
    /// lasts exactly that long and cannot leak into the next alert.
    func presentConfirmation(
        title: String.LocalizationValue,
        message: String.LocalizationValue,
        confirmTitle: String.LocalizationValue = "Confirm",
        destructive: Bool = false,
        onConfirm: @escaping () -> Void
    ) {
        let accent = AlertControllerConfiguration.accentColor
        if destructive {
            AlertControllerConfiguration.accentColor = .swipeDelete
        }
        let alert = AlertViewController(title: title, message: message) { context in
            context.addAction(title: "Cancel") {
                context.dispose()
            }
            context.addAction(title: confirmTitle, attribute: .accent) {
                context.dispose { onConfirm() }
            }
        }
        AlertControllerConfiguration.accentColor = accent
        present(alert, animated: true, completion: nil)
    }

    /// Returns once the dismissal has finished. The SDK marks
    /// `dismiss(animated:completion:)` `NS_SWIFT_DISABLE_ASYNC`, so an
    /// `await` on it returns at once, while the sheet is still leaving and
    /// the next `present` would be refused.
    func dismissFinishing(animated: Bool) async {
        guard presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            dismiss(animated: animated) { continuation.resume() }
        }
    }
}

/// A modal spinner for work the user has to wait through, built here rather
/// than at the call site.
///
/// Xcode's extractor only sees a `String.LocalizationValue` literal handed to a
/// function declared in this module: a literal passed straight to
/// AlertController resolves at run time but never reaches
/// `Localizable.xcstrings`, so it ships untranslated.
func progressAlert(
    title: String.LocalizationValue,
    message: String.LocalizationValue
) -> AlertProgressIndicatorViewController {
    .init(title: title, message: message)
}
