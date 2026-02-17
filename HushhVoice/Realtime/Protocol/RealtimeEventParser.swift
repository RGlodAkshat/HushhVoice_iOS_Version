import Foundation

enum RealtimeEventParserError: Error, LocalizedError {
    case invalidJSON
    case missingEventType

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Raw event is not valid JSON"
        case .missingEventType:
            return "Realtime event is missing the `type` field"
        }
    }
}

enum RealtimeEventParser {
    static func parse(rawJSON: String) throws -> OpenAIEvent {
        guard let data = rawJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealtimeEventParserError.invalidJSON
        }

        guard let eventType = extractEventType(from: object) else {
            throw RealtimeEventParserError.missingEventType
        }

        let responseId = extractResponseId(from: object)
        let itemId = extractItemId(from: object)
        let callId = extractCallId(from: object)

        let assistantTextDelta = extractAssistantTextDelta(eventType: eventType, object: object)
        let assistantTextFinal = extractAssistantTextFinal(eventType: eventType, object: object)

        let userTranscriptDelta = extractUserTranscriptDelta(eventType: eventType, object: object)
        let userTranscriptFinal = extractUserTranscriptFinal(eventType: eventType, object: object)

        let audioState = extractAudioState(eventType: eventType)

        let (toolName, toolArgsJSON, toolArgsDone) = extractToolFields(eventType: eventType, object: object)
        let errorMessage = extractErrorMessage(eventType: eventType, object: object)

        return OpenAIEvent(
            eventType: eventType,
            kind: OpenAIEvent.Kind(eventType: eventType),
            responseId: responseId,
            itemId: itemId,
            callId: callId,
            assistantTextDelta: assistantTextDelta,
            assistantTextFinal: assistantTextFinal,
            userTranscriptDelta: userTranscriptDelta,
            userTranscriptFinal: userTranscriptFinal,
            audioState: audioState,
            toolName: toolName,
            toolArgumentsJSON: toolArgsJSON,
            isToolArgumentsDone: toolArgsDone,
            errorMessage: errorMessage,
            raw: rawJSON
        )
    }

    private static func extractEventType(from object: [String: Any]) -> String? {
        string(at: ["type"], in: object)
            ?? deepString(forKey: "type", in: object)
    }

    private static func extractResponseId(from object: [String: Any]) -> String? {
        string(at: ["response_id"], in: object)
            ?? string(at: ["response", "id"], in: object)
            ?? deepString(forKey: "response_id", in: object)
            ?? deepString(forKey: "id", in: object["response"])
    }

    private static func extractItemId(from object: [String: Any]) -> String? {
        string(at: ["item_id"], in: object)
            ?? string(at: ["item", "id"], in: object)
            ?? deepString(forKey: "item_id", in: object)
            ?? deepString(forKey: "id", in: object["item"])
    }

    private static func extractCallId(from object: [String: Any]) -> String? {
        string(at: ["call_id"], in: object)
            ?? string(at: ["item", "call_id"], in: object)
            ?? deepString(forKey: "call_id", in: object)
    }

    private static func extractAssistantTextDelta(eventType: String, object: [String: Any]) -> String? {
        switch eventType {
        case "response.output_text.delta", "response.text.delta",
             "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            return string(at: ["delta"], in: object)
                ?? string(at: ["text"], in: object)
                ?? string(at: ["transcript"], in: object)
        default:
            return nil
        }
    }

    private static func extractAssistantTextFinal(eventType: String, object: [String: Any]) -> String? {
        switch eventType {
        case "response.output_text.done", "response.text.done",
             "response.output_audio_transcript.done", "response.audio_transcript.done":
            return string(at: ["text"], in: object)
                ?? string(at: ["transcript"], in: object)
                ?? string(at: ["final"], in: object)
        default:
            return nil
        }
    }

    private static func extractUserTranscriptDelta(eventType: String, object: [String: Any]) -> String? {
        // Some implementations emit `input_audio_transcription.delta` or similar.
        if eventType.hasSuffix(".delta"), eventType.contains("input_audio_transcription") {
            return string(at: ["delta"], in: object)
                ?? string(at: ["transcript"], in: object)
                ?? string(at: ["text"], in: object)
        }
        return nil
    }

    private static func extractUserTranscriptFinal(eventType: String, object: [String: Any]) -> String? {
        if (eventType.hasSuffix(".done") || eventType.hasSuffix(".completed")) && eventType.contains("input_audio_transcription") {
            return string(at: ["transcript"], in: object)
                ?? string(at: ["text"], in: object)
                ?? string(at: ["final"], in: object)
        }
        return nil
    }

    private static func extractAudioState(eventType: String) -> OpenAIEvent.AudioState? {
        switch eventType {
        case "output_audio_buffer.started", "response.audio.started":
            return .started
        case "output_audio_buffer.stopped", "response.audio.done", "response.audio.stopped":
            return .stopped
        case "output_audio_buffer.cleared":
            return .cleared
        default:
            return nil
        }
    }

    private static func extractToolFields(eventType: String, object: [String: Any]) -> (name: String?, argsJSON: String?, argsDone: Bool) {
        let name = string(at: ["name"], in: object)
            ?? string(at: ["item", "name"], in: object)
            ?? deepString(forKey: "name", in: object["item"])

        let argsAny = value(at: ["arguments"], in: object) ?? value(at: ["item", "arguments"], in: object)
        let argsJSON = argsAny.flatMap { stringifyJSON($0) }

        var argsDone = false
        if eventType.contains("arguments.done") {
            argsDone = true
        }

        if eventType == "response.output_item.added" {
            // If the added output item is a function call and we already have arguments, treat it as "done".
            if string(at: ["item", "type"], in: object) == "function_call", argsJSON != nil {
                argsDone = true
            }
        }

        if eventType.contains("function_call") && eventType.hasSuffix(".done") && argsJSON != nil {
            argsDone = true
        }

        return (name.isEmptyOrNil ? nil : name, argsJSON, argsDone)
    }

    private static func extractErrorMessage(eventType: String, object: [String: Any]) -> String? {
        guard eventType == "error" else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private static func string(at path: [String], in object: [String: Any]) -> String? {
        guard !path.isEmpty else { return nil }

        var current: Any = object
        for segment in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[segment] else {
                return nil
            }
            current = next
        }

        return current as? String
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        guard !path.isEmpty else { return nil }

        var current: Any = object
        for segment in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[segment] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func stringifyJSON(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let output = String(data: data, encoding: .utf8) {
            return output
        }
        return "\(value)"
    }

    private static func deepString(forKey key: String, in object: Any?, maxDepth: Int = 8) -> String? {
        guard maxDepth >= 0, let object else { return nil }

        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? String {
                return value
            }
            for value in dictionary.values {
                if let found = deepString(forKey: key, in: value, maxDepth: maxDepth - 1) {
                    return found
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let found = deepString(forKey: key, in: value, maxDepth: maxDepth - 1) {
                    return found
                }
            }
        }

        return nil
    }
}

private extension Optional where Wrapped == String {
    var isEmptyOrNil: Bool {
        switch self {
        case .none:
            return true
        case .some(let value):
            return value.isEmpty
        }
    }
}
