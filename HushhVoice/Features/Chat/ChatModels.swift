import Foundation

// Chat message model used throughout the UI and persistence.
struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .init()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
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
