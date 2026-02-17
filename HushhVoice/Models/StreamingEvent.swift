import Foundation

// Generic JSON payload support for streaming events.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// Canonical envelope for streaming events.
struct StreamEventEnvelope: Codable, Identifiable, Equatable {
    let event_id: String
    let event_type: String
    let ts: String
    let session_id: String
    let turn_id: String?
    let message_id: String?
    let seq: Int
    let turn_seq: Int
    let role: String?
    let payload: [String: JSONValue]

    var id: String { event_id }

    static func make(
        eventType: String,
        sessionID: String,
        seq: Int,
        turnSeq: Int,
        turnID: String? = nil,
        messageID: String? = nil,
        role: String? = nil,
        payload: [String: JSONValue] = [:]
    ) -> StreamEventEnvelope {
        let ts = ISO8601DateFormatter().string(from: Date())
        return StreamEventEnvelope(
            event_id: UUID().uuidString,
            event_type: eventType,
            ts: ts,
            session_id: sessionID,
            turn_id: turnID,
            message_id: messageID,
            seq: seq,
            turn_seq: turnSeq,
            role: role,
            payload: payload
        )
    }
}

// Encoder/decoder helpers for streaming events.
enum StreamEventCodec {
    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return enc
    }()
    private static let decoder = JSONDecoder()

    static func encode(_ event: StreamEventEnvelope) throws -> Data {
        try encoder.encode(event)
    }

    static func decode(_ data: Data) throws -> StreamEventEnvelope {
        try decoder.decode(StreamEventEnvelope.self, from: data)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func doubleValue(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    func object(_ key: String) -> [String: JSONValue]? {
        self[key]?.objectValue
    }
}
