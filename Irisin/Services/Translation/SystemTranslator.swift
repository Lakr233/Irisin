//
//  SystemTranslator.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/19.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation
import os

/// The system's own translation engine, asked for text and nothing else.
///
/// The public `TranslationSession` arrives with iOS 18 and only inside a
/// SwiftUI view. Under it, since iOS 15, is `_LTTranslator` talking to
/// translationd, and that is what this speaks: the same class on every
/// system the app runs on. translationd turns away a client without the
/// `com.apple.private.translation` entitlement, which the app is signed with
/// (`Packaging/irisin.entitlements`). Nothing is linked: the framework is
/// opened by path and every class is looked up by name, so a system that
/// renamed one fails closed as `Failure.unavailable`.
///
/// A request first goes the way the system prefers, which is Apple's server
/// (or the large on-device model where there is one): the accurate answer.
/// When that fails it is asked again for the small on-device model alone,
/// and when that fails too the error is the caller's to show.
nonisolated enum SystemTranslator {
    enum Failure: Error, Equatable {
        /// No engine on this system, or it would not talk to us.
        case unavailable
        /// The engine has no pair from the text's language to the user's.
        case unsupportedLanguage
        /// The engine tried and said why it could not.
        case failed(String)
    }

    /// The language the user reads, as the engine should be asked for it.
    static var preferredTarget: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    /// Whether this device can translate into `target` at all: the engine
    /// loads, answers, and lists a pair that ends in the user's language.
    static func verify(target: Locale = preferredTarget) async -> Failure? {
        guard let pairs = await availablePairs() else { return .unavailable }
        return pairs.contains { matches($0.target, target) > 0 } ? nil : .unsupportedLanguage
    }

    /// Whether this system has the engine at all. Says nothing of whether
    /// it will answer: `verify` does.
    static var isPresent: Bool {
        engine != nil
    }

    /// The languages the engine reads and the ones it writes, by identifier,
    /// nil when it does not answer.
    static func languages() async -> (sources: [Locale], targets: [Locale])? {
        guard let pairs = await availablePairs() else { return nil }
        func distinct(_ locales: [Locale]) -> [Locale] {
            var seen = Set<String>()
            return locales.filter { seen.insert($0.identifier).inserted }
        }
        return (distinct(pairs.map(\.source)), distinct(pairs.map(\.target)))
    }

    /// `texts` in `target`, in order, or nil when they are in it already (or
    /// in no language the engine is sure of). A nil `source` is detected.
    static func translate(
        _ texts: [String],
        from source: Locale? = nil,
        to target: Locale = preferredTarget
    ) async throws -> [String]? {
        guard let pairs = await availablePairs() else { throw Failure.unavailable }
        let named = source
        let detected: Locale? = if named == nil {
            await detectLanguage(of: texts.joined(separator: "\n"))
        } else {
            nil
        }
        guard let source = named ?? detected else { return nil }
        if matches(source, target) >= 2 {
            return nil
        }
        let candidates = pairs
            .map { (pair: $0, score: matches($0.source, source) * 4 + matches($0.target, target)) }
            .filter { matches($0.pair.source, source) > 0 && matches($0.pair.target, target) > 0 }
        guard let pair = candidates.max(by: { $0.score < $1.score })?.pair else {
            throw Failure.unsupportedLanguage
        }

        var results: [String] = []
        var accurateRouteFailed = false
        for text in texts {
            try Task.checkCancellation()
            var translated: String?
            if !accurateRouteFailed {
                translated = try? await request(text, pair: pair, onDeviceOnly: false)
                accurateRouteFailed = translated == nil
            }
            let answer: String = if let translated {
                translated
            } else {
                try await request(text, pair: pair, onDeviceOnly: true)
            }
            results.append(answer)
        }
        return results
    }

    // MARK: - The engine

    private struct Pair: Sendable {
        let source: Locale
        let target: Locale
    }

    /// The engine's pairs, once it has answered with some: the list is the
    /// system's and does not change while the app runs.
    private static let knownPairs = OSAllocatedUnfairLock<[Pair]?>(initialState: nil)

    /// How long the engine gets to answer before it counts as a failure.
    /// translationd drops a client it rejects without calling anything back.
    private static let patience: Duration = .seconds(20)

    private static let engine: (translator: NSObject.Type, request: NSObject.Type)? = {
        let paths = [
            "/System/Library/Frameworks/Translation.framework/Translation", // iOS 18 and later
            "/System/Library/PrivateFrameworks/Translation.framework/Translation",
        ]
        guard paths.contains(where: { dlopen($0, RTLD_LAZY) != nil }),
              let translator = NSClassFromString("_LTTranslator") as? NSObject.Type,
              let request = NSClassFromString("_LTTextTranslationRequest") as? NSObject.Type,
              translator.instancesRespond(to: NSSelectorFromString("translate:")),
              request.instancesRespond(to: NSSelectorFromString("initWithSourceLocale:targetLocale:"))
        else {
            return nil
        }
        return (translator, request)
    }()

    private typealias Block1 = @convention(block) @Sendable (AnyObject?) -> Void
    private typealias Block2 = @convention(block) @Sendable (AnyObject?, AnyObject?) -> Void

    /// One answer from a callback that may come twice, late, or never.
    private static func answer<T: Sendable>(
        _ start: (@escaping @Sendable (T?) -> Void) -> Void
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first {
                    continuation.resume(returning: value)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(patience.components.seconds))) {
                finish(nil)
            }
            start(finish)
        }
    }

    /// Every pair the engine translates text between, nil when it does not
    /// answer. A rejected client is answered with nothing.
    private static func availablePairs() async -> [Pair]? {
        guard let engine else { return nil }
        if let known = knownPairs.withLock({ $0 }) {
            return known
        }
        let selector = NSSelectorFromString("availableLocalePairsForTask:completion:")
        guard let method = class_getClassMethod(engine.translator, selector) else { return nil }
        typealias Call = @convention(c) (AnyClass, Selector, Int, AnyObject) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let textTask = 1
        let pairs: [Pair]? = await answer { finish in
            let block: Block1 = { list in
                finish((list as? [NSObject])?.compactMap { pair in
                    guard let source = pair.value(forKey: "sourceLocale") as? Locale,
                          let target = pair.value(forKey: "targetLocale") as? Locale
                    else {
                        return nil
                    }
                    return Pair(source: source, target: target)
                })
            }
            call(engine.translator, selector, textTask, unsafeBitCast(block, to: AnyObject.self))
        }
        guard let pairs, !pairs.isEmpty else { return nil }
        knownPairs.withLock { $0 = pairs }
        return pairs
    }

    /// The language `text` is written in, when the engine is confident.
    private static func detectLanguage(of text: String) async -> Locale? {
        guard let engine else { return nil }
        let selector = NSSelectorFromString("languageForText:completion:")
        guard engine.translator.responds(to: selector) else { return nil }
        return await answer { finish in
            let block: Block1 = { result in
                guard let result = result as? NSObject,
                      result.value(forKey: "isConfident") as? Bool == true
                else {
                    return finish(nil)
                }
                finish(result.value(forKey: "dominantLanguage") as? Locale)
            }
            _ = (engine.translator as AnyObject).perform(
                selector,
                with: text as NSString,
                with: unsafeBitCast(block, to: AnyObject.self)
            )
        }
    }

    private static func request(_ text: String, pair: Pair, onDeviceOnly: Bool) async throws -> String {
        guard let engine else { throw Failure.unavailable }
        let initializer = NSSelectorFromString("initWithSourceLocale:targetLocale:")
        guard let method = class_getInstanceMethod(engine.request, initializer),
              let allocated = (engine.request as AnyObject).perform(NSSelectorFromString("alloc"))
        else {
            throw Failure.unavailable
        }
        // alloc hands over one reference and init takes it, handing back its own
        typealias Initialize = @convention(c) (Unmanaged<AnyObject>, Selector, NSLocale, NSLocale) -> Unmanaged<AnyObject>?
        let initialize = unsafeBitCast(method_getImplementation(method), to: Initialize.self)
        guard let request = initialize(allocated, initializer, pair.source as NSLocale, pair.target as NSLocale)?
            .takeRetainedValue() as? NSObject
        else {
            throw Failure.unavailable
        }

        let outcome: Result<String, Failure>? = await answer { finish in
            let handler: Block2 = { first, second in
                if let error = [first, second].compactMap({ $0 as? NSError }).first {
                    return finish(.failure(.failed(error.localizedFailureReason ?? error.localizedDescription)))
                }
                if let translated = [first, second].compactMap({ ($0 as? NSObject).flatMap(translatedText) }).first {
                    finish(.success(translated))
                }
            }
            request.setValue(NSAttributedString(string: text), forKey: "text")
            request.setValue(onDeviceOnly, forKey: "forcedOfflineTranslation")
            // iOS 18 added `completionHandler`; before it the answer comes
            // through `translationHandler`. Whichever speaks first is heard.
            for key in ["completionHandler", "translationHandler"]
                where request.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):"))
            {
                request.setValue(unsafeBitCast(handler, to: AnyObject.self), forKey: key)
            }
            _ = engine.translator.init().perform(NSSelectorFromString("translate:"), with: request)
        }
        guard let outcome else { throw Failure.unavailable }
        return try outcome.get()
    }

    /// `_LTCombinedTranslationResult.translatedText` on a current system,
    /// `_LTTranslationResult.translations.first.formattedString` before it.
    private static func translatedText(in result: NSObject) -> String? {
        if result.responds(to: NSSelectorFromString("translatedText")),
           let text = result.value(forKey: "translatedText") as? NSAttributedString
        {
            return text.string
        }
        if result.responds(to: NSSelectorFromString("translations")),
           let candidate = (result.value(forKey: "translations") as? [NSObject])?.first,
           candidate.responds(to: NSSelectorFromString("formattedString"))
        {
            return candidate.value(forKey: "formattedString") as? String
        }
        return nil
    }

    /// 0 for different languages, 1 for the same language, 2 when the script
    /// agrees too (Simplified is not Traditional), 3 when the region does.
    private static func matches(_ one: Locale, _ other: Locale) -> Int {
        let lhs = Locale.Language(identifier: one.identifier)
        let rhs = Locale.Language(identifier: other.identifier)
        guard let language = lhs.languageCode, language == rhs.languageCode else { return 0 }
        let scripts = [lhs, rhs].map { Locale.Language(identifier: $0.maximalIdentifier).script }
        guard scripts[0] == scripts[1] else { return 1 }
        return lhs.region != nil && lhs.region == rhs.region ? 3 : 2
    }
}
