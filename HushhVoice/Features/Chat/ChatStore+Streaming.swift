import Foundation

extension ChatStore {
    // Apply inbound streaming events to local UI state.
    func applyStreamEvent(_ event: StreamEventEnvelope) {
        let payload = event.payload
        if let turnID = event.turn_id {
            setCurrentTurnID(turnID)
        }

        switch event.event_type {
        case "input_transcript.delta":
            if let text = payload.string("text") {
                updateVoiceDraft(text)
            }
        case "input_transcript.final":
            if let text = payload.string("text") {
                updateVoiceDraft(text)
                _ = finalizeVoiceDraft(appendToChat: false)
            }
        case "assistant_text.delta":
            if let text = payload.string("text") {
                appendAssistantStream(text)
            }
        case "assistant_text.final":
            if let text = payload.string("text"), !text.isEmpty {
                appendAssistantStream(text)
            }
            finalizeAssistantStream()
            setProgress(nil)
        case "state.change":
            if let to = payload.string("to") {
                setTurnState(mapTurnState(from: to))
            }
        case "turn.start":
            setTurnState(.thinking)
            setProgress(nil)
        case "turn.end":
            setTurnState(.idle)
            setProgress(nil)
            clearCurrentTurn()
        case "turn.cancelled":
            setTurnState(.cancelled)
            setProgress(nil)
            clearCurrentTurn()
        case "confirmation.request":
            let action = payload.string("action_type") ?? "action"
            let preview: String
            if let previewStr = payload.string("preview") {
                preview = previewStr
            } else if let previewObj = payload.object("preview") {
                preview = previewObj.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            } else {
                preview = "(preview)"
            }
            let rawID = payload.string("confirmation_request_id")
            let parsedID = rawID.flatMap { UUID(uuidString: $0) } ?? UUID()
            let confirmation = ChatConfirmation(id: parsedID, actionType: action, previewText: preview, status: .pending)
            addConfirmation(confirmation)
        case "tool_call.progress":
            let message = payload.string("message") ?? payload.string("status") ?? "Working..."
            setProgress(message)
        case "error":
            let message = payload.string("message") ?? "Unknown error"
            setTurnState(.errorRecoverable)
            showHint(message)
        default:
            break
        }
    }

    private func mapTurnState(from raw: String) -> ChatTurnState {
        switch raw {
        case "idle": return .idle
        case "listening": return .listening
        case "finalizing_input": return .finalizingInput
        case "thinking": return .thinking
        case "executing_tools": return .executingTools
        case "awaiting_confirmation": return .awaitingConfirmation
        case "speaking": return .speaking
        case "cancelled": return .cancelled
        case "error_recoverable": return .errorRecoverable
        case "error_terminal": return .errorTerminal
        default: return .idle
        }
    }
}
