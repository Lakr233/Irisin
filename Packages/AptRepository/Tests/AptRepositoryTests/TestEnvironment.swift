@testable import AptRepository
import Foundation
import XCTest

/// One throwaway environment for every test class: the engine bootstraps
/// once per process, so the first class to ask creates it.
enum TestEnvironment {
    /// A text file under `Fixtures/`.
    static func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url)
    }

    static let root: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AptRepositoryTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AptEnvironment.bootstrap(AptEnvironment(
            workingLocation: dir,
            dpkgStatusLocation: dir.appendingPathComponent("status").path,
            deviceArchitecture: { "iphoneos-arm64" },
            storage: MemoryStorage(),
            logger: PrintLogger()
        ))
        // WCDB builds a table binding's columns the first time a table is
        // created from it, and not safely from two threads: two databases
        // opened at once can both add the primary key ("more than one
        // primary key"). The app opens one; the tests open many in
        // parallel, so every binding is built here first, once.
        _ = AptDatabase.shared
        return dir
    }()

    static func database() -> AptDatabase {
        AptDatabase(at: root.appendingPathComponent("\(UUID().uuidString).db"))
    }
}

struct MemoryStorage: AptStorage {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var values = [String: Data]()

    func read(key: String) -> Data? {
        Self.lock.withLock { Self.values[key] }
    }

    func write(key: String, value: Data?) {
        Self.lock.withLock { Self.values[key] = value }
    }
}

struct PrintLogger: AptLogger {
    func log(_ kind: String, _ message: String, level: AptLogLevel) {
        if level == .error || level == .critical {
            print("[\(level.rawValue)] \(kind): \(message)")
        }
    }
}
