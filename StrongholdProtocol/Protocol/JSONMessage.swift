import Foundation

/// A JSON value that can hold anything the game protocol sends.
/// The web client uses plain JSON objects end to end; we mirror that with
/// an enum so we can decode loosely now and type specific payloads later.
indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    var objectValue: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int64(d)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    subscript(key: String) -> JSON? {
        objectValue?[key]
    }

    subscript(index: Int) -> JSON? {
        arrayValue?[index]
    }
}

extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSON].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSON].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

/// Builds outgoing protocol messages: `{ t, rid?, ...fields }`.
enum OutgoingMessage {
    /// Makes a message body. `rid` is echoed by the server in `ok`/`error`.
    static func make(_ type: String, rid: Int64? = nil, _ fields: [String: JSON] = [:]) -> JSON {
        var body: [String: JSON] = ["t": .string(type)]
        if let rid { body["rid"] = .int(rid) }
        for (k, v) in fields { body[k] = v }
        return .object(body)
    }

    /// Encodes a message to wire JSON text.
    static func encode(_ message: JSON) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Decodes incoming wire text into a JSON object.
enum IncomingMessage {
    static func decode(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSON.self, from: data)
        else { return nil }
        return value
    }
}
