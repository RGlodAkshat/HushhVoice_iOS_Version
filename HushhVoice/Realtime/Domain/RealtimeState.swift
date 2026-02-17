import Foundation

struct RealtimeState: Equatable {
    var session: SessionState = .init()
    var activeTurnId: UUID?
    var turns: [UUID: TurnContext] = [:]
    var responses: [String: ResponseContext] = [:]
    var tools: [String: ToolContext] = [:]
    var itemToResponse: [String: String] = [:]
    var callToResponse: [String: String] = [:]
    var callToTurn: [String: UUID] = [:]
    var messages: [ChatMessage] = []
    var streaming: StreamingViewState = .init()
}

struct SessionState: Equatable {
    var status: SessionStatus = .idle
    var lastError: String?
}

enum SessionStatus: String, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed
}

struct TurnContext: Equatable {
    let turnId: UUID
    var status: TurnStatus
    var activeResponseId: String?
    var userTranscriptBuffer: String
    let createdAt: Date

    init(
        turnId: UUID,
        status: TurnStatus = .listening,
        activeResponseId: String? = nil,
        userTranscriptBuffer: String = "",
        createdAt: Date = Date()
    ) {
        self.turnId = turnId
        self.status = status
        self.activeResponseId = activeResponseId
        self.userTranscriptBuffer = userTranscriptBuffer
        self.createdAt = createdAt
    }
}

enum TurnStatus: String, Equatable {
    case listening
    case thinking
    case speaking
    case cancelled
    case ended
}

struct ResponseContext: Equatable {
    let responseId: String
    var turnId: UUID?
    var status: ResponseStatus
    var textBuffer: String
    var audioActive: Bool
    var lastEventType: String?
    let createdAt: Date

    init(
        responseId: String,
        turnId: UUID? = nil,
        status: ResponseStatus = .streaming,
        textBuffer: String = "",
        audioActive: Bool = false,
        lastEventType: String? = nil,
        createdAt: Date = Date()
    ) {
        self.responseId = responseId
        self.turnId = turnId
        self.status = status
        self.textBuffer = textBuffer
        self.audioActive = audioActive
        self.lastEventType = lastEventType
        self.createdAt = createdAt
    }
}

enum ResponseStatus: String, Equatable {
    case streaming
    case completed
    case cancelled
    case failed
}

struct ToolContext: Equatable {
    let callId: String
    var boundResponseId: String?
    var boundTurnId: UUID?
    var name: String
    var argsJSON: String
    var status: ToolStatus
    let createdAt: Date

    init(
        callId: String,
        boundResponseId: String? = nil,
        boundTurnId: UUID? = nil,
        name: String = "",
        argsJSON: String = "{}",
        status: ToolStatus = .pending,
        createdAt: Date = Date()
    ) {
        self.callId = callId
        self.boundResponseId = boundResponseId
        self.boundTurnId = boundTurnId
        self.name = name
        self.argsJSON = argsJSON
        self.status = status
        self.createdAt = createdAt
    }
}

enum ToolStatus: String, Equatable {
    case pending
    case awaitingUserConfirm
    case running
    case outputSent
    case ignored
    case failed
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable {
        case user
        case assistant
        case system
    }

    let id: UUID
    var role: Role
    var text: String
    var responseId: String?
    var turnId: UUID?
    var isFinal: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        responseId: String? = nil,
        turnId: UUID? = nil,
        isFinal: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.responseId = responseId
        self.turnId = turnId
        self.isFinal = isFinal
        self.createdAt = createdAt
    }
}

struct StreamingViewState: Equatable {
    var activeResponseId: String?
    var activeAssistantText: String = ""
}
