import Foundation

struct RealtimeReducer {
    @discardableResult
    func reduce(state: inout RealtimeState, action: RealtimeAction) -> [RealtimeAction] {
        switch action {
        case .transport(let transportAction):
            return reduceTransport(state: &state, action: transportAction)

        case .openAIEvent(let event):
            return reduceOpenAIEvent(state: &state, event: event)

        case .userIntent(let userIntent):
            return reduceUserIntent(state: &state, action: userIntent)

        case .internal(let internalAction):
            return reduceInternal(state: &state, action: internalAction)

        case .timer:
            return []
        }
    }

    private func reduceTransport(state: inout RealtimeState, action: TransportAction) -> [RealtimeAction] {
        switch action {
        case .stateChanged(let value):
            switch value {
            case .connected:
                state.session.status = SessionFSM.transition(from: state.session.status, event: .connected)
            case .disconnected:
                state.session.status = SessionFSM.transition(from: state.session.status, event: .disconnected)
            case .reconnecting:
                state.session.status = SessionFSM.transition(from: state.session.status, event: .reconnectRequested)
            }
        case .dataChannel(let channelState):
            switch channelState {
            case .open:
                state.session.status = SessionFSM.transition(from: state.session.status, event: .connected)
            case .closed:
                state.session.status = SessionFSM.transition(from: state.session.status, event: .disconnected)
            }
        case .message:
            break
        case .error(let message):
            state.session.status = SessionFSM.transition(from: state.session.status, event: .failed)
            state.session.lastError = message
        }
        return []
    }

    private func reduceUserIntent(state: inout RealtimeState, action: UserIntentAction) -> [RealtimeAction] {
        switch action {
        case .toggleMic:
            return []

        case .manualInterrupt:
            guard let activeTurnId = state.activeTurnId,
                  let responseId = state.turns[activeTurnId]?.activeResponseId else {
                return []
            }
            _ = reduceInternal(state: &state, action: .markResponseCancelled(responseId: responseId))
            if var turn = state.turns[activeTurnId] {
                turn.status = TurnFSM.transition(from: turn.status, event: .speechStarted)
                turn.activeResponseId = nil
                state.turns[activeTurnId] = turn
            }
            state.streaming.activeResponseId = nil
            state.streaming.activeAssistantText = ""
            return []

        case .sendText(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let turnId = state.activeTurnId ?? UUID()
            if state.turns[turnId] == nil {
                state.turns[turnId] = TurnContext(turnId: turnId, status: .thinking)
            } else {
                state.turns[turnId]?.status = .thinking
            }
            state.activeTurnId = turnId
            state.messages.append(
                ChatMessage(role: .user, text: trimmed, responseId: nil, turnId: turnId, isFinal: true)
            )
            return []

        case .confirmTool(let callId, _):
            guard var tool = state.tools[callId] else { return [] }
            if let responseId = tool.boundResponseId,
               state.responses[responseId]?.status == .cancelled {
                tool.status = ToolFSM.transition(from: tool.status, event: .ignored)
            } else {
                tool.status = ToolFSM.transition(from: tool.status, event: .running)
            }
            state.tools[callId] = tool
            return []

        case .rejectTool(let callId):
            guard var tool = state.tools[callId] else { return [] }
            tool.status = ToolFSM.transition(from: tool.status, event: .failed)
            state.tools[callId] = tool
            return []
        }
    }

    private func reduceInternal(state: inout RealtimeState, action: InternalAction) -> [RealtimeAction] {
        switch action {
        case .startNewTurn(let proposedId):
            let turnId = proposedId ?? UUID()
            if state.turns[turnId] == nil {
                state.turns[turnId] = TurnContext(turnId: turnId)
            }
            state.activeTurnId = turnId
            return []

        case .bindResponseToTurn(let responseId, let turnId):
            if state.turns[turnId] == nil {
                state.turns[turnId] = TurnContext(turnId: turnId)
            }
            state.turns[turnId]?.activeResponseId = responseId
            state.activeTurnId = turnId

            var response = state.responses[responseId] ?? ResponseContext(responseId: responseId)
            response.turnId = turnId
            state.responses[responseId] = response
            return []

        case .markResponseCancelled(let responseId):
            var response = state.responses[responseId] ?? ResponseContext(responseId: responseId)
            response.status = ResponseFSM.transition(from: response.status, event: .cancelled)
            response.audioActive = false
            response.lastEventType = "cancelled_locally"
            state.responses[responseId] = response

            if let turnId = response.turnId, var turn = state.turns[turnId] {
                turn.status = TurnFSM.transition(from: turn.status, event: .speechStarted)
                turn.activeResponseId = nil
                state.turns[turnId] = turn
            }
            return []

        case .appendAssistantDelta(let responseId, let delta):
            guard !delta.isEmpty else { return [] }
            var response = state.responses[responseId] ?? ResponseContext(responseId: responseId)
            guard response.status == .streaming else { return [] }
            response.textBuffer += delta
            state.responses[responseId] = response
            state.streaming.activeResponseId = responseId
            state.streaming.activeAssistantText = response.textBuffer
            upsertAssistantMessage(state: &state, responseId: responseId, turnId: response.turnId, text: response.textBuffer, isFinal: false)
            return []

        case .finalizeAssistant(let responseId, let status):
            var response = state.responses[responseId] ?? ResponseContext(responseId: responseId)
            response.status = status
            response.audioActive = false
            state.responses[responseId] = response
            if status == .completed {
                upsertAssistantMessage(state: &state, responseId: responseId, turnId: response.turnId, text: response.textBuffer, isFinal: true)
            }
            if let turnId = response.turnId,
               var turn = state.turns[turnId],
               turn.activeResponseId == responseId {
                turn.activeResponseId = nil
                turn.status = status == .cancelled
                    ? TurnFSM.transition(from: turn.status, event: .cancelled)
                    : TurnFSM.transition(from: turn.status, event: .ended)
                state.turns[turnId] = turn
                if state.activeTurnId == turnId {
                    state.activeTurnId = nil
                }
            }
            if state.streaming.activeResponseId == responseId {
                state.streaming.activeResponseId = nil
                state.streaming.activeAssistantText = ""
            }
            return []

        case .toolRequested(let callId):
            guard var tool = state.tools[callId] else { return [] }
            if let responseId = tool.boundResponseId,
               state.responses[responseId]?.status == .cancelled {
                tool.status = ToolFSM.transition(from: tool.status, event: .ignored)
            } else {
                tool.status = ToolFSM.transition(from: tool.status, event: .requested)
            }
            state.tools[callId] = tool
            return []

        case .toolResult(let callId, _, let success):
            guard var tool = state.tools[callId] else { return [] }
            if let responseId = tool.boundResponseId,
               state.responses[responseId]?.status == .cancelled {
                tool.status = ToolFSM.transition(from: tool.status, event: .ignored)
            } else {
                tool.status = ToolFSM.transition(from: tool.status, event: success ? .outputSent : .failed)
            }
            state.tools[callId] = tool
            return []

        case .bargeInConfirmed:
            guard let activeTurnId = state.activeTurnId,
                  let responseId = state.turns[activeTurnId]?.activeResponseId else {
                return []
            }
            _ = reduceInternal(state: &state, action: .markResponseCancelled(responseId: responseId))
            return []

        case .reconnectRequested:
            state.session.status = SessionFSM.transition(from: state.session.status, event: .reconnectRequested)
            return []

        case .reconnectAttempt:
            state.session.status = SessionFSM.transition(from: state.session.status, event: .reconnectRequested)
            return []

        case .reconnectSucceeded:
            state.session.status = SessionFSM.transition(from: state.session.status, event: .connected)
            state.session.lastError = nil
            return []

        case .reconnectFailed(let message):
            state.session.status = SessionFSM.transition(from: state.session.status, event: .failed)
            state.session.lastError = message
            return []
        }
    }

    private func reduceOpenAIEvent(state: inout RealtimeState, event: OpenAIEvent) -> [RealtimeAction] {
        // Update correlation maps whenever we have authoritative IDs.
        if let itemId = event.itemId, let responseId = event.responseId {
            state.itemToResponse[itemId] = responseId
        }
        if let callId = event.callId, let responseId = event.responseId {
            state.callToResponse[callId] = responseId
        }

        let resolvedResponseId = resolveResponseId(for: event, state: state)
        var followUps: [RealtimeAction] = []

        if let responseId = resolvedResponseId {
            followUps.append(contentsOf: reduceResponseScopedOpenAIEvent(state: &state, event: event, responseId: responseId))
        }

        if let callId = event.callId, isToolRelated(event: event) {
            followUps.append(contentsOf: reduceToolScopedOpenAIEvent(state: &state, event: event, callId: callId, resolvedResponseId: resolvedResponseId))
        } else if resolvedResponseId == nil, let callId = event.callId {
            followUps.append(contentsOf: reduceToolScopedOpenAIEvent(state: &state, event: event, callId: callId, resolvedResponseId: nil))
        } else if resolvedResponseId == nil {
            followUps.append(contentsOf: reduceSessionLevelOpenAIEvent(state: &state, event: event))
        }

        return followUps
    }

    private func reduceSessionLevelOpenAIEvent(state: inout RealtimeState, event: OpenAIEvent) -> [RealtimeAction] {
        if let message = event.errorMessage, !message.isEmpty {
            state.session.lastError = message
            let lower = message.lowercased()
            if lower.contains("session") || lower.contains("update") || lower.contains("auth") || lower.contains("unauthorized") {
                state.session.status = SessionFSM.transition(from: state.session.status, event: .failed)
            }
        }

        switch event.eventType {
        case "input_audio_buffer.speech_started":
            let turnId = state.activeTurnId ?? UUID()
            var turn = state.turns[turnId] ?? TurnContext(turnId: turnId)
            turn.status = TurnFSM.transition(from: turn.status, event: .speechStarted)
            state.turns[turnId] = turn
            state.activeTurnId = turnId

        case "input_audio_buffer.speech_stopped":
            if let turnId = state.activeTurnId, var turn = state.turns[turnId] {
                turn.status = TurnFSM.transition(from: turn.status, event: .speechStopped)
                state.turns[turnId] = turn
            }

        case "response.failed":
            state.session.status = SessionFSM.transition(from: state.session.status, event: .failed)

        case "error":
            state.session.status = SessionFSM.transition(from: state.session.status, event: .failed)
            state.session.lastError = event.errorMessage ?? "Unknown error"

        default:
            break
        }

        if let delta = event.userTranscriptDelta, !delta.isEmpty {
            let turnId = state.activeTurnId ?? UUID()
            var turn = state.turns[turnId] ?? TurnContext(turnId: turnId)
            turn.userTranscriptBuffer += delta
            state.turns[turnId] = turn
            state.activeTurnId = turnId
        }

        if let final = event.userTranscriptFinal, !final.isEmpty {
            let turnId = state.activeTurnId ?? UUID()
            var turn = state.turns[turnId] ?? TurnContext(turnId: turnId)
            turn.userTranscriptBuffer = final
            state.turns[turnId] = turn
            state.activeTurnId = turnId

            // Commit user speech as a single final chat message (no live transcription bubbles).
            let alreadyCommitted = state.messages.contains {
                $0.role == .user && $0.turnId == turnId && $0.text == final
            }
            if !alreadyCommitted {
                state.messages.append(
                    ChatMessage(role: .user, text: final, responseId: nil, turnId: turnId, isFinal: true)
                )
            }
        }

        return []
    }

    private func reduceResponseScopedOpenAIEvent(state: inout RealtimeState, event: OpenAIEvent, responseId: String) -> [RealtimeAction] {
        var followUps: [RealtimeAction] = []
        var response = state.responses[responseId] ?? ResponseContext(responseId: responseId)
        response.lastEventType = event.eventType

        if event.eventType == "response.created" {
            let turnId = response.turnId ?? state.activeTurnId ?? UUID()
            var turn = state.turns[turnId] ?? TurnContext(turnId: turnId)
            turn.activeResponseId = responseId
            turn.status = TurnFSM.transition(from: turn.status, event: .speechStopped)
            state.turns[turnId] = turn
            state.activeTurnId = turnId

            response.turnId = turnId
            response.status = .streaming
            state.responses[responseId] = response
            state.streaming.activeResponseId = responseId
            return followUps
        }

        if event.eventType == "response.completed" || event.eventType == "response.done" || event.eventType == "response.output_text.done" || event.eventType == "response.text.done" {
            state.responses[responseId] = response
            _ = reduceInternal(state: &state, action: .finalizeAssistant(responseId: responseId, status: .completed))
            return followUps
        }

        if event.eventType == "response.canceled" || event.eventType == "response.stopped" {
            state.responses[responseId] = response
            _ = reduceInternal(state: &state, action: .finalizeAssistant(responseId: responseId, status: .cancelled))
            return followUps
        }

        if event.eventType == "response.failed" {
            state.responses[responseId] = response
            _ = reduceInternal(state: &state, action: .finalizeAssistant(responseId: responseId, status: .failed))
            return followUps
        }

        if let audioState = event.audioState {
            switch audioState {
            case .started:
                if response.status == .streaming {
                    response.audioActive = true
                    state.responses[responseId] = response
                    if let turnId = response.turnId, var turn = state.turns[turnId] {
                        turn.status = TurnFSM.transition(from: turn.status, event: .assistantSpeaking)
                        state.turns[turnId] = turn
                    }
                } else {
                    state.responses[responseId] = response
                }
                recomputeTurnStatusIfPossible(state: &state, turnId: response.turnId)
                return followUps

            case .stopped, .cleared:
                response.audioActive = false
                state.responses[responseId] = response
                recomputeTurnStatusIfPossible(state: &state, turnId: response.turnId)
                return followUps
            }
        }

        if let delta = event.assistantTextDelta, !delta.isEmpty {
            state.responses[responseId] = response
            _ = reduceInternal(state: &state, action: .appendAssistantDelta(responseId: responseId, delta: delta))
            recomputeTurnStatusIfPossible(state: &state, turnId: response.turnId)
            return followUps
        }

        if let final = event.assistantTextFinal, !final.isEmpty, response.status == .streaming {
            let buffer = response.textBuffer
            // Hardening: final should win if it contains the buffer or is longer (common).
            // Rare case: final is shorter/unrelated; keep both separated.
            if buffer.isEmpty || final.contains(buffer) || final.count >= buffer.count {
                response.textBuffer = final
            } else {
                response.textBuffer = buffer + " " + final
            }
            state.responses[responseId] = response
            state.streaming.activeResponseId = responseId
            state.streaming.activeAssistantText = response.textBuffer
            upsertAssistantMessage(state: &state, responseId: responseId, turnId: response.turnId, text: response.textBuffer, isFinal: false)
            recomputeTurnStatusIfPossible(state: &state, turnId: response.turnId)
            return followUps
        }

        state.responses[responseId] = response
        return followUps
    }

    private func reduceToolScopedOpenAIEvent(state: inout RealtimeState, event: OpenAIEvent, callId: String, resolvedResponseId: String?) -> [RealtimeAction] {
        var tool = state.tools[callId] ?? ToolContext(callId: callId)
        if let responseId = resolvedResponseId ?? event.responseId ?? state.callToResponse[callId] {
            tool.boundResponseId = responseId
            tool.boundTurnId = state.responses[responseId]?.turnId ?? state.activeTurnId
            state.callToResponse[callId] = responseId
        } else if tool.boundResponseId == nil {
            tool.boundResponseId = state.activeTurnId.flatMap { state.turns[$0]?.activeResponseId }
            tool.boundTurnId = state.activeTurnId
        }

        if let turnId = tool.boundTurnId {
            state.callToTurn[callId] = turnId
        }

        if let responseId = tool.boundResponseId,
           state.responses[responseId]?.status == .cancelled {
            tool.status = ToolFSM.transition(from: tool.status, event: .ignored)
        } else if event.isToolArgumentsDone {
            tool.status = ToolFSM.transition(from: tool.status, event: .requested)
        }

        if let name = event.toolName, !name.isEmpty {
            tool.name = name
        }
        if let args = event.toolArgumentsJSON, !args.isEmpty {
            tool.argsJSON = args
        }

        state.tools[callId] = tool
        return event.isToolArgumentsDone ? [.internal(.toolRequested(callId: callId))] : []
    }

    private func upsertAssistantMessage(state: inout RealtimeState, responseId: String, turnId: UUID?, text: String, isFinal: Bool) {
        if let idx = state.messages.lastIndex(where: { $0.responseId == responseId && $0.role == .assistant }) {
            state.messages[idx].text = text
            state.messages[idx].isFinal = isFinal
            if state.messages[idx].turnId == nil {
                state.messages[idx].turnId = turnId
            }
            return
        }

        state.messages.append(
            ChatMessage(role: .assistant, text: text, responseId: responseId, turnId: turnId, isFinal: isFinal)
        )
    }

    private func resolveResponseId(for event: OpenAIEvent, state: RealtimeState) -> String? {
        if let responseId = event.responseId {
            return responseId
        }
        if let itemId = event.itemId, let mapped = state.itemToResponse[itemId] {
            return mapped
        }
        if let callId = event.callId, let mapped = state.callToResponse[callId] {
            return mapped
        }
        return nil
    }

    private func isToolRelated(event: OpenAIEvent) -> Bool {
        event.isToolArgumentsDone
            || event.toolName != nil
            || event.toolArgumentsJSON != nil
            || event.eventType.contains("function_call")
            || event.eventType.contains("tool_call")
    }

    private func recomputeTurnStatusIfPossible(state: inout RealtimeState, turnId: UUID?) {
        guard let turnId else { return }
        guard var turn = state.turns[turnId] else { return }
        guard turn.status != .ended && turn.status != .cancelled else { return }

        if let responseId = turn.activeResponseId, let response = state.responses[responseId] {
            if response.audioActive {
                turn.status = .speaking
            } else if response.status == .streaming {
                turn.status = .thinking
            } else {
                turn.status = .listening
            }
        } else {
            turn.status = .listening
        }

        state.turns[turnId] = turn
    }
}
