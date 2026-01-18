import Foundation

// Chat message model used throughout the UI and persistence.
struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    enum Status: String, Codable { case normal, interrupted }

    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date
    var status: Status

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .init(), status: Status = .normal) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .normal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(status, forKey: .status)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case timestamp
        case status
    }
}

// Chat thread model that holds a list of messages.
struct Chat: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = .init(),
        updatedAt: Date = .init(),
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

// Lightweight attachment metadata for local UI display.
struct ChatAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let sizeBytes: Int

    init(id: UUID = UUID(), fileName: String, sizeBytes: Int) {
        self.id = id
        self.fileName = fileName
        self.sizeBytes = sizeBytes
    }

    var displayName: String { fileName }
}

// Confirmation request displayed in the chat UI.
struct ChatConfirmation: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case pending, accepted, rejected, edited, expired }
    let id: UUID
    let actionType: String
    let previewText: String
    var status: Status

    init(id: UUID = UUID(), actionType: String, previewText: String, status: Status = .pending) {
        self.id = id
        self.actionType = actionType
        self.previewText = previewText
        self.status = status
    }
}
