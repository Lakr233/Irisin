import ArgumentParser
import Foundation

/// The options every command takes.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print one JSON object per line instead of text.")
    var json = false

    @Flag(name: .shortAndLong, help: "Print what the catalogue and the helper say along the way.")
    var verbose = false
}

/// Text for a person, or one JSON object per line for a script. The JSON
/// keys are the contract icli's bridge and scripts read: add, never rename.
struct Output: Sendable {
    let json: Bool

    /// Flushed at once: a transcript read through a pipe arrives as the
    /// helper writes it, and before any note on standard error after it.
    func line(_ text: String) {
        guard !json else { return }
        print(text)
        fflush(stdout)
    }

    func object(_ object: [String: Any]) {
        guard json else { return }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    /// A line for a person on standard error, whatever the mode: a warning
    /// is not a result.
    func note(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }
}

/// Why a command stopped, with the exit status the design gives it.
enum CommandFailure: Error, CustomStringConvertible {
    case notRoot
    case misplaced
    case unavailable(String)
    case refused(String)
    case transaction(status: Int32)

    var description: String {
        switch self {
        case .notRoot:
            "irisin-cli changes the system as root. Run it with sudo."
        case .misplaced:
            "irisin-cli runs only where Irisin's package installed it."
        case let .unavailable(reason), let .refused(reason):
            reason
        case let .transaction(status):
            "The transaction ended with status \(status)."
        }
    }

    var exitCode: ExitCode {
        switch self {
        case .notRoot: ExitCode(77)
        case .misplaced, .unavailable, .refused: ExitCode(1)
        case let .transaction(status): ExitCode(status == 0 ? 1 : status)
        }
    }
}

extension ParsableCommand {
    /// Runs `body` and turns a `CommandFailure` into its message and exit
    /// status; anything else is ArgumentParser's to report.
    func guarded(_ output: Output, _ body: @escaping () async throws -> Void) throws {
        do {
            try Self.blocking(body)
        } catch let failure as CommandFailure {
            if output.json {
                output.object(["error": failure.description])
            }
            output.note("irisin-cli: \(failure.description)")
            throw failure.exitCode
        }
    }

    /// The async work of a command, on a task of its own while this thread
    /// waits. Commands are synchronous on purpose: an async `main` imports
    /// `swift_task_asyncMainDrainQueue` and `swift_job_run`, which the iOS
    /// 15 floor is not known to export (Scripts/check-floor-imports.py).
    static func blocking(_ body: @escaping () async throws -> Void) throws {
        let work = Unchecked(body)
        let outcome = Unchecked(Outcome())
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await work.value()
                outcome.value.result = .success(())
            } catch {
                outcome.value.result = .failure(error)
            }
            finished.signal()
        }
        finished.wait()
        try outcome.value.result.get()
    }
}

/// A value handed to the one task `blocking` starts and read back only
/// after the semaphore says it finished: never touched from two threads at
/// once, which is what the unchecked conformance stands for.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class Outcome {
    var result: Result<Void, any Error> = .success(())
}
