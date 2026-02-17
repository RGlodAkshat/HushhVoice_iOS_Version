import Foundation

struct OpenAIEvent: Equatable {
    enum AudioState: String, Equatable {
        case started
        case stopped
        case cleared
    }

    enum Kind: Equatable {
        case known(String)
        case unknown

        init(eventType: String) {
            if eventType.isEmpty {
                self = .unknown
            } else {
                self = .known(eventType)
            }
        }
    }

    let eventType: String
    let kind: Kind
    let responseId: String?
    let itemId: String?
    let callId: String?
    let assistantTextDelta: String?
    let assistantTextFinal: String?
    let userTranscriptDelta: String?
    let userTranscriptFinal: String?
    let audioState: AudioState?
    let toolName: String?
    let toolArgumentsJSON: String?
    let isToolArgumentsDone: Bool
    let errorMessage: String?
    let raw: String
}
