import Foundation

/// A JSON value the server and its responder hand each other across
/// actors: what the page sent and what it is answered, without `Any`.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var integer: Int? {
        if case let .number(value) = self, value.rounded() == value, abs(value) < 1e15 {
            return Int(value)
        }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    public static func integer(_ value: Int) -> JSONValue {
        .number(Double(value))
    }

    /// Its compact UTF-8 encoding, keys sorted so the same value is the same
    /// bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
