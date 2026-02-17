# HushhVoice Realtime Voice Architecture (Current) — Code-Referenced

## 1) System Overview

- App runtime enters chat at `HushhVoice/HushhVoiceApp.swift:8` (`HushhVoiceApp`) and renders `ChatView()` at `HushhVoice/HushhVoiceApp.swift:13`.
- `ChatView` owns the realtime orchestrator `ChatRealtimeSession` (`HushhVoice/Features/Chat/ChatView.swift:8`) and wires callbacks in `configureRealtimeCallbacks()` (`HushhVoice/Features/Chat/ChatView.swift:743`).
- Realtime mode is explicitly forced in chat by constants `useFallbackMode = false` and `realtimeOnlyMode = true` (`HushhVoice/Features/Chat/ChatView.swift:61-62`).
- `ChatRealtimeSession.start()` does permission/audio session setup, backend config+token fetch, then WebRTC connect (`HushhVoice/Services/ChatRealtimeSession.swift:70-83`).
- WebRTC JSON control/events flow over data channel `"oai-events"` (`HushhVoice/Services/ChatRealtimeSession.swift:304`), while assistant audio is RTP media (no custom app-level audio sink).
- Incoming OpenAI events are parsed in `handleIncomingEvent(_:)` (`HushhVoice/Services/ChatRealtimeSession.swift:543`) and converted into internal `StreamEventEnvelope` events via `emit(...)` (`HushhVoice/Services/ChatRealtimeSession.swift:195`).
- `ChatView.handleStreamEvent(...)` filters by turn and dispatches to `ChatStore.applyStreamEvent(...)` (`HushhVoice/Features/Chat/ChatView.swift:891`, `HushhVoice/Features/Chat/ChatStore+Streaming.swift:5`).
- User/assistant message commit is stateful: user draft buffers in `ChatStore` (`beginVoiceDraft/finalizeVoiceDraft`), assistant stream buffers in `ChatRealtimeSession.assistantTextBuffer` and `ChatStore.streamingAssistantText` (`HushhVoice/Services/ChatRealtimeSession.swift:35`, `HushhVoice/Features/Chat/ChatStore.swift:16-20`).
- Barge-in cancels current response via `response.cancel` + `output_audio_buffer.clear` (`HushhVoice/Services/ChatRealtimeSession.swift:149-150`) and resets turn/audio flags.
- Realtime tool calls are handled by backend bridge endpoints `/chat/agent/tool` and `/chat/agent/confirm`, then returned as `conversation.item.create` with `function_call_output` (`HushhVoice/Services/ChatRealtimeSession.swift:907`, `HushhVoice/Services/ChatRealtimeSession.swift:965`, `HushhVoice/Services/ChatRealtimeSession.swift:1005`).

## 2) Component Map

| Component | Responsibility | Key files/symbols | Threading/actors notes |
|---|---|---|---|
| App entry | Launches chat runtime | `HushhVoice/HushhVoiceApp.swift:8` `HushhVoiceApp.body` | SwiftUI scene lifecycle |
| Chat orchestrator | Owns realtime/store/audio managers; routes events to UI/store | `HushhVoice/Features/Chat/ChatView.swift` (`configureRealtimeCallbacks`, `handleStreamEvent`, `toggleMic`) | Main-thread UI state (`@StateObject`); callback hops to main (`DispatchQueue.main.async`) |
| Realtime session | WebRTC setup, OpenAI event parsing, turn/response state, tool bridge | `HushhVoice/Services/ChatRealtimeSession.swift` (`start`, `connectWebRTC`, `handleIncomingEvent`, `interruptForBargeIn`) | `@MainActor` class; async tasks for network/tool calls |
| Chat store | Persistent chat model + drafts + streaming assistant text | `HushhVoice/Features/Chat/ChatStore.swift` | `@MainActor`; persists via `UserDefaults` |
| Stream reducer | Applies internal stream events to store state | `HushhVoice/Features/Chat/ChatStore+Streaming.swift` | Runs on main through chat dispatch path |
| Event envelope | Canonical internal event structure and IDs | `HushhVoice/Models/StreamingEvent.swift` (`StreamEventEnvelope`, `JSONValue`) | Codable transport model |
| Local STT loop (optional) | AVAudioEngine + SFSpeech partial/final callbacks | `HushhVoice/Services/AudioCaptureManager.swift` | Own callbacks; feeds `ChatView` closures |
| Fallback TTS player (non-realtime path) | Plays backend `/tts` or AVSpeech | `HushhVoice/Services/SpeechManager.swift` | AVAudioPlayer/AVSpeech on main actor calls |
| Debug logging | Structured logs with sid/tid/mid | `HushhVoice/Features/Chat/DebugLogger.swift` | Append on main queue; prints immediately |

## 3) Sequence Diagrams (text-based)

### (a) Normal voice turn (user -> model -> streaming -> commit)

```text
User taps mic
 -> ChatView.toggleMic() unmute realtime
 -> ChatRealtimeSession.setMuted(false) enables local WebRTC audio track

User speaks
 -> OpenAI server VAD emits input_audio_buffer.speech_started
 -> ChatRealtimeSession.handleIncomingEvent() starts turn (turn.start)
 -> emits state.change(listening), input_transcript.delta("")

Transcription stream
 -> input_audio_transcription.delta... events
 -> ChatRealtimeSession appends userTranscriptBuffer
 -> emits input_transcript.delta(buffer)

Final transcription
 -> ...transcription.completed/done
 -> ChatRealtimeSession emits input_transcript.final(text)
 -> emits state.change(thinking)
 -> sendEvent(response.create)

Assistant generation
 -> response.created
 -> response output text/audio events
 -> assistant_text.delta events emitted to ChatView/Store
 -> output_audio_buffer.started -> assistant_audio.start + state.change(speaking)

Completion
 -> response.done/response.completed
 -> assistant_text.final emitted
 -> turn.end emitted
 -> ChatStore commits assistant stream and clears current turn
```

Refs: `HushhVoice/Services/ChatRealtimeSession.swift:601-667`, `HushhVoice/Services/ChatRealtimeSession.swift:671-737`, `HushhVoice/Features/Chat/ChatView.swift:891-1021`, `HushhVoice/Features/Chat/ChatStore+Streaming.swift:19-53`.

### (b) Barge-in interrupt turn (cancel + audio stop + state reset)

```text
Assistant currently speaking/thinking
 -> OpenAI emits input_audio_buffer.speech_started while output active
 -> ChatRealtimeSession.armServerBargeInConfirmation()

If sustained speech meets thresholds
 -> maybeConfirmServerBargeIn() passes duration+content gates
 -> ChatRealtimeSession.interruptForBargeIn()
    sends response.cancel
    sends output_audio_buffer.clear
    clears response/audio/text buffers
    emits assistant_audio.end (if active)
    emits turn.cancelled (old turn)
    emits state.change(listening)
 -> starts new turn and emits input_transcript.delta(buffered speech)
 -> final transcript emits input_transcript.final
 -> sends response.create for new query
```

Refs: `HushhVoice/Services/ChatRealtimeSession.swift:462-523`, `HushhVoice/Services/ChatRealtimeSession.swift:137-169`, `HushhVoice/Services/ChatRealtimeSession.swift:625-667`, `HushhVoice/Features/Chat/ChatView.swift:1010-1017`.

### (c) Tool call turn (tool request -> execution -> tool output -> continue)

```text
Model emits tool intent
 -> response.output_item.added/done with item.type=function_call
 -> ChatRealtimeSession caches call_id/name/args

Model emits function_call_arguments.done
 -> ChatRealtimeSession.forwardToolCall() async to backend /chat/agent/tool

If backend requires confirmation
 -> emit confirmation.request to UI
 -> user accept/edit/reject in ChatView
 -> ChatRealtimeSession.confirmToolCall()
 -> /chat/agent/confirm (accept/edit) OR immediate rejection output

Tool output back to model
 -> sendEvent(conversation.item.create {type:function_call_output, call_id, output})
 -> requestResponseCreate(reason: tool_output/tool_confirmed/etc)
 -> model continues response generation
```

Refs: `HushhVoice/Services/ChatRealtimeSession.swift:858-887`, `HushhVoice/Services/ChatRealtimeSession.swift:902-1001`, `HushhVoice/Services/ChatRealtimeSession.swift:1004-1013`, `HushhVoice/Features/Chat/ChatView.swift:1080-1099`.

## 4) WebRTC Details

### Offer/answer flow

- Peer connection factory and peer are created in `connectWebRTC(clientSecret:)` (`HushhVoice/Services/ChatRealtimeSession.swift:281-293`).
- Local audio track is created and added: `audioTrack(with:..., trackId: "audio0")`, `peer.add(track, streamIds:["stream0"])` (`HushhVoice/Services/ChatRealtimeSession.swift:295-300`).
- Data channel is created label `"oai-events"` ordered (`HushhVoice/Services/ChatRealtimeSession.swift:302-309`).
- Offer is generated and set local description (`HushhVoice/Services/ChatRealtimeSession.swift:311-326`).
- SDP offer is POSTed to `https://api.openai.com/v1/realtime/calls` with headers:
  - `Authorization: Bearer <clientSecret>`
  - `Content-Type: application/sdp`
  - `OpenAI-Beta: realtime=v1`
  (`HushhVoice/Services/ChatRealtimeSession.swift:338-347`).
- Answer SDP is set as remote description (`HushhVoice/Services/ChatRealtimeSession.swift:328-335`).

### ICE and connection lifecycle

- No explicit ICE servers are configured in `LKRTCConfiguration` (only `sdpSemantics = .unifiedPlan`) (`HushhVoice/Services/ChatRealtimeSession.swift:283-284`).
- ICE/signaling/connection changes are logged only (`didChange` delegate methods) (`HushhVoice/Services/ChatRealtimeSession.swift:1222-1236`).
- On data channel non-open state, session moves to `.error` with `lastError = "Realtime data channel closed"` (`HushhVoice/Services/ChatRealtimeSession.swift:1253-1260`).
- Teardown is manual via `stop()` (`HushhVoice/Services/ChatRealtimeSession.swift:93-105`).
- No automatic reconnect/timeout retry loop exists in `ChatRealtimeSession`.

### Data channel protocol

- Outgoing JSON uses `sendEvent(_:)` (serializes `[String:Any]`, sends non-binary) (`HushhVoice/Services/ChatRealtimeSession.swift:356-360`).
- Incoming JSON handled in `dataChannel(...didReceiveMessageWith:)` -> `handleIncomingEvent(_:)` (`HushhVoice/Services/ChatRealtimeSession.swift:1266-1271`).
- Session-level initialization event `session.update` is sent when channel opens (`HushhVoice/Services/ChatRealtimeSession.swift:1242-1247`, `HushhVoice/Services/ChatRealtimeSession.swift:363-427`).

## 5) Streaming State + IDs

### IDs and where they live

- Internal stream envelope IDs:
  - `event_id`, `session_id`, `turn_id`, `seq`, `turn_seq` in `StreamEventEnvelope` (`HushhVoice/Models/StreamingEvent.swift:67-77`).
- Session ID generation:
  - `ChatRealtimeSession.sessionID = UUID()` (`HushhVoice/Services/ChatRealtimeSession.swift:30`).
- Turn ID generation:
  - `currentTurnID = UUID()` in `startTurnIfNeeded` (`HushhVoice/Services/ChatRealtimeSession.swift:186-191`).
- OpenAI IDs extracted:
  - `response_id`, `item_id`, `call_id` parsed in `eventMeta` (`HushhVoice/Services/ChatRealtimeSession.swift:1194-1199`).
- Important limitation:
  - `response_id/item_id` are logged but not used for routing/filtering decisions.

### Event routing and filtering

- Realtime -> UI bridge:
  - `ChatRealtimeSession.emit(...)` -> `ChatView.realtime.onEvent` -> `handleStreamEvent` (`HushhVoice/Services/ChatRealtimeSession.swift:195-209`, `HushhVoice/Features/Chat/ChatView.swift:743-748`).
- `ChatView` filtering:
  - Drops required events missing `turn_id` (`HushhVoice/Features/Chat/ChatView.swift:892-907`).
  - Drops events for canceled turn IDs (`HushhVoice/Features/Chat/ChatView.swift:908-913`).
  - Drops mismatched current turn IDs except limited bootstrapping event types (`HushhVoice/Features/Chat/ChatView.swift:914-926`).

### Streaming buffers and final commits

- User transcript buffers:
  - `ChatRealtimeSession.userTranscriptBuffer` (server transcript assembly) (`HushhVoice/Services/ChatRealtimeSession.swift:34`).
  - `ChatView.pendingSpeechTranscript` (UI-side buffering/merge) (`HushhVoice/Features/Chat/ChatView.swift:57`).
  - `ChatStore.draftUserText` for draft message rendering/commit (`HushhVoice/Features/Chat/ChatStore.swift:11-14`, `HushhVoice/Features/Chat/ChatStore.swift:309-339`).
- Assistant text buffers:
  - `ChatRealtimeSession.assistantTextBuffer` + source arbitration (`HushhVoice/Services/ChatRealtimeSession.swift:35`, `HushhVoice/Services/ChatRealtimeSession.swift:671-700`).
  - `ChatStore.streamingAssistantText` for UI stream (`HushhVoice/Features/Chat/ChatStore.swift:16-20`, `HushhVoice/Features/Chat/ChatStore.swift:432-458`).
- Finalization points:
  - User final: on input transcription final/speech_stopped emits `input_transcript.final` and `response.create` (`HushhVoice/Services/ChatRealtimeSession.swift:625-667`).
  - Assistant final: on `response.done/completed/...` -> `assistant_text.final` + `turn.end` (`HushhVoice/Services/ChatRealtimeSession.swift:702-737`).

### JSON event contract (OpenAI-facing)

#### Sent by app (JSON over data channel)

| Event type | Where sent | IDs carried | State mutation |
|---|---|---|---|
| `session.update` | `sendSessionUpdate()` | None explicit; session context in OpenAI | Enables modalities/tools/turn_detection/transcription |
| `conversation.item.create` (user message) | `sendUserText()` | OpenAI-side item id assigned server-side; local turn already active | Starts user text turn path |
| `response.create` | `sendResponseCreate()` | None explicit | Sets `responseInProgress = true` |
| `response.cancel` | `interruptForBargeIn()` | None explicit | Cancels active model response |
| `output_audio_buffer.clear` | `interruptForBargeIn()` | None explicit | Clears active output audio |
| `conversation.item.create` (`function_call_output`) | `sendToolOutput()` | `call_id` | Feeds tool result back to model |

Refs: `HushhVoice/Services/ChatRealtimeSession.swift:125-132`, `HushhVoice/Services/ChatRealtimeSession.swift:149-150`, `HushhVoice/Services/ChatRealtimeSession.swift:427`, `HushhVoice/Services/ChatRealtimeSession.swift:431-439`, `HushhVoice/Services/ChatRealtimeSession.swift:1005-1012`.

#### Received and handled from OpenAI

| Event type(s) handled | Where handled | IDs parsed | State mutation |
|---|---|---|---|
| `session.created`, `session.updated` | `handleIncomingEvent` | `response_id/item_id/call_id` parsed for logs | `lastSessionUpdateStatus = "ack"` |
| `error` | `handleIncomingEvent` | parsed via `obj["error"]` | emits internal `error` event |
| `response.created` | `handleIncomingEvent` | stores `lastResponseId` | marks response active; emits thinking state |
| `output_audio_buffer.started`, `response.audio.started` | `handleIncomingEvent` | parsed meta | `outputAudioActive = true`; emits `assistant_audio.start` |
| `output_audio_buffer.stopped/cleared`, `response.audio.done/stopped` | `handleIncomingEvent` | parsed meta | emits `assistant_audio.end`; clears speaking flag |
| `input_audio_buffer.speech_started/speech_stopped` | `handleIncomingEvent` | parsed meta | turn/listening transitions, barge-in arming/disarm |
| input transcription delta/final variants | `extractUserTranscriptDelta/Final` | parsed meta | builds user transcript; emits `input_transcript.delta/final`; sends `response.create` on final |
| assistant text delta variants (`response.output_text.delta`, `response.text.delta`, content_part, audio_transcript deltas) | `extractAssistantDelta` | parsed meta | emits `assistant_text.delta` |
| `response.output_text.done`, `response.done`, `response.completed` | `handleIncomingEvent` | parsed meta | emits `assistant_text.final`; ends turn |
| `response.failed`, `response.canceled`, `response.stopped` | `handleIncomingEvent` | parsed meta | emits final if buffer exists; ends turn |
| `response.output_item.added/done` + `function_call_arguments.done`/`tool_call_arguments.done` | `handleToolEvents` | `call_id` critical | starts tool execution task |

Refs: `HushhVoice/Services/ChatRealtimeSession.swift:543-718`, `HushhVoice/Services/ChatRealtimeSession.swift:800-887`.

## 6) The 3 Async Loops + Race Conditions

### Loop A: Mic/STT loop (optional in realtime mode)

- Source: `AudioCaptureManager` recognition callbacks (`onSpeechStart/onPartial/onFinal`) (`HushhVoice/Services/AudioCaptureManager.swift:166-183`, `HushhVoice/Services/AudioCaptureManager.swift:273-285`).
- Consumer: `ChatView.configureAudioCaptureCallbacks()` (`HushhVoice/Features/Chat/ChatView.swift:752-824`).
- Current chat runtime: effectively disabled for realtime-only by `enableLocalTranscription = false` and callback guards (`HushhVoice/Features/Chat/ChatView.swift:52`, `HushhVoice/Features/Chat/ChatView.swift:88`, `HushhVoice/Features/Chat/ChatView.swift:119-123`).

### Loop B: Model event loop (WebRTC data channel)

- Source: `LKRTCDataChannelDelegate.didReceiveMessageWith` (`HushhVoice/Services/ChatRealtimeSession.swift:1266-1271`).
- Processor: `handleIncomingEvent(_:)` parses OpenAI protocol and emits app stream events (`HushhVoice/Services/ChatRealtimeSession.swift:543-718`).

### Loop C: UI/store loop

- Source: `ChatRealtimeSession.emit(...)` internal events (`HushhVoice/Services/ChatRealtimeSession.swift:195-209`).
- Router: `ChatView.handleStreamEvent(...)` with turn filtering (`HushhVoice/Features/Chat/ChatView.swift:891-1021`).
- Reducer: `ChatStore.applyStreamEvent(...)` mutates chat state and message streams (`HushhVoice/Features/Chat/ChatStore+Streaming.swift:5-78`).

### Top 10 concrete race conditions

| # | Race window | Code location | Symptom |
|---|---|---|---|
| 1 | Outgoing event before data channel ready | `HushhVoice/Services/ChatRealtimeSession.swift:356-359` | Event silently dropped (`conversation.item.create`, `response.cancel`, etc.) |
| 2 | UI says “Reconnecting…” but no reconnect call | `HushhVoice/Features/Chat/ChatView.swift:492-500` | Session stays errored/muted indefinitely |
| 3 | Data channel closes -> `.error` without restart | `HushhVoice/Services/ChatRealtimeSession.swift:1253-1260` | Chat stops receiving/sending until manual restart |
| 4 | Turn filter drops valid events on out-of-order turn assignment | `HushhVoice/Features/Chat/ChatView.swift:904-926` | Missing assistant/user updates in UI |
| 5 | No `response_id`-based filtering after cancel/new turn | `HushhVoice/Services/ChatRealtimeSession.swift:1194-1199`, `HushhVoice/Services/ChatRealtimeSession.swift:671-700` | Late old deltas can be attributed to current turn |
| 6 | Barge-in arm clears `userTranscriptBuffer` early | `HushhVoice/Services/ChatRealtimeSession.swift:462-470` | Short utterance before threshold can be discarded |
| 7 | `responseInProgress` local flag can desync server truth | `HushhVoice/Services/ChatRealtimeSession.swift:431-459` | `response.create` blocked/queued unexpectedly |
| 8 | Tool async completion after turn changes | `HushhVoice/Services/ChatRealtimeSession.swift:902-961` | Tool output may continue wrong conversational context |
| 9 | Tool UI events require turn_id; late nil-turn tool events are dropped | `HushhVoice/Features/Chat/ChatView.swift:892-907`, `HushhVoice/Features/Chat/ChatView.swift:987`, `HushhVoice/Features/Chat/ChatView.swift:1018` | No confirmation/progress shown despite backend activity |
| 10 | Dual assistant text sources (`output_text` + `audio_transcript`) switch heuristically | `HushhVoice/Services/ChatRealtimeSession.swift:671-699`, `HushhVoice/Services/ChatRealtimeSession.swift:740-776` | Duplicate or uneven streaming text |

## 7) Known Gaps / TODOs / Uncertainties

- **Gap:** No explicit reconnect strategy in realtime session class.
  - TODO: Add deterministic reconnect state machine with backoff and explicit restart trigger.
- **Gap:** Response correlation is mostly by local turn, not by `response_id/item_id`.
  - TODO: Track active `response_id` and reject stale deltas/tool callbacks from canceled responses.
- **Gap:** Tool call lifecycle is not strongly response-bound (only `call_id` + optional `turn_id` to backend).
  - TODO: Persist `call_id -> turn_id -> response_id` mapping and enforce before UI/model continuation.
- **Gap:** WebRTC audio output sink is implicit (no explicit app-level render control).
  - TODO: Document/verify exact audio route behavior under interruptions and route changes.

### Questions for you (to close remaining uncertainties)

1. Should short barge-ins (for example 1-word commands like “stop”) bypass the current minimum transcript gating?  
   Unlocks: final barge-in threshold policy.
2. Do you want strict response-id isolation (drop any event not matching active `response_id`) even if it risks dropping rare valid late chunks?  
   Unlocks: stale-event protection strategy.
3. For tool calls, should tool output be ignored if turn was canceled before backend returned?  
   Unlocks: deterministic post-cancel tool handling.
4. Is server-side turn detection config guaranteed stable per session from `/chat/agent/config`, or can backend hot-update it mid-call?  
   Unlocks: whether client must support runtime `session.update` refresh.
5. Is onboarding voice (`KaiVoiceViewModel`) intentionally separate from chat realtime, or should chat and onboarding converge to one shared realtime engine?  
   Unlocks: whether to de-duplicate implementations now.
