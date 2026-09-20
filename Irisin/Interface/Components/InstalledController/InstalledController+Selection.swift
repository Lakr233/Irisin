//
//  InstalledController+Selection.swift
//  Irisin
//

import AptRepository
import AptResolver
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
            let done = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(endEditing))
            if placesBarItemsLeading {
                // the trailing end stays the search field's
                navigationItem.setRightBarButtonItems(nil, animated: animated)
                navigationItem.setLeftBarButtonItems(
                    [done, removeSelectedItem, updateSelectedItem],
                    animated: animated
                )
            } else {
                navigationItem.setLeftBarButtonItems([removeSelectedItem], animated: animated)
                navigationItem.setRightBarButtonItems([done, updateSelectedItem], animated: animated)
            }
        } else {
            setupBarItems()
        }
        updateSelectionItems()
    }

    var selectedPackages: [Package] {
        (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            diffableDataSource.itemIdentifier(for: $0)
        }
    }

    /// Remove takes any selection; Update one with a newer version in it.
    func updateSelectionItems() {
        guard isEditing else { return }
        let selected = selectedPackages
        removeSelectedItem.isEnabled = !selected.isEmpty
        updateSelectedItem.isEnabled = selected.contains { identitiesWithUpdate.contains($0.identity) }
    }

    @objc
    private func endEditing() {
        setEditing(false, animated: true)
    }

    @objc
    func removeSelected() {
        enqueueSelection(selectedPackages.map { .remove($0.identity) })
    }

    /// The selected rows that have an update; the rest stay as they are.
    @objc
    func updateSelected() {
        enqueueSelection(selectedPackages.compactMap(PackageMenuAction.updateRequest(forInstalled:)))
    }

    private func enqueueSelection(_ actions: [ResolutionAction]) {
        guard !actions.isEmpty else { return }
        setEditing(false, animated: true)
        Task { await PackageMenuAction.enqueue(actions, from: self) }
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
