//
//  LXInstalledController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/10.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

class LXInstalledController: InstalledController {
    override func viewDidLoad() {
        view.backgroundColor = .pageBackground
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)
        super.viewDidLoad()
    }
}
