//
//  InstalledController+Selection.swift
//  Irisin
//

import AptRepository
import AptResolver
import SPIndicator
import UIKit

/// Editing is multi-selection, as on the repository page: a two-finger drag
/// on the list or Select in the menu enters it, Done leaves it, and the bar
/// carries what applies to the selected rows. Both go to the change sheet
/// as one request, where the resolver answers for all of them at once.
extension InstalledController {
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        if editing {
            // the system's Done, made for each edit: one that has left the
            // bar comes back to it without its glyph
            let doneItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(endEditing)
            )
            if placesBarItemsLeading {
                // the trailing end stays the search field's
                placeBarItems(
                    leading: [doneItem, removeSelectedItem, updateSelectedItem],
                    trailing: [],
                    animated: animated
                )
            } else {
                placeBarItems(
                    leading: [removeSelectedItem],
                    trailing: [doneItem, updateSelectedItem],
                    animated: animated
                )
            }
        } else {
            // the ticks go with the mode: the next edit starts with none
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
            setupBarItems(animated: animated)
        }
        updateSelectionItems()
    }

    var selectedPackages: [Package] {
        (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            diffableDataSource.itemIdentifier(for: $0)
        }
    }

    /// Each is live when the batch has something to send: Remove a row that
    /// can be removed or withdrawn, Update a row the batch can update, which
    /// is not every row with an arrow on it.
    func updateSelectionItems() {
        guard isEditing else { return }
        let selected = selectedPackages
        removeSelectedItem.isEnabled = PackageMenu.removal(ofInstalled: selected).request != nil
        updateSelectedItem.isEnabled = selected.contains {
            identitiesWithUpdate.contains($0.identity) && PackageMenu.updateRequest(forInstalled: $0) != nil
        }
    }

    @objc
    func endEditing() {
        setEditing(false, animated: true)
    }

    @objc
    func removeSelected() {
        let (request, leftOut) = PackageMenu.removal(ofInstalled: selectedPackages)
        send(request, leavingOut: leftOut)
    }

    /// The selected rows that have an update; the rest stay as they are. A
    /// row with an update the batch cannot take (a paid package, which is
    /// checked with its vendor one at a time) is said to be left out.
    @objc
    func updateSelected() {
        var updates: [ResolutionAction] = []
        var leftOut: [Package] = []
        for row in selectedPackages where identitiesWithUpdate.contains(row.identity) {
            if let update = PackageMenu.updateRequest(forInstalled: row) {
                updates.append(update)
            } else {
                leftOut.append(row)
            }
        }
        send(updates.isEmpty ? nil : .actions(updates), leavingOut: leftOut)
    }

    /// One request to the change sheet, where the resolver answers for the
    /// whole selection. With nothing to ask for the list stays as it is
    /// edited, and either way what was left out is said.
    private func send(_ request: QueueChangeController.Request?, leavingOut leftOut: [Package]) {
        if !leftOut.isEmpty {
            SPIndicator.present(
                title: String(localized: "Some Packages Left Out"),
                message: String(localized: "Open their pages instead."),
                preset: .error
            )
        }
        guard let request else { return }
        setEditing(false, animated: true)
        Task { await QueueChangeController.show(request, from: self) }
    }

    // MARK: - TWO-FINGER SELECTION

    override func collectionView(
        _: UICollectionView,
        shouldBeginMultipleSelectionInteractionAt _: IndexPath
    ) -> Bool {
        true
    }

    override func collectionView(
        _: UICollectionView,
        didBeginMultipleSelectionInteractionAt _: IndexPath
    ) {
        setEditing(true, animated: true)
    }

    override func collectionViewDidEndMultipleSelectionInteraction(_: UICollectionView) {
        updateSelectionItems()
    }

    override func collectionView(_: UICollectionView, didDeselectItemAt _: IndexPath) {
        updateSelectionItems()
    }
}
