import Foundation

enum ToolFSM {
    enum Event: Equatable {
        case requested
        case awaitingConfirmation
        case running
        case outputSent
        case ignored
        case failed
    }

    static func transition(from current: ToolStatus, event: Event) -> ToolStatus {
        switch current {
        case .ignored, .failed:
            return current
        case .outputSent:
            return event == .failed ? .failed : .outputSent
        case .pending, .awaitingUserConfirm, .running:
            switch event {
            case .requested:
                return .pending
            case .awaitingConfirmation:
                return .awaitingUserConfirm
            case .running:
                return .running
            case .outputSent:
                return .outputSent
            case .ignored:
                return .ignored
            case .failed:
                return .failed
            }
        }
    }
}
