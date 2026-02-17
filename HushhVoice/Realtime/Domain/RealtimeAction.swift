import Foundation

enum RealtimeAction: Equatable {
    case transport(TransportAction)
    case openAIEvent(OpenAIEvent)
    case userIntent(UserIntentAction)
    case `internal`(InternalAction)
    case timer(TimerAction)
}

enum TransportAction: Equatable {
    case stateChanged(TransportConnectionState)
    case dataChannel(TransportDataChannelState)
    case message(String)
    case error(String)
}

enum UserIntentAction: Equatable {
    case toggleMic(isOn: Bool)
    case manualInterrupt
    case sendText(String)
    case confirmTool(callId: String, editedOutput: String?)
    case rejectTool(callId: String)
}

enum InternalAction: Equatable {
    case startNewTurn(turnId: UUID?)
    case bindResponseToTurn(responseId: String, turnId: UUID)
    case markResponseCancelled(responseId: String)
    case appendAssistantDelta(responseId: String, delta: String)
    case finalizeAssistant(responseId: String, status: ResponseStatus)
    case toolRequested(callId: String)
    case toolResult(callId: String, output: String, success: Bool)
    case reconnectRequested
    case reconnectAttempt(Int)
    case reconnectSucceeded
    case reconnectFailed(String)
    case bargeInConfirmed
}

enum TimerAction: Equatable {
    case reconnectBackoffTick
    case reconnectBackoffElapsed
}
