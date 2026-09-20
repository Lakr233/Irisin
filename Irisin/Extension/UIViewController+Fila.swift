//
//  UIViewController+Fila.swift
//  Irisin
//

import AptRepository
import UIKit

extension UIViewController {
    /// Where Fila comes from, and its identity there.
    private static let filaRepository = URL(string: "https://apt.owngoal.dev")!
    private static let filaIdentity = "wiki.qaq.fila"

    /// Opens the folder at `path` in Fila.
    func openInFila(path: String) {
        fila(host: "open", path: path)
    }

    /// Shows `path` selected in its folder in Fila.
    func revealInFila(path: String) {
        fila(host: "reveal", path: path)
    }

    /// The fila:// link from the README. Without Fila the sheet offers the
    /// way to it: the OwnGoal Studio repository when it is not added yet,
    /// the package once it is.
    private func fila(host: String, path: String) {
        var components = URLComponents()
        components.scheme = "fila"
        components.host = host
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        if let url = components.url, UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            return
        }

        let repository = RepositoryCenter.default.repositories.values
            .first { $0.url.host == Self.filaRepository.host }
        presentConfirmation(
            title: "Install Fila",
            message: "Fila opens folders and files on this device. It comes from the OwnGoal Studio repository.",
            confirmTitle: repository == nil ? "Add Repository" : "Install Fila"
        ) { [weak self] in
            guard let repository else {
                self?.present(
                    RepositoryAddController.sheet(initialInput: Self.filaRepository.absoluteString),
                    animated: true
                )
                return
            }
            // a repository added but not refreshed yet has no package to show
            if let package = PackageCenter.default.obtainPackage(with: Self.filaIdentity, in: repository.url) {
                self?.present(next: PackageController(package: package))
            } else {
                self?.present(next: RepositoryDetailController(withRepo: repository))
            }
        }
    }
}
