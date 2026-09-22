import IrisinProtocol
import UIKit

/// The queue's row while its package is installed or removed: the line
/// under the name says which step runs and the ring at the trailing edge
/// counts it, the accent for what comes and red for what goes. Nothing else
/// on the row moves. A package that stopped the operation trades its ring
/// for a red info mark; the row then opens the account of what went wrong.
final class OperationPackageCell: UITableViewCell {
    private let ring = ProgressRing()
    private(set) var change: QueueChange?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        ring.frame = CGRect(origin: .zero, size: ring.intrinsicContentSize)
        accessoryView = ring
        // One stop a row: the name, then the step under it as the row's
        // value. Nothing inside answers a press — the ring is drawn, and a
        // row with a problem opens its account through the row's own
        // selection — so the cell reads for all of it.
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// The row and where its package stands. `animated` is false for a cell
    /// that is being filled in, true for one on screen that moves on.
    func apply(_ change: QueueChange, icon: UIImage?, state: OperationPackages.State, animated: Bool) {
        self.change = change
        let status = state.status
        var content = change.content(
            icon: icon,
            details: [Self.subtitle(of: state, change: change), change.versions],
            muted: status == .notStarted
        )
        if state.hasProblem {
            content.secondaryTextProperties.color = status == .incomplete || state.ignoredScriptFailure
                ? .operationWarning
                : .operationFailed
        }
        // one line whatever it says: a row never changes height under the eye
        content.secondaryTextProperties.numberOfLines = 1
        contentConfiguration = content
        // only a row with a problem answers a press
        selectionStyle = state.hasProblem ? .default : .none

        let appearance: ProgressRing.Appearance
        switch status {
        case .failed:
            ring.tintColor = .operationFailed
            appearance = .glyph("info.circle.fill")
        case .incomplete:
            ring.tintColor = .operationWarning
            appearance = .glyph("info.circle.fill")
        case .done where state.ignoredScriptFailure:
            ring.tintColor = .operationWarning
            appearance = .glyph("info.circle.fill")
        case .done where state.needsRepair:
            ring.tintColor = .operationFailed
            appearance = .glyph("info.circle.fill")
        case .done:
            ring.tintColor = .operationSucceeded
            appearance = .glyph("checkmark.circle.fill")
        case .notStarted:
            appearance = .skipped
        case .waiting, .running:
            ring.tintColor = change.kind == .remove ? .swipeDelete : .buttonNormal
            appearance = state.isIndeterminate
                ? .working(state.fraction)
                : state.fraction > 0 ? .progress(state.fraction) : .waiting
        }
        ring.set(appearance, animated: animated)

        // the name is drawn attributed, so it is `attributedText` the row
        // reads as; a strikethrough is not spoken and the kind is in the line
        // under it
        accessibilityLabel = content.attributedText?.string
        accessibilityValue = content.secondaryText
        accessibilityTraits = state.hasProblem ? .button : .staticText
        accessibilityHint = state.hasProblem ? String(localized: "Shows what went wrong.") : nil
    }

    /// What the package is doing, or how it ended.
    private static func subtitle(of state: OperationPackages.State, change: QueueChange) -> String {
        switch state.status {
        case .waiting:
            return state.nextStep == .configuring ? String(localized: "Waiting to be set up") : String(localized: "Waiting")
        case let .running(_, script?):
            return String(localized: "Running \(script)…")
        case let .running(step, nil):
            return switch step {
            case .verifying: String(localized: "Checking…")
            case .removing: String(localized: "Removing…")
            case .unpacking: String(localized: "Installing…")
            case .configuring: String(localized: "Setting up…")
            case .triggering: String(localized: "Processing triggers…")
            }
        case .done where state.ignoredScriptFailure:
            return String(localized: "Completed with warnings")
        case .done where state.needsRepair:
            return String(localized: "Needs repair")
        case .done:
            return switch change.kind {
            case .remove: String(localized: "Removed")
            case .install: String(localized: "Installed")
            case .update: String(localized: "Updated")
            case .downgrade: String(localized: "Downgraded")
            case .reinstall: String(localized: "Reinstalled")
            }
        case .failed where state.needsRepair:
            return String(localized: "Needs repair")
        case let .failed(step):
            // a preinst that fails stops an unpack, but nothing failed to unpack
            if let script = state.failedScript {
                return String(localized: "The \(script) script failed")
            }
            return switch step {
            case .removing: String(localized: "Failed while removing")
            case .unpacking: String(localized: "Failed while installing")
            case .configuring, .triggering: String(localized: "Failed while setting up")
            case .verifying: String(localized: "Failed verification")
            }
        case .incomplete:
            return String(localized: "Unpacked, not set up")
        case .notStarted:
            return String(localized: "Not started")
        }
    }
}
