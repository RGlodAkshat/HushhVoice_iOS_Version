import Foundation

enum TurnFSM {
    enum Event: Equatable {
        case speechStarted
        case speechStopped
        case assistantSpeaking
        case cancelled
        case ended
    }

    static func transition(from current: TurnStatus, event: Event) -> TurnStatus {
        switch event {
        case .speechStarted:
            return .listening
        case .speechStopped:
            return .thinking
        case .assistantSpeaking:
            return .speaking
        case .cancelled:
            return .cancelled
        case .ended:
            return .ended
        }
    }
}
