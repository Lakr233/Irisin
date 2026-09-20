//
//  Properties.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/6.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Foundation

/// One file per key under a directory `main.swift` picks before anything reads
/// a value. Not UserDefaults: the app is installed by dpkg into a jailbreak
/// bootstrap, and a rootless-to-roothide move takes the Documents directory
/// with it while the defaults domain stays behind.
nonisolated enum Properties {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storeLocation: URL?
    private nonisolated(unsafe) static var onError: @Sendable (String) -> Void = { _ in }

    static func setup(storeAt location: URL, onError errorCall: @escaping @Sendable (String) -> Void) {
        lock.withLock {
            storeLocation = location
            onError = errorCall
        }

        try? FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        var isDir = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: location.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            fatalError("Broken Setting Permission")
        }
    }

    private static func locationFor(key: String) -> URL? {
        lock.withLock { storeLocation }?.appendingPathComponent(key)
    }

    static func read(key: String) -> Data? {
        guard let url = locationFor(key: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(key: String, value: Data?) {
        guard let url = locationFor(key: key) else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            if let value {
                try value.write(to: url)
            }
        } catch {
            lock.withLock { onError }(error.localizedDescription)
        }
    }
}

/// A value persisted through `Properties`, cached in memory after the first read.
///
/// Lock-guarded because a few settings are read off the main actor: the
/// package architecture is asked for by every repository compile. Owned as a
/// `let` store with a computed property in front of it; a wrapped `var` in a
/// nonisolated type is not allowed.
@propertyWrapper
final nonisolated class PropertiesWrapper<Value: Codable & Sendable>: @unchecked Sendable {
    private let key: String
    private let defaultValue: Value
    private let lock = NSLock()
    private var cachedValue: Value?

    init(key: String, defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
        cachedValue = Self.readDisk(key: key)
    }

    var wrappedValue: Value {
        get { lock.withLock { cachedValue ?? Self.readDisk(key: key) ?? defaultValue } }
        set {
            lock.withLock {
                cachedValue = newValue
                writeDisk(newValue)
            }
        }
    }

    private static func readDisk(key: String) -> Value? {
        guard let data = Properties.read(key: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func writeDisk(_ newValue: Value) {
        Properties.write(key: key, value: try? JSONEncoder().encode(newValue))
    }
}
