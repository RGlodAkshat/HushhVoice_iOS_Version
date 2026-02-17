import Foundation

// Client-side turn lifecycle for the chat surface.
enum ChatTurnState: String, Codable {
    case idle
    case listening
    case finalizingInput
    case thinking
    case executingTools
    case awaitingConfirmation
    case speaking
    case cancelled
    case errorRecoverable
    case errorTerminal
}

// Minimal state machine used by the chat UI to stay consistent.
final class ChatTurnStateMachine: ObservableObject {
    @Published private(set) var state: ChatTurnState = .idle
    @Published private(set) var lastError: String?

    var isListening: Bool { state == .listening }
    var isSpeaking: Bool { state == .speaking }

    func setState(_ newState: ChatTurnState, error: String? = nil) {
        state = newState
        lastError = error
    }

    func reset() {
        state = .idle
        lastError = nil
    }
}
