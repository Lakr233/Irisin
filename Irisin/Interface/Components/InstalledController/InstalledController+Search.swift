//
//  InstalledController+Search.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

extension InstalledController: UISearchControllerDelegate, UISearchResultsUpdating, UISearchBarDelegate {
    func updateSearchResults(for searchController: UISearchController) {
        updateSource(withSearchText: searchController.searchBar.text)
    }

    func searchBar(_: UISearchBar, textDidChange _: String) {}
}
