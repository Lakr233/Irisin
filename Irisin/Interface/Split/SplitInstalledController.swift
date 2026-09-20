//
//  SplitInstalledController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/10.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

class SplitInstalledController: InstalledController {
    override var placesBarItemsLeading: Bool {
        true
    }

    override func viewDidLoad() {
        view.backgroundColor = .pageBackground
        super.viewDidLoad()
    }
}
