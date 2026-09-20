//
//  SplitDashboardController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/15.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

class SplitDashboardController: DashboardController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Dashboard")
        navigationItem.largeTitleDisplayMode = .never
        // the iPhone has a search tab; here the field is in the bar
        navigationItem.searchController = SearchController.searchController(hostedBy: self)
        navigationItem.hidesSearchBarWhenScrolling = false
        // the results stay under this screen when one of them is pushed
        definesPresentationContext = true
        view.backgroundColor = .pageBackground
    }
}
