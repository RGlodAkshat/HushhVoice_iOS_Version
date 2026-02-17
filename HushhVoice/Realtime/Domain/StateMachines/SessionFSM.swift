import Foundation

enum SessionFSM {
    enum Event: Equatable {
        case connectRequested
        case connected
        case disconnected
        case reconnectRequested
        case failed
        case reset
    }

    static func transition(from current: SessionStatus, event: Event) -> SessionStatus {
        switch (current, event) {
        case (_, .connectRequested):
            return .connecting
        case (_, .connected):
            return .connected
        case (.connected, .disconnected), (.connecting, .disconnected), (.reconnecting, .disconnected):
            return .reconnecting
        case (_, .reconnectRequested):
            return .reconnecting
        case (_, .failed):
            return .failed
        case (_, .reset):
            return .idle
        default:
            return current
        }
    }
}
