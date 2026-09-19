//
//  PackageController+Depiction.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AlertController
import AptRepository
import Dog
import PackageDepiction
import UIKit

extension PackageController {
    /// The depiction json for a package that named none, written here out of
    /// what dpkg already told us. Every package has a page; a repository that
    /// supplied no `SileoDepiction:` only means this app writes it instead.
    func localDepictionJSON() -> [String: Any] {
        let package = describedPackage
        var targetJsonData: [String: Any] = [:]
        targetJsonData["minVersion"] = "0.1"
        targetJsonData["class"] = "DepictionTabView"

        var tabRoot: [String: Any] = ["tabname": String(localized: "Details"),
                                      "class": "DepictionStackView"]
        var tabViewsArray: [[String: Any]] = []

        if let descMarkDown = package.latestMetadata?["description"] {
            var newmd: [String: Any] = [:]
            newmd["class"] = "DepictionMarkdownView"
            newmd["useSpacing"] = "true"
            newmd["markdown"] = descMarkDown
            tabViewsArray.append(newmd)
            tabViewsArray.append(["class": "DepictionSeparatorView"])
        }

        for (title, key) in [
            (String(localized: "Version"), "version"),
            (String(localized: "Section"), "section"),
            (String(localized: "Author"), "author"),
            (String(localized: "Maintainer"), "maintainer"),
        ] {
            var row: [String: Any] = ["title": title, "class": "DepictionTableTextView"]
            var field = package.latestMetadata?[key] ?? String(localized: "Unknown")
            if key == "section" {
                field = field.sectionDisplayName
            }
            (row["text"], row["action"]) = Self.contact(field)
            tabViewsArray.append(row)
        }

        tabRoot["views"] = tabViewsArray
        targetJsonData["tabs"] = [tabRoot]
        return targetJsonData
    }

    /// A dpkg `Author:` or `Maintainer:` field as the row shows it: the name
    /// with a `mailto:` behind it when the field is "Name <address>" (or the
    /// page itself for "Name <https://...>"), the address itself when that is
    /// all there is, the text untouched otherwise.
    /// The address is dropped from the text because it does not fit.
    nonisolated static func contact(_ field: String) -> (text: String, action: String?) {
        let address = #/[^<>\s@]+@[^<>\s@]+/#
        if let match = field.wholeMatch(of: #/\s*(?<name>.*?)\s*<(?<address>[^<>\s@]+@[^<>\s@]+)>\s*/#) {
            let name = String(match.name)
            return (name.isEmpty ? String(match.address) : name, "mailto:\(match.address)")
        }
        if let match = field.wholeMatch(of: #/\s*(?<name>.*?)\s*<(?<link>https?://[^<>\s]+)>\s*/#) {
            let name = String(match.name)
            return (name.isEmpty ? String(match.link) : name, String(match.link))
        }
        if let match = field.trimmingCharacters(in: .whitespaces).wholeMatch(of: address) {
            return (String(match.output), "mailto:\(match.output)")
        }
        return (field, nil)
    }

    /// The page shown while the remote depiction is still on its way.
    func defaultDepiction() -> UIView {
        render(localDepictionJSON(), tintColor: .buttonNormal) ?? UIView()
    }

    /// Fetches the package's own depiction and puts the rendered page on show.
    ///
    /// A package that named no depiction, and one whose depiction cannot be
    /// read, land in the same place: the json written locally. The difference
    /// between the two is a line in the log, not a different page.
    func downloadDepictionIfAvailable() {
        let package = describedPackage
        Task { [weak self] in
            guard let self else { return }

            var json: [String: Any]?
            if let url = PackageCenter.default.depictionURL(of: package) {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let remote = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                {
                    json = remote
                } else {
                    Dog.shared.join(
                        "Depiction",
                        "could not read the json depiction for \(package.identity) at \(url.absoluteString), writing one locally",
                        level: .error
                    )
                }
            } else {
                Dog.shared.join(
                    "Depiction",
                    "\(package.identity) named no depiction, writing one locally",
                    level: .verbose
                )
            }

            let depiction = json ?? localDepictionJSON()

            // a version without a photo does not keep the last one's. One
            // that is cached is here before the page shows; one that is not
            // waits for the page to have settled, then resizes the banner
            bannerArtwork.load(
                (depiction["headerImage"] as? String).flatMap(URL.init(string:)),
                uncachedNotBefore: bannerPhotoDeadline
            )

            let color = UIColor(css: depiction["tintColor"] as? String) ?? .buttonNormal
            bannerPackageView.buttonBackground.backgroundColor = color

            guard let view = render(depiction, tintColor: color) else {
                Dog.shared.join(
                    "Depiction",
                    "the depiction for \(package.identity) named a view class this build cannot render",
                    level: .warning
                )
                return
            }
            depictionView = view
            depictionOnShow = (depiction, color)
            translationModeOnShow = .original
            showTranslation(asked: false)
        }
    }

    /// Shows the depiction in `translationMode`. The page is always there
    /// as its author wrote it first; its prose goes to the system's
    /// translator (or comes out of `TranslationCache`) and the same depiction
    /// rendered from the answer fades in over it.
    ///
    /// `asked` is the user choosing from the Translate menu: every outcome
    /// is said, and one that leaves the page as it was puts the checkmark
    /// back where it stood. Without it this is Auto Translate, which leaves
    /// text already in the user's language alone without a word and says a
    /// failure once per launch (it is logged every time): a device offline
    /// with no language downloaded would otherwise alert on every page.
    ///
    /// With Auto Translate on, the line under the banner says how it is
    /// going, a failure included. With it off the page has no such line,
    /// and a translation asked for from the menu waits behind a progress
    /// alert that can cancel it.
    func showTranslation(asked: Bool) {
        depictionTranslation?.cancel()
        depictionTranslation = nil
        guard let (depiction, tintColor) = depictionOnShow else { return }
        guard translationMode != .original else {
            showTranslationStatus(.none)
            if asked {
                translationModeOnShow = .original
                fade(to: depiction, tintColor: tintColor)
            }
            return
        }
        let texts = DepictionTranslation.texts(in: depiction)
        guard !texts.isEmpty else {
            return showTranslationStatus(.none)
        }
        let package = "\(packageObject.identity) \(packageObject.latestVersion ?? "")"
        let source = translationSource
        let target = AutomaticTranslation.target
        let pair = "\(source?.identifier ?? "auto")>\(target.identifier)"
        let mode = translationMode

        func apply(_ translations: [String: String]) {
            translationModeOnShow = mode
            showTranslationStatus(.translated)
            fade(
                to: DepictionTranslation.replacing(depiction, with: translations, comparing: mode == .compared),
                tintColor: tintColor
            )
        }
        if let known = TranslationCache.translations(of: package, pair: pair) {
            return apply(known)
        }

        let alert = asked && !AutomaticTranslation.isEnabled ? translationProgressAlert() : nil
        showTranslationStatus(.translating)
        depictionTranslation = Task { [weak self] in
            // on screen before the answer: a quick one would dismiss it
            // while it is still coming in, which UIKit ignores
            if let alert, let self {
                await withCheckedContinuation { done in
                    self.present(alert, animated: true) { done.resume() }
                }
            }
            let outcome: Result<[String]?, Error>
            do {
                outcome = try await .success(SystemTranslator.translate(texts, from: source, to: target))
            } catch {
                outcome = .failure(error)
            }
            // Cancel took the alert down itself; a page that moved on has
            // said what it shows now, and only the alert is left to go
            guard !Task.isCancelled, let self else {
                if let alert, !alert.isBeingDismissed {
                    await alert.dismissFinishing(animated: true)
                }
                return
            }
            // gone before a notice: the page cannot present while it is leaving
            await alert?.dismissFinishing(animated: true)
            switch outcome {
            case let .success(translated):
                // an engine unsure of the language hands the text back as it was
                guard let translated, translated != texts else {
                    translationMode = translationModeOnShow
                    showTranslationStatus(translationModeOnShow == .original ? .none : .translated)
                    if asked {
                        presentNotice(
                            title: "Nothing to Translate",
                            message: "This page is already in the target language."
                        )
                    }
                    return
                }
                let translations = Dictionary(zip(texts, translated)) { first, _ in first }
                TranslationCache.store(translations, of: package, pair: pair)
                apply(translations)
            case .failure(is CancellationError):
                return
            case let .failure(error):
                Dog.shared.join("Translation", "could not translate the depiction of \(package): \(error)", level: .error)
                translationMode = translationModeOnShow
                showTranslationStatus(.failed)
                guard asked || !AutomaticTranslation.failureWasShown,
                      viewIfLoaded?.window != nil, presentedViewController == nil
                else {
                    return
                }
                AutomaticTranslation.failureWasShown = true
                presentNotice(title: "Unable to Translate", message: AutomaticTranslation.describe(error))
            }
        }
    }

    /// The alert a translation asked for from the menu waits behind while
    /// Auto Translate is off. Cancel leaves the page and its checkmark as
    /// they were.
    private func translationProgressAlert() -> AlertProgressIndicatorViewController {
        let alert = progressAlert(
            title: "Translating…",
            message: "The system is translating this page."
        )
        alert.progressContext.addAction(title: "Cancel") { [weak self, weak alert] in
            self?.depictionTranslation?.cancel()
            self?.depictionTranslation = nil
            if let self {
                translationMode = translationModeOnShow
            }
            alert?.progressContext.dispose()
        }
        return alert
    }

    /// What the line under the banner says. It is Auto Translate's: with the
    /// setting off it stays closed whatever happens.
    private func showTranslationStatus(_ status: TranslationStatusView.Status) {
        let status = AutomaticTranslation.isEnabled ? status : .none
        let last = translationStatusView.status
        guard last != status else { return }
        // Words that give way to other words cross-dissolve; the line
        // itself is a row, which the list brings in and takes out. Only a
        // page on show animates: one still being pushed arrives settled.
        translationStatusView.show(status, animated: hasAppeared && last != .none && status != .none)
        applyRows(animated: hasAppeared)
    }

    private func fade(to depiction: [String: Any], tintColor: UIColor) {
        guard let view = render(depiction, tintColor: tintColor) else { return }
        UIView.transition(
            with: tableView,
            duration: 0.35,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            self.depictionView = view
        }
    }

    /// The one renderer both paths go through. Nothing at the root is
    /// actionable: that flag is what a button hands the view it wraps, so
    /// a label inside one wears the tint. Set here, every label did.
    private func render(_ json: [String: Any], tintColor: UIColor) -> UIView? {
        let proxy = PackageControllerProxy()
        proxy.parentController = self
        let view = DepictionBaseView.view(
            dictionary: json,
            viewController: proxy,
            tintColor: tintColor,
            isActionable: false
        )
        depictionIsPartial = !proxy.unrenderedClasses.isEmpty
        if depictionIsPartial {
            Dog.shared.join(
                "Depiction",
                "the depiction for \(packageObject.identity) named views this build cannot render: \(proxy.unrenderedClasses.joined(separator: ", "))",
                level: .warning
            )
        }
        return view
    }
}
