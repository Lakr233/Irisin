//
//  Copyright (c) Microsoft Corporation.
//  Licensed under the MIT license.
//

import UIKit

enum FluentIcon {
    case arrowRightCircle24Filled
    case arrowUpCircle24Filled
    case bookCompass24Filled
    case bookCompass24Regular
    case bookNumber24Filled
    case bookSearch24Regular
    case checkmarkCircle24Filled
    case delete24Filled
    case documentNone24Regular
    case errorCircle24Filled
    case extension24Filled
    case peopleSearch24Regular
    case settings24Regular
    case shareIos24Filled
    case textChangeAccept24Filled
    case timeline24Regular

    var image: UIImage {
        switch self {
        case .arrowRightCircle24Filled: .arrowRightCircle24Filled
        case .arrowUpCircle24Filled: .arrowUpCircle24Filled
        case .bookCompass24Filled: .bookCompass24Filled
        case .bookCompass24Regular: .bookCompass24Regular
        case .bookNumber24Filled: .bookNumber24Filled
        case .bookSearch24Regular: .bookSearch24Regular
        case .checkmarkCircle24Filled: .checkmarkCircle24Filled
        case .delete24Filled: .delete24Filled
        case .documentNone24Regular: .documentNone24Regular
        case .errorCircle24Filled: .errorCircle24Filled
        case .extension24Filled: .extension24Filled
        case .peopleSearch24Regular: .peopleSearch24Regular
        case .settings24Regular: .settings24Regular
        case .shareIos24Filled: .shareIos24Filled
        case .textChangeAccept24Filled: .textChangeAccept24Filled
        case .timeline24Regular: .timeline24Regular
        }
    }
}

extension UIImage {
    static func fluent(_ icon: FluentIcon) -> UIImage {
        icon.image
    }
}
