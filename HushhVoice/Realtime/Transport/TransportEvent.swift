import Foundation

enum TransportConnectionState: Equatable {
    case connected
    case disconnected
    case reconnecting
}

enum TransportDataChannelState: Equatable {
    case open
    case closed
}

enum TransportEvent {
    case stateChanged(TransportConnectionState)
    case dataChannel(TransportDataChannelState)
    case message(String)
    case error(Error)
}

enum TransportError: Error, LocalizedError {
    case dataChannelUnavailable
    case dataChannelNotOpen
    case invalidJSONObject
    case notConnected

    var errorDescription: String? {
        switch self {
        case .dataChannelUnavailable:
            return "Data channel is unavailable"
        case .dataChannelNotOpen:
            return "Data channel is not open"
        case .invalidJSONObject:
            return "Payload is not a valid JSON object"
        case .notConnected:
            return "WebRTC peer is not connected"
        }
    }
}
