import Foundation

enum ResponseFSM {
    enum Event: Equatable {
        case created
        case delta
        case completed
        case cancelled
        case failed
    }

    static func transition(from current: ResponseStatus, event: Event) -> ResponseStatus {
        switch current {
        case .cancelled, .completed, .failed:
            return current
        case .streaming:
            switch event {
            case .created, .delta:
                return .streaming
            case .completed:
                return .completed
            case .cancelled:
                return .cancelled
            case .failed:
                return .failed
            }
        }
    }
}
