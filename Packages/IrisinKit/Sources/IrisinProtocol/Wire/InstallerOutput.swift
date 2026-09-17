import Foundation

/// How the helper's transcript is framed on the pipe.
///
/// One event per line, JSON. A pipe carries bytes and not a wait status, and
/// the daemon that could have waited may have been restarted by the very
/// package it installed, so the exit status travels as the last event. A
/// line that is not an event (a helper older than this protocol, or a hand
/// on the pipe) decodes as `.output`, never as silence.
public enum InstallerOutput {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The one line that carries `event`. Never contains a newline: JSON
    /// escapes the ones inside strings.
    public static func encode(_ event: InstallerEvent) -> String {
        guard let data = try? encoder.encode(event) else {
            // Every case is a plain value; this cannot fail, but a transcript
            // must not lose its exit status if it somehow did.
            if case let .exit(status) = event {
                return #"{"exit":{"_0":\#(status)}}"#
            }
            return #"{"output":{"_0":""}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The event a line carries. A line that is not one is `.output(line)`.
    public static func decode(_ line: String) -> InstallerEvent {
        guard line.first == "{", line.last == "}",
              let event = try? JSONDecoder().decode(InstallerEvent.self, from: Data(line.utf8))
        else {
            return .output(line)
        }
        return event
    }
}
