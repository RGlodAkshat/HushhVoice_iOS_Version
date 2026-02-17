import XCTest
@testable import HushhVoice

final class RealtimeReducerTests: XCTestCase {
    private func makeEvent(
        eventType: String,
        responseId: String? = nil,
        itemId: String? = nil,
        callId: String? = nil,
        assistantTextDelta: String? = nil,
        assistantTextFinal: String? = nil,
        isToolArgumentsDone: Bool = false,
        raw: String = "{}"
    ) -> OpenAIEvent {
        OpenAIEvent(
            eventType: eventType,
            kind: .known(eventType),
            responseId: responseId,
            itemId: itemId,
            callId: callId,
            assistantTextDelta: assistantTextDelta,
            assistantTextFinal: assistantTextFinal,
            userTranscriptDelta: nil,
            userTranscriptFinal: nil,
            audioState: nil,
            toolName: nil,
            toolArgumentsJSON: nil,
            isToolArgumentsDone: isToolArgumentsDone,
            errorMessage: nil,
            raw: raw
        )
    }

    func testAssistantTextDeltaExtractedInParserAndAppliedByReducer() throws {
        let reducer = RealtimeReducer()
        var state = RealtimeState()

        let raw = "{\"type\":\"response.output_text.delta\",\"response_id\":\"r1\",\"delta\":\"hello\"}"
        let event = try RealtimeEventParser.parse(rawJSON: raw)
        XCTAssertEqual(event.assistantTextDelta, "hello")

        _ = reducer.reduce(state: &state, action: .openAIEvent(event))
        XCTAssertEqual(state.responses["r1"]?.textBuffer, "hello")
    }

    func testLateDeltaAfterCancelIgnored() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()

        let turnId = UUID()
        state.activeTurnId = turnId
        state.turns[turnId] = TurnContext(turnId: turnId, status: .speaking, activeResponseId: "r1")
        state.responses["r1"] = ResponseContext(responseId: "r1", turnId: turnId, status: .streaming, textBuffer: "Hello")

        _ = reducer.reduce(state: &state, action: .userIntent(.manualInterrupt))
        XCTAssertEqual(state.responses["r1"]?.status, .cancelled)

        let event = makeEvent(
            eventType: "response.output_text.delta",
            responseId: "r1",
            assistantTextDelta: " late",
            raw: "{\"type\":\"response.output_text.delta\",\"response_id\":\"r1\",\"delta\":\" late\"}"
        )

        _ = reducer.reduce(state: &state, action: .openAIEvent(event))
        XCTAssertEqual(state.responses["r1"]?.textBuffer, "Hello")
    }

    func testToolResultAfterCancelIgnored() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()

        state.responses["r1"] = ResponseContext(responseId: "r1", status: .cancelled)
        state.tools["call_1"] = ToolContext(
            callId: "call_1",
            boundResponseId: "r1",
            boundTurnId: nil,
            name: "calendar.create",
            argsJSON: "{}",
            status: .running
        )

        _ = reducer.reduce(
            state: &state,
            action: .internal(.toolResult(callId: "call_1", output: "ok", success: true))
        )

        XCTAssertEqual(state.tools["call_1"]?.status, .ignored)
    }

    func testItemIdMappingRoutesEventCorrectly() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()

        state.itemToResponse["item_1"] = "r1"
        state.responses["r1"] = ResponseContext(responseId: "r1", status: .streaming, textBuffer: "A")

        let event = makeEvent(
            eventType: "response.output_text.delta",
            responseId: nil,
            itemId: "item_1",
            assistantTextDelta: "B"
        )

        _ = reducer.reduce(state: &state, action: .openAIEvent(event))
        XCTAssertEqual(state.responses["r1"]?.textBuffer, "AB")
    }

    func testReconnectStateTransitionsInDomain() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()
        state.session.status = .connected

        _ = reducer.reduce(state: &state, action: .internal(.reconnectRequested))
        XCTAssertEqual(state.session.status, .reconnecting)

        _ = reducer.reduce(state: &state, action: .internal(.reconnectAttempt(1)))
        XCTAssertEqual(state.session.status, .reconnecting)

        _ = reducer.reduce(state: &state, action: .internal(.reconnectSucceeded))
        XCTAssertEqual(state.session.status, .connected)

        _ = reducer.reduce(state: &state, action: .internal(.reconnectFailed("nope")))
        XCTAssertEqual(state.session.status, .failed)
        XCTAssertEqual(state.session.lastError, "nope")
    }

    func testOutOfOrderEventsRouteByResponseIdAndPreserveBuffer() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()

        let deltaEvent = makeEvent(
            eventType: "response.output_text.delta",
            responseId: "r2",
            assistantTextDelta: "hello",
            raw: "{\"type\":\"response.output_text.delta\",\"response_id\":\"r2\",\"delta\":\"hello\"}"
        )

        _ = reducer.reduce(state: &state, action: .openAIEvent(deltaEvent))
        XCTAssertEqual(state.responses["r2"]?.status, .streaming)
        XCTAssertEqual(state.responses["r2"]?.textBuffer, "hello")

        let createdEvent = makeEvent(
            eventType: "response.created",
            responseId: "r2",
            raw: "{\"type\":\"response.created\",\"response\":{\"id\":\"r2\"}}"
        )

        _ = reducer.reduce(state: &state, action: .openAIEvent(createdEvent))
        XCTAssertEqual(state.responses["r2"]?.textBuffer, "hello")
        XCTAssertEqual(state.responses["r2"]?.status, .streaming)
    }

    func testUserIntentSendTextAppendsUserMessage() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()

        _ = reducer.reduce(state: &state, action: .userIntent(.sendText("hi")))

        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages.first?.role, .user)
        XCTAssertEqual(state.messages.first?.text, "hi")
        XCTAssertEqual(state.messages.first?.isFinal, true)
    }

    func testUserTranscriptFinalCommitsSingleUserMessage() {
        let reducer = RealtimeReducer()
        var state = RealtimeState()
        let turnId = UUID()
        state.activeTurnId = turnId
        state.turns[turnId] = TurnContext(turnId: turnId)

        let e1 = OpenAIEvent(
            eventType: "input_audio_transcription.done",
            kind: .known("input_audio_transcription.done"),
            responseId: nil,
            itemId: nil,
            callId: nil,
            assistantTextDelta: nil,
            assistantTextFinal: nil,
            userTranscriptDelta: nil,
            userTranscriptFinal: "hello",
            audioState: nil,
            toolName: nil,
            toolArgumentsJSON: nil,
            isToolArgumentsDone: false,
            errorMessage: nil,
            raw: "{}"
        )
        _ = reducer.reduce(state: &state, action: .openAIEvent(e1))

        let e2 = OpenAIEvent(
            eventType: "input_audio_transcription.done",
            kind: .known("input_audio_transcription.done"),
            responseId: nil,
            itemId: nil,
            callId: nil,
            assistantTextDelta: nil,
            assistantTextFinal: nil,
            userTranscriptDelta: nil,
            userTranscriptFinal: "hello",
            audioState: nil,
            toolName: nil,
            toolArgumentsJSON: nil,
            isToolArgumentsDone: false,
            errorMessage: nil,
            raw: "{}"
        )
        _ = reducer.reduce(state: &state, action: .openAIEvent(e2))

        let userMessages = state.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1)
        XCTAssertEqual(userMessages.first?.text, "hello")
    }
}
