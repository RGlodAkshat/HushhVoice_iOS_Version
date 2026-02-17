import Foundation
import AVFoundation
import LiveKitWebRTC

@MainActor
final class ChatRealtimeSession: NSObject, ObservableObject {
    enum State: String {
        case idle
        case connecting
        case connected
        case error
    }

    @Published private(set) var state: State = .idle
    @Published var isMuted: Bool = true
    @Published var lastError: String?
    @Published private(set) var lastSessionUpdateStatus: String?
    @Published private(set) var serverVadEnabled: Bool = false

    var onEvent: ((StreamEventEnvelope) -> Void)?

    private var factory: LKRTCPeerConnectionFactory?
    private var peer: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var localAudioTrack: LKRTCAudioTrack?

    private var seq: Int = 0
    private var turnSeq: Int = 0
    private var currentTurnID: String?
    private let sessionID: String = UUID().uuidString

    var sessionId: String { sessionID }

    private var userTranscriptBuffer = ""
    private var assistantTextBuffer = ""
    private var pendingAssistantText = ""
    private var assistantTextGateOpen = false
    private var didFinalizeInput = false
    private var responseInProgress = false
    private var outputAudioActive = false
    private var pendingResponseCreateReason: String?

    private var sessionUpdateCount = 0
    private var lastSessionUpdateCaller: String?
    private var sessionUpdateSent = false
    private var lastResponseId: String?
    private var seenTextDeltaThisResponse = false
    private var seenAudioDeltaThisResponse = false
    private var lastAssistantDelta: String?
    private var lastAssistantDeltaAt: Date?
    private var awaitingServerBargeInConfirmation = false
    private var serverBargeInSpeechStartedAt: Date?
    private var serverBargeInTranscriptBuffer = ""
    private let serverBargeInMinSpeechDuration: TimeInterval = 0.8
    private let serverBargeInMinTranscriptChars: Int = 6
    private let minValidSpeechDuration: TimeInterval = 0.8

    private var userSpeechStartedAt: Date?
    private var lastSpeechDuration: TimeInterval = 0
    private var lastSpeechWasValid: Bool = false

    private var pendingToolArgs: [String: String] = [:]
    private var pendingToolNames: [String: String] = [:]
    private var pendingConfirmations: [String: PendingToolCall] = [:]
    private var lastPrefetchAt: Date?
    private var lastPrefetchHint: String = ""

    private var config: ChatAgentConfig?
    private var userId: String = ""
    private var googleToken: String?

    private let debugEnabled = true
    var useLocalSTTOnly: Bool = true

    func start(userId: String) {
        self.userId = userId
        sessionUpdateSent = false
        state = .connecting
        dbg("ChatRealtime", "start", fields: ["user_id": userId])
        Task {
            do {
                try await ensurePermissions()
                try configureAudioSession()
                let cfg = try await fetchConfig(userId: userId)
                let token = try await fetchToken()
                self.config = cfg
                try await connectWebRTC(clientSecret: token)
                state = .connected
                dbg("ChatRealtime", "connected")
            } catch {
                lastError = error.localizedDescription
                state = .error
                dbg("ChatRealtime", "error", message: error.localizedDescription)
            }
        }
    }

    func stop() {
        peer?.close()
        dataChannel = nil
        localAudioTrack = nil
        peer = nil
        factory = nil
        state = .idle
        sessionUpdateSent = false
        pendingResponseCreateReason = nil
        clearServerBargeInConfirmation()
        deactivateAudioSession()
        dbg("ChatRealtime", "stop")
    }

    func setMuted(_ muted: Bool) {
        let wasMuted = isMuted
        isMuted = muted
        localAudioTrack?.isEnabled = !muted && !useLocalSTTOnly
        // If the user stops talking by muting, only commit if we have a valid speech window.
        if !useLocalSTTOnly, !wasMuted, muted {
            let duration = currentSpeechDuration()
            if duration >= minValidSpeechDuration {
                sendInputAudioBufferCommit(reason: "mic_muted")
            } else if duration > 0 {
                emitHintPleaseSpeakMore()
                endTurnIfNeeded()
                resetSpeechWindow()
            }
        }
        dbg("ChatRealtime", "mute", fields: [
            "muted": muted,
            "use_local_stt_only": useLocalSTTOnly,
            "track_enabled": localAudioTrack?.isEnabled ?? false,
        ])
    }

    func updateGoogleToken(_ token: String?) {
        googleToken = token
        dbg("ChatRealtime", "google_token", fields: ["present": token != nil])
    }

    func sendUserText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startTurnIfNeeded(inputMode: "text")
        maybePrefetch(for: trimmed)
        dbg("ChatRealtime", "send_user_text", fields: ["len": trimmed.count])

        sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": trimmed]],
            ],
        ])
        emit(eventType: "state.change", payload: ["from": .string("listening"), "to": .string("thinking"), "reason": .string("typed_input")], role: "system")
        sendResponseCreate(reason: "typed")
    }

    func interruptForBargeIn() {
        let hadOutputAudio = outputAudioActive
        let hadResponse = responseInProgress
        let hadTurn = currentTurnID != nil
        guard hadOutputAudio || hadResponse || hadTurn else { return }

        dbg("ChatRealtime", "barge_in_interrupt", fields: [
            "had_audio": hadOutputAudio,
            "had_response": hadResponse,
            "had_turn": hadTurn,
        ])

        sendEvent(["type": "response.cancel"])
        sendEvent(["type": "output_audio_buffer.clear"])
        outputAudioActive = false
        responseInProgress = false
        assistantTextGateOpen = false
        assistantTextBuffer = ""
        pendingAssistantText = ""
        pendingResponseCreateReason = nil
        seenTextDeltaThisResponse = false
        seenAudioDeltaThisResponse = false
        clearServerBargeInConfirmation()

        if hadOutputAudio {
            emit(eventType: "assistant_audio.end", payload: [:], role: "assistant")
        }
        if let turn = currentTurnID {
            emit(eventType: "turn.cancelled", payload: ["cancel_turn_id": .string(turn)], role: "system")
            currentTurnID = nil
        }
        emit(eventType: "state.change", payload: ["from": .string("speaking"), "to": .string("listening"), "reason": .string("barge_in")], role: "system")
    }

    func confirmToolCall(confirmationID: UUID, decision: String, editedText: String?) {
        guard let pending = pendingConfirmations[confirmationID.uuidString] else { return }
        dbg("ChatRealtime", "confirm_tool", fields: ["decision": decision, "tool": pending.toolName])
        if decision == "accept" {
            Task { await completeConfirmedTool(pending, editedText: editedText) }
        } else {
            sendToolOutput(
                callId: pending.callId,
                output: "{\"error\":\"User declined\"}"
            )
            requestResponseCreate(reason: "tool_rejected")
        }
        pendingConfirmations.removeValue(forKey: confirmationID.uuidString)
    }

    private func startTurnIfNeeded(inputMode: String = "voice") {
        if currentTurnID == nil {
            currentTurnID = UUID().uuidString
            turnSeq = 0
            emit(eventType: "turn.start", payload: ["input_mode": .string(inputMode)], role: "system")
            dbg("ChatRealtime", "turn_start", fields: ["mode": inputMode, "turn": currentTurnID ?? "-"])
        }
    }

    private func emit(eventType: String, payload: [String: JSONValue], role: String?) {
        seq += 1
        turnSeq += 1
        let env = StreamEventEnvelope.make(
            eventType: eventType,
            sessionID: sessionID,
            seq: seq,
            turnSeq: turnSeq,
            turnID: currentTurnID,
            messageID: nil,
            role: role,
            payload: payload
        )
        onEvent?(env)
    }

    private func ensurePermissions() async throws {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .undetermined {
            try await withCheckedThrowingContinuation { cont in
                session.requestRecordPermission { granted in
                    if granted {
                        cont.resume()
                    } else {
                        cont.resume(throwing: NSError(domain: "ChatRealtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]))
                    }
                }
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [
            .defaultToSpeaker,
            .allowBluetooth,
        ])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fetchConfig(userId: String) async throws -> ChatAgentConfig {
        var comps = URLComponents(url: HushhAPI.base.appendingPathComponent("/chat/agent/config"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "user_id", value: userId)]
        guard let url = comps?.url else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            dbg("ChatRealtime", "config_fetch_fail", fields: ["status": (resp as? HTTPURLResponse)?.statusCode ?? -1])
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ChatAgentConfigResponse.self, from: data)
        guard let cfg = decoded.data else {
            throw URLError(.cannotParseResponse)
        }
        let td = cfg.realtime?.turn_detection
        dbg("ChatRealtime", "config_fetch_ok", fields: [
            "status": http.statusCode,
            "has_turn_detection": td != nil,
        ])
        return cfg
    }

    private func fetchToken() async throws -> String {
        var req = URLRequest(url: HushhAPI.base.appendingPathComponent("/chat/agent/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": "gpt-4o-realtime-preview"]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            dbg("ChatRealtime", "token_fetch_fail", fields: ["status": (resp as? HTTPURLResponse)?.statusCode ?? -1])
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(ChatAgentTokenResponse.self, from: data)
        guard let secret = decoded.data?.client_secret else {
            throw URLError(.cannotParseResponse)
        }
        dbg("ChatRealtime", "token_fetch_ok", fields: ["status": http.statusCode])
        return secret
    }

    private func connectWebRTC(clientSecret: String) async throws {
        factory = LKRTCPeerConnectionFactory()
        let rtcConfig = LKRTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peer = factory?.peerConnection(with: rtcConfig, constraints: constraints, delegate: self) else {
            throw NSError(domain: "WebRTC", code: 10, userInfo: [NSLocalizedDescriptionKey: "PeerConnection failed"])
        }
        self.peer = peer
        dbg("ChatRealtime", "webrtc_peer_created")

        let audioSource = factory!.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory!.audioTrack(with: audioSource, trackId: "audio0")
        track.isEnabled = !isMuted && !useLocalSTTOnly
        localAudioTrack = track
        _ = peer.add(track, streamIds: ["stream0"])
        dbg("ChatRealtime", "webrtc_audio_track", fields: ["enabled": !isMuted])

        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = peer.dataChannel(forLabel: "oai-events", configuration: dcConfig) else {
            throw NSError(domain: "WebRTC", code: 11, userInfo: [NSLocalizedDescriptionKey: "DataChannel failed"])
        }
        dataChannel = dc
        dc.delegate = self
        dbg("ChatRealtime", "webrtc_data_channel")

        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LKRTCSessionDescription, Error>) in
            peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let err { cont.resume(throwing: err); return }
                guard let sdp else {
                    cont.resume(throwing: NSError(domain: "WebRTC", code: 12, userInfo: [NSLocalizedDescriptionKey: "Offer SDP nil"]))
                    return
                }
                cont.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { err in
                if let err { cont.resume(throwing: err); return }
                cont.resume()
            }
        }

        let answerSdp = try await postSDPToOpenAI(clientSecret: clientSecret, offerSdp: offer.sdp)
        let answer = LKRTCSessionDescription(type: .answer, sdp: answerSdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(answer) { err in
                if let err { cont.resume(throwing: err); return }
                cont.resume()
            }
        }
    }

    private func postSDPToOpenAI(clientSecret: String, offerSdp: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/realtime/calls") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        req.httpBody = offerSdp.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Bad response"
            throw NSError(domain: "OpenAIRealtime", code: (resp as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func sendEvent(_ obj: [String: Any]) {
        guard let dataChannel else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        dataChannel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
        debugLog("sent \(obj["type"] ?? "event")")
    }

    private func sendSessionUpdate(caller: String) {
        guard let cfg = config else { return }
        if sessionUpdateSent {
            dbg("ChatRealtime", "session_update_skipped", fields: ["caller": caller])
            return
        }
        var session: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": cfg.instructions,
            "tools": cfg.tools.map { decodeAnyDict($0) },
            "tool_choice": "auto",
        ]
        if !useLocalSTTOnly {
            if let turn = cfg.realtime?.turn_detection {
                var rawTurn = decodeAnyDict(turn)
                // Production hardening: ensure server-side VAD is always used for WebRTC realtime.
                // If backend sends an unsupported/incorrect type, input speech events + transcription may never arrive.
                rawTurn["type"] = "server_vad"
                // Sane defaults if backend omitted them.
                if rawTurn["threshold"] == nil { rawTurn["threshold"] = 0.6 }
                if rawTurn["silence_duration_ms"] == nil { rawTurn["silence_duration_ms"] = 900 }
                if rawTurn["prefix_padding_ms"] == nil { rawTurn["prefix_padding_ms"] = 300 }
                // IMPORTANT: gate assistant replies until we accept a valid user turn + transcription.
                // We'll send `response.create` ourselves once transcription final arrives.
                rawTurn["create_response"] = false
                let sanitizedTurn = sanitizeTurnDetection(rawTurn)
                session["turn_detection"] = sanitizedTurn
                if let rawThreshold = normalizeNumber(rawTurn["threshold"] ?? 0) {
                    let full = String(format: "%.17g", rawThreshold)
                    let decimals = decimalPlaces(full)
                    dbg("ChatRealtime", "threshold_raw", fields: [
                        "value": full,
                        "decimals": decimals,
                        "caller": caller,
                    ])
                }
                if let sanitizedThreshold = sanitizedTurn["threshold"] as? NSDecimalNumber {
                    let full = sanitizedThreshold.stringValue
                    let decimals = decimalPlaces(full)
                    dbg("ChatRealtime", "threshold_sanitized", fields: [
                        "value": full,
                        "decimals": decimals,
                        "caller": caller,
                    ])
                }
                serverVadEnabled = true
            } else {
                // Harden voice: if backend config omitted turn_detection, default to server VAD so
                // we still receive `input_audio_buffer.speech_started/stopped` and input transcription.
                session["turn_detection"] = [
                    "type": "server_vad",
                    "threshold": 0.6,
                    "silence_duration_ms": 900,
                    "prefix_padding_ms": 300,
                    "create_response": false,
                ]
                serverVadEnabled = true
                dbg("ChatRealtime", "turn_detection_defaulted", fields: ["caller": caller])
            }
        } else {
            serverVadEnabled = false
        }
        if !useLocalSTTOnly {
            // Match the known-good session.update used by `KaiVoiceViewModel` (same model + WebRTC stack).
            // This controls whether user input transcription events are emitted.
            session["input_audio_transcription"] = ["model": "gpt-4o-mini-transcribe"]
        }

        let sanitized = sanitizeJSONObject(session)
        sessionUpdateCount += 1
        lastSessionUpdateCaller = caller
        lastSessionUpdateStatus = "sent"
        let payloadLog = redactedJSONString(sanitized) ?? "<unserializable>"
        DispatchQueue.main.async {
            DebugLogger.shared.lastSessionUpdatePayload = payloadLog
        }
        dbg("ChatRealtime", "session_update_send", fields: [
            "count": sessionUpdateCount,
            "caller": caller,
        ])
        dbg("ChatRealtime", "session_update_payload", message: payloadLog)
        if sessionUpdateCount > 1 {
            dbg("ChatRealtime", "session_update_duplicate", fields: [
                "count": sessionUpdateCount,
                "caller": caller,
            ])
        }
        if let turn = sanitized["turn_detection"] {
            debugLog("session.update turn_detection=\(turn)")
        }
        dbg("ChatRealtime", "session_update_cfg", fields: [
            "caller": caller,
            "server_vad": serverVadEnabled,
            "has_input_transcription": sanitized["input_audio_transcription"] != nil,
        ])
        sendEvent(["type": "session.update", "session": sanitized])
        sessionUpdateSent = true
    }

    private func sendInputAudioBufferCommit(reason: String) {
        guard !useLocalSTTOnly else { return }
        guard dataChannel != nil else { return }
        // Never commit tiny buffers; OpenAI rejects them ("buffer too small").
        let duration = currentSpeechDuration()
        guard duration >= minValidSpeechDuration else {
            dbg("ChatRealtime", "input_commit_skipped_short", fields: [
                "reason": reason,
                "duration_ms": Int(duration * 1000),
            ])
            return
        }
        dbg("ChatRealtime", "input_commit_send", fields: [
            "reason": reason,
            "response_in_progress": responseInProgress,
            "output_audio_active": outputAudioActive,
        ])
        sendEvent(["type": "input_audio_buffer.commit"])
    }

    private func emitHintPleaseSpeakMore() {
        emit(
            eventType: "hint",
            payload: ["message": .string("Please speak a bit more before I respond.")],
            role: "system"
        )
        dbg("ChatRealtime", "short_speech_hint")
    }

    private func resetSpeechWindow() {
        userSpeechStartedAt = nil
        lastSpeechDuration = 0
        lastSpeechWasValid = false
    }

    private func currentSpeechDuration() -> TimeInterval {
        if let startedAt = userSpeechStartedAt {
            return Date().timeIntervalSince(startedAt)
        }
        return 0
    }

    private func sendResponseCreate(reason: String) {
        guard !responseInProgress else { return }
        let obj: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["audio", "text"],
            ],
        ]
        sendEvent(obj)
        responseInProgress = true
        debugLog("response.create \(reason)")
        dbg("ChatRealtime", "response_create", fields: ["reason": reason])
    }

    private func requestResponseCreate(reason: String) {
        if responseInProgress {
            pendingResponseCreateReason = reason
            dbg("ChatRealtime", "response_create_queued", fields: ["reason": reason])
            return
        }
        sendResponseCreate(reason: reason)
    }

    @discardableResult
    private func flushPendingResponseCreateIfNeeded() -> Bool {
        guard !responseInProgress, let reason = pendingResponseCreateReason else { return false }
        pendingResponseCreateReason = nil
        sendResponseCreate(reason: reason)
        return true
    }

    private func armServerBargeInConfirmation() {
        if awaitingServerBargeInConfirmation {
            return
        }
        awaitingServerBargeInConfirmation = true
        serverBargeInSpeechStartedAt = Date()
        serverBargeInTranscriptBuffer = ""
        userTranscriptBuffer = ""
        didFinalizeInput = false
        dbg("ChatRealtime", "barge_in_arm", fields: ["min_duration_s": serverBargeInMinSpeechDuration])
    }

    private func clearServerBargeInConfirmation() {
        awaitingServerBargeInConfirmation = false
        serverBargeInSpeechStartedAt = nil
        serverBargeInTranscriptBuffer = ""
    }

    @discardableResult
    private func maybeConfirmServerBargeIn(with transcriptDelta: String?) -> Bool {
        guard awaitingServerBargeInConfirmation else { return false }
        if let transcriptDelta, !transcriptDelta.isEmpty {
            let incoming = transcriptDelta.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incoming.isEmpty {
                if serverBargeInTranscriptBuffer.isEmpty {
                    serverBargeInTranscriptBuffer = incoming
                } else if incoming.lowercased().contains(serverBargeInTranscriptBuffer.lowercased()) {
                    serverBargeInTranscriptBuffer = incoming
                } else if !serverBargeInTranscriptBuffer.lowercased().contains(incoming.lowercased()) {
                    serverBargeInTranscriptBuffer += " " + incoming
                }
            }
        }
        guard let startedAt = serverBargeInSpeechStartedAt else {
            clearServerBargeInConfirmation()
            return false
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= serverBargeInMinSpeechDuration else {
            return false
        }

        let buffered = serverBargeInTranscriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableBargeInTranscript(buffered) else {
            dbg("ChatRealtime", "barge_in_waiting_for_content", fields: [
                "elapsed_ms": Int(elapsed * 1000),
                "chars": buffered.count,
            ])
            return false
        }
        clearServerBargeInConfirmation()
        interruptForBargeIn()
        startTurnIfNeeded(inputMode: "voice")
        didFinalizeInput = false
        if !buffered.isEmpty {
            userTranscriptBuffer = buffered
            emit(eventType: "input_transcript.delta", payload: ["text": .string(buffered)], role: "user")
            maybePrefetch(for: buffered)
        }
        dbg("ChatRealtime", "barge_in_confirmed", fields: ["elapsed_ms": Int(elapsed * 1000)])
        return true
    }

    private func isUsableBargeInTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= serverBargeInMinTranscriptChars else { return false }
        let alnumCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return alnumCount >= serverBargeInMinTranscriptChars
    }

    private func ensureVoiceTurnForInputIfNeeded(reason: String) {
        guard currentTurnID == nil else { return }
        startTurnIfNeeded(inputMode: "voice")
        didFinalizeInput = false
        emit(
            eventType: "state.change",
            payload: ["from": .string("idle"), "to": .string("listening"), "reason": .string(reason)],
            role: "system"
        )
    }

    private func handleIncomingEvent(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        let meta = eventMeta(obj: obj)
        dbg("ChatRealtime", "openai_event", fields: [
            "type": type,
            "response_id": meta.responseId ?? "-",
            "item_id": meta.itemId ?? "-",
            "call_id": meta.callId ?? "-",
        ])
        // High-signal instrumentation for missing user transcript pipeline.
        if type == "input_audio_buffer.speech_started"
            || type == "input_audio_buffer.speech_stopped"
            || type == "input_audio_buffer.committed"
            || type == "conversation.item.created"
            || type == "conversation.item.input_audio_transcription.delta"
            || type == "conversation.item.input_audio_transcription.completed"
            || type == "conversation.item.input_audio_transcription.failed"
            || type == "input_audio_transcript.delta"
            || type == "input_audio_transcript.done"
            || type == "input_audio_transcription.delta"
            || type == "input_audio_transcription.done"
            || type == "input_audio_transcription.completed"
            || type == "error"
        {
            dbg("ChatRealtime", "signal", fields: ["type": type])
        }
        if type == "session.created" || type == "session.updated" {
            lastSessionUpdateStatus = "ack"
            dbg("ChatRealtime", "session_update_ack", fields: ["type": type])
        }

        if type.contains("transcript") || type.contains("response") || type.contains("audio") {
            debugLog("recv \(type)")
        }

        if type == "error", let err = obj["error"] as? [String: Any] {
            let message = (err["message"] as? String) ?? "Realtime error"
            let code = (err["code"] as? String) ?? (err["type"] as? String) ?? "-"
            emit(eventType: "error", payload: ["message": .string(message)], role: "system")
            DispatchQueue.main.async {
                DebugLogger.shared.lastSessionUpdateError = message
            }
            lastSessionUpdateStatus = "error"
            dbg("ChatRealtime", "openai_error", message: message, fields: ["type": type, "code": code])
        }

        if type == "conversation.item.created" {
            if let item = obj["item"] as? [String: Any] {
                let role = (item["role"] as? String) ?? "-"
                let itemType = (item["type"] as? String) ?? "-"
                var contentTypes: [String] = []
                if let content = item["content"] as? [[String: Any]] {
                    contentTypes = content.compactMap { $0["type"] as? String }
                }
                dbg("ChatRealtime", "item_created", fields: [
                    "role": role,
                    "item_type": itemType,
                    "content_types": contentTypes.joined(separator: ","),
                ])
            }
        }

        if type == "response.created" {
            ensureTurnForResponse(reason: "response.created")
            responseInProgress = true
            assistantTextGateOpen = true
            lastResponseId = meta.responseId
            seenTextDeltaThisResponse = false
            seenAudioDeltaThisResponse = false
            emit(eventType: "state.change", payload: ["from": .string("listening"), "to": .string("thinking"), "reason": .string("response_created")], role: "system")
        }

        if type == "output_audio_buffer.started" || type == "response.audio.started" {
            ensureTurnForResponse(reason: "audio_started")
            outputAudioActive = true
            assistantTextGateOpen = true
            flushPendingAssistantText()
            emit(eventType: "assistant_audio.start", payload: [:], role: "assistant")
            emit(eventType: "state.change", payload: ["from": .string("thinking"), "to": .string("speaking"), "reason": .string("audio")], role: "system")
        }
        if type == "output_audio_buffer.stopped"
            || type == "output_audio_buffer.cleared"
            || type == "response.audio.done"
            || type == "response.audio.stopped" {
            if outputAudioActive {
                outputAudioActive = false
                assistantTextGateOpen = false
                emit(eventType: "assistant_audio.end", payload: [:], role: "assistant")
            }
        }

        if !useLocalSTTOnly {
            if type == "input_audio_buffer.speech_started" {
                if outputAudioActive || responseInProgress {
                    armServerBargeInConfirmation()
                    return
                }
                clearServerBargeInConfirmation()
                userSpeechStartedAt = Date()
                lastSpeechDuration = 0
                lastSpeechWasValid = false
                startTurnIfNeeded(inputMode: "voice")
                didFinalizeInput = false
                emit(eventType: "state.change", payload: ["from": .string("idle"), "to": .string("listening"), "reason": .string("speech_started")], role: "system")
                emit(eventType: "input_transcript.delta", payload: ["text": .string("")], role: "user")
            }

            if type == "input_audio_buffer.speech_stopped" {
                let duration = currentSpeechDuration()
                lastSpeechDuration = duration
                lastSpeechWasValid = duration >= minValidSpeechDuration
                dbg("ChatRealtime", "speech_window", fields: [
                    "duration_ms": Int(duration * 1000),
                    "valid": lastSpeechWasValid,
                ])

                // If the user spoke too briefly, do not commit, do not barge-in, and do not respond.
                if !lastSpeechWasValid, duration > 0 {
                    emitHintPleaseSpeakMore()
                    userTranscriptBuffer = ""
                    didFinalizeInput = true
                    endTurnIfNeeded()
                    resetSpeechWindow()
                    return
                }
            }

            if type == "input_audio_buffer.committed" {
                dbg("ChatRealtime", "input_commit_ack")
                // We intentionally do NOT start a response here.
                // We'll start only after we receive a final transcription for a valid speech window.
            }

            if let delta = extractUserTranscriptDelta(type: type, obj: obj) {
                if awaitingServerBargeInConfirmation {
                    _ = maybeConfirmServerBargeIn(with: delta)
                    return
                }
                ensureVoiceTurnForInputIfNeeded(reason: "transcript_delta")
                userTranscriptBuffer.append(delta)
                emit(eventType: "input_transcript.delta", payload: ["text": .string(userTranscriptBuffer)], role: "user")
                maybePrefetch(for: userTranscriptBuffer)
                dbg("ChatRealtime", "input_delta", fields: ["len": delta.count, "total": userTranscriptBuffer.count])
            }

            let finalFallback = awaitingServerBargeInConfirmation ? serverBargeInTranscriptBuffer : userTranscriptBuffer
            if let final = extractUserTranscriptFinal(type: type, obj: obj, fallback: finalFallback) {
                if awaitingServerBargeInConfirmation {
                    let confirmed = maybeConfirmServerBargeIn(with: final)
                    if !confirmed {
                        clearServerBargeInConfirmation()
                        dbg("ChatRealtime", "barge_in_disarmed", fields: ["reason": "final_before_min_duration"])
                        emitHintPleaseSpeakMore()
                        return
                    }
                }
                ensureVoiceTurnForInputIfNeeded(reason: "transcript_final")
                if !didFinalizeInput {
                    didFinalizeInput = true
                    let finalTranscript = final.trimmingCharacters(in: .whitespacesAndNewlines)
                    let transcript = finalTranscript.isEmpty
                        ? userTranscriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        : finalTranscript
                    userTranscriptBuffer = ""
                    if !transcript.isEmpty {
                        // Only accept transcription if the speech window is valid.
                        let duration = lastSpeechDuration > 0 ? lastSpeechDuration : currentSpeechDuration()
                        if duration < minValidSpeechDuration {
                            emitHintPleaseSpeakMore()
                            endTurnIfNeeded()
                            resetSpeechWindow()
                            return
                        }
                        debugLog("input final len=\(transcript.count)")
                        emit(eventType: "input_transcript.final", payload: ["text": .string(transcript)], role: "user")
                        emit(eventType: "state.change", payload: ["from": .string("listening"), "to": .string("thinking"), "reason": .string("final_transcript")], role: "system")
                        sendResponseCreate(reason: "voice_final")
                        dbg("ChatRealtime", "input_final", fields: ["len": transcript.count])
                        resetSpeechWindow()
                    }
                }
            }

            if type == "input_audio_buffer.speech_stopped", !didFinalizeInput {
                if awaitingServerBargeInConfirmation {
                    clearServerBargeInConfirmation()
                    dbg("ChatRealtime", "barge_in_disarmed", fields: ["reason": "speech_stopped_early"])
                    emitHintPleaseSpeakMore()
                    return
                }
                // Strict mode: do not respond without a final transcription.
                // If transcription never arrives, the UI will remain listening/thinking until timeout logic is added.
            }
        }

        if let delta = extractAssistantDelta(type: type, obj: obj) {
            let source = assistantDeltaSource(type: type, obj: obj)
            guard source != "unknown" else {
                dbg("ChatRealtime", "assistant_delta_skipped", fields: ["reason": "unknown_source", "type": type])
                return
            }
            if source == "audio_transcript",
               isAssistantAudioTranscriptDoneEvent(type),
               seenAudioDeltaThisResponse {
                dbg("ChatRealtime", "assistant_delta_skipped", fields: ["reason": "audio_done_duplicate"])
                return
            }
            if source == "audio_transcript" && seenTextDeltaThisResponse {
                dbg("ChatRealtime", "assistant_delta_skipped", fields: ["reason": "text_preferred"])
            } else {
                if source == "output_text" { seenTextDeltaThisResponse = true }
                if source == "audio_transcript" { seenAudioDeltaThisResponse = true }
                assistantTextBuffer.append(delta)
                if let lastDelta = lastAssistantDelta,
                   let lastAt = lastAssistantDeltaAt,
                   lastDelta == delta,
                   Date().timeIntervalSince(lastAt) < 0.5 {
                    dbg("ChatRealtime", "duplicate_append", fields: ["source": source])
                }
                lastAssistantDelta = delta
                lastAssistantDeltaAt = Date()
                emit(eventType: "assistant_text.delta", payload: ["text": .string(delta)], role: "assistant")
                dbg("ChatRealtime", "assistant_delta", fields: ["len": delta.count, "source": source])
            }
        }

        if type == "response.output_text.done" || type == "response.done" || type == "response.completed" {
            finalizeAssistantText()
            responseInProgress = false
            if !flushPendingResponseCreateIfNeeded() {
                endTurnIfNeeded()
            }
        }

        if type == "response.failed" || type == "response.canceled" || type == "response.stopped" {
            finalizeAssistantText()
            responseInProgress = false
            if !flushPendingResponseCreateIfNeeded() {
                endTurnIfNeeded()
            }
        }

        handleToolEvents(type: type, obj: obj)
    }

    private func finalizeAssistantText() {
        if !assistantTextBuffer.isEmpty {
            if !assistantTextGateOpen {
                flushPendingAssistantText()
            }
            emit(eventType: "assistant_text.final", payload: ["text": .string(assistantTextBuffer)], role: "assistant")
            assistantTextBuffer = ""
            dbg("ChatRealtime", "assistant_final")
        }
    }

    private func endTurnIfNeeded() {
        if currentTurnID != nil {
            emit(eventType: "turn.end", payload: ["outcome": .string("success"), "error_code": .null], role: "system")
            currentTurnID = nil
            dbg("ChatRealtime", "turn_end")
        }
    }

    private func assistantDeltaSource(type: String, obj: [String: Any]) -> String {
        if type == "response.output_text.delta" || type == "response.text.delta" {
            return "output_text"
        }
        if type == "response.content_part.added" || type == "response.content_part.delta" {
            return "output_text"
        }
        if isAssistantAudioTranscriptEvent(type) {
            return "audio_transcript"
        }
        return "unknown"
    }

    private func extractAssistantDelta(type: String, obj: [String: Any]) -> String? {
        if type == "response.output_text.delta" || type == "response.text.delta" {
            return obj["delta"] as? String
        }
        if type == "response.content_part.added" || type == "response.content_part.delta" {
            return extractContentPartText(obj)
        }
        if isAssistantAudioTranscriptEvent(type) {
            return extractTranscriptText(obj) ?? (obj["delta"] as? String) ?? (obj["transcript"] as? String)
        }
        return nil
    }

    private func isAssistantAudioTranscriptEvent(_ type: String) -> Bool {
        type == "response.output_audio_transcript.delta"
            || type == "response.output_audio_transcript.done"
            || type == "response.audio_transcript.delta"
            || type == "response.audio_transcript.done"
    }

    private func isAssistantAudioTranscriptDoneEvent(_ type: String) -> Bool {
        type == "response.output_audio_transcript.done"
            || type == "response.audio_transcript.done"
    }

    private func extractContentPartText(_ obj: [String: Any]) -> String? {
        if let part = obj["part"] as? [String: Any] {
            if let text = part["text"] as? String { return text }
            if let delta = part["delta"] as? String { return delta }
            if let content = part["content"] as? [[String: Any]] {
                for entry in content {
                    if let text = entry["text"] as? String { return text }
                    if let delta = entry["delta"] as? String { return delta }
                    if let transcript = entry["transcript"] as? String { return transcript }
                }
            }
        }
        if let content = obj["content"] as? [[String: Any]] {
            for entry in content {
                if let text = entry["text"] as? String { return text }
                if let delta = entry["delta"] as? String { return delta }
                if let transcript = entry["transcript"] as? String { return transcript }
            }
        }
        return nil
    }

    private func extractUserTranscriptDelta(type: String, obj: [String: Any]) -> String? {
        if type.contains("input_audio") && type.contains("transcription") && type.contains("delta") {
            return extractTranscriptText(obj) ?? (obj["delta"] as? String)
        }
        if type == "input_audio_transcript.delta"
            || type == "input_audio_transcription.delta"
            || type == "response.input_audio_transcription.delta"
            || type == "response.input_audio_transcript.delta" {
            return extractTranscriptText(obj) ?? (obj["delta"] as? String)
        }
        if type == "conversation.item.input_audio_transcription.delta" {
            return extractTranscriptText(obj) ?? (obj["delta"] as? String)
        }
        return nil
    }

    private func extractUserTranscriptFinal(type: String, obj: [String: Any], fallback: String) -> String? {
        if type.contains("input_audio") && type.contains("transcription") && (type.contains("done") || type.contains("completed")) {
            return extractTranscriptText(obj) ?? (obj["transcript"] as? String) ?? fallback
        }
        if type == "input_audio_transcript.done"
            || type == "input_audio_transcription.completed"
            || type == "input_audio_transcription.done"
            || type == "response.input_audio_transcription.completed"
            || type == "response.input_audio_transcript.done" {
            return extractTranscriptText(obj) ?? (obj["transcript"] as? String) ?? fallback
        }
        if type == "conversation.item.input_audio_transcription.completed" {
            return extractTranscriptText(obj) ?? (obj["transcript"] as? String) ?? fallback
        }
        return nil
    }

    private func extractTranscriptText(_ obj: [String: Any]) -> String? {
        if let text = obj["transcript"] as? String { return text }
        if let text = obj["delta"] as? String { return text }
        if let text = obj["text"] as? String { return text }
        if let item = obj["item"] as? [String: Any],
           let content = item["content"] as? [[String: Any]] {
            for part in content {
                if let text = part["text"] as? String { return text }
                if let text = part["transcript"] as? String { return text }
            }
        }
        if let response = obj["response"] as? [String: Any],
           let output = response["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = part["text"] as? String { return text }
                        if let text = part["transcript"] as? String { return text }
                    }
                }
            }
        }
        return nil
    }

    private func handleToolEvents(type: String, obj: [String: Any]) {
        if type == "response.output_item.added" || type == "response.output_item.done" {
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let callId = (item["call_id"] as? String) ?? (item["id"] as? String)
                let name = item["name"] as? String
                if let callId, let name {
                    pendingToolNames[callId] = name
                }
                if let callId, let args = item["arguments"] {
                    pendingToolArgs[callId] = (args as? String) ?? "\(args)"
                }
            }
        }

        if type.contains("function_call_arguments.done") || type.contains("tool_call_arguments.done") {
            let callId = (obj["call_id"] as? String)
                ?? (obj["item"] as? [String: Any])?["call_id"] as? String
            guard let callId else { return }
            let toolName = (obj["name"] as? String) ?? pendingToolNames[callId]
            guard let toolName else { return }
            let rawArgs = obj["arguments"]
                ?? (obj["item"] as? [String: Any])?["arguments"]
                ?? pendingToolArgs[callId]
            let args = parseArgumentsValue(rawArgs)
            pendingToolArgs.removeValue(forKey: callId)
            pendingToolNames.removeValue(forKey: callId)
            dbg("ChatRealtime", "tool_call", fields: ["tool": toolName, "call_id": callId])
            Task { await forwardToolCall(callId: callId, toolName: toolName, arguments: args) }
        }
    }

    private func parseArgumentsValue(_ raw: Any?) -> Any {
        guard let raw else { return [:] }
        if let dict = raw as? [String: Any] { return dict }
        if let arr = raw as? [Any] { return arr }
        if let str = raw as? String, let data = str.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        if let str = raw as? String { return ["raw": str] }
        return [:]
    }

    private func forwardToolCall(callId: String, toolName: String, arguments: Any) async {
        emit(eventType: "tool_call.progress", payload: ["message": .string("Running \(toolName)..."), "status": .string("running")], role: "assistant")
        if googleToken == nil, toolName.contains("gmail") || toolName.contains("calendar") {
            debugLog("tool \(toolName) missing google token")
        }
        let url = HushhAPI.base.appendingPathComponent("/chat/agent/tool")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "user_id": userId,
            "tool_name": toolName,
            "arguments": arguments,
            "call_id": callId,
        ]
        if let turn = currentTurnID {
            payload["turn_id"] = turn
        }
        if let googleToken {
            payload["google_access_token"] = googleToken
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Tool error"
                debugLog("tool \(toolName) http_error=\(msg)")
                sendToolOutput(callId: callId, output: "{\"error\":\"\(msg)\"}")
                requestResponseCreate(reason: "tool_http_error")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let confirmation = json?["confirmation_request_id"] as? String {
                let action = (json?["action_type"] as? String) ?? toolName
                let preview = json?["preview"]
                pendingConfirmations[confirmation] = PendingToolCall(
                    callId: callId,
                    toolName: toolName,
                    arguments: arguments,
                    confirmationID: confirmation,
                    turnID: currentTurnID
                )
                emit(eventType: "confirmation.request", payload: [
                    "confirmation_request_id": .string(confirmation),
                    "action_type": .string(action),
                    "preview": .string(stringifyPreview(preview)),
                ], role: "system")
                return
            }
            let output = json?["output"] ?? json
            debugLog("tool \(toolName) ok")
            sendToolOutput(callId: callId, output: stringifyOutput(output))
            requestResponseCreate(reason: "tool_output")
            emit(eventType: "tool_call.progress", payload: ["message": .string("\(toolName) complete"), "status": .string("done")], role: "assistant")
        } catch {
            debugLog("tool \(toolName) error=\(error.localizedDescription)")
            sendToolOutput(callId: callId, output: "{\"error\":\"\(error.localizedDescription)\"}")
            requestResponseCreate(reason: "tool_error")
        }
    }

    private func completeConfirmedTool(_ pending: PendingToolCall, editedText: String?) async {
        let url = HushhAPI.base.appendingPathComponent("/chat/agent/confirm")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = [
            "confirmation_request_id": pending.confirmationID ?? "",
            "user_id": userId,
            "tool_name": pending.toolName,
            "arguments": pending.arguments,
            "call_id": pending.callId,
        ]
        if let turn = pending.turnID {
            payload["turn_id"] = turn
        }
        if let editedText, !editedText.isEmpty {
            payload["edited_text"] = editedText
        }
        if let googleToken {
            payload["google_access_token"] = googleToken
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Tool confirm error"
                sendToolOutput(callId: pending.callId, output: "{\"error\":\"\(msg)\"}")
                requestResponseCreate(reason: "tool_confirm_http_error")
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let output = json?["output"] ?? json
            sendToolOutput(callId: pending.callId, output: stringifyOutput(output))
            requestResponseCreate(reason: "tool_confirmed")
        } catch {
            sendToolOutput(callId: pending.callId, output: "{\"error\":\"\(error.localizedDescription)\"}")
            requestResponseCreate(reason: "tool_confirm_error")
        }
    }

    private func sendToolOutput(callId: String, output: String) {
        sendEvent([
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output,
            ],
        ])
    }

    private func stringifyOutput(_ output: Any?) -> String {
        if let str = output as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: output ?? [:], options: []) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return "\(output ?? "")"
    }

    private func stringifyPreview(_ preview: Any?) -> String {
        if let str = preview as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: preview ?? [:], options: [.prettyPrinted]) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return "\(preview ?? "")"
    }

    private func debugLog(_ msg: String) {
        guard debugEnabled else { return }
        print("🛰️ [ChatRealtime] \(msg)")
    }

    private func maybePrefetch(for text: String) {
        let lower = text.lowercased()
        let wantsGmail = lower.contains("gmail") || lower.contains("email") || lower.contains("inbox")
        let wantsCalendar = lower.contains("calendar") || lower.contains("meeting") || lower.contains("schedule") || lower.contains("event")
        guard wantsGmail || wantsCalendar else { return }
        guard let googleToken else { return }

        let now = Date()
        if let last = lastPrefetchAt, now.timeIntervalSince(last) < 1.2 {
            return
        }
        if lower == lastPrefetchHint {
            return
        }

        lastPrefetchAt = now
        lastPrefetchHint = lower
        Task { await sendPrefetch(hint: lower, token: googleToken) }
    }

    private func sendPrefetch(hint: String, token: String) async {
        let url = HushhAPI.base.appendingPathComponent("/chat/agent/prefetch")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId,
            "hint": hint,
            "google_access_token": token,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                debugLog("prefetch failed status=\(http.statusCode)")
            }
        } catch {
            debugLog("prefetch error \(error.localizedDescription)")
        }
    }

    private func flushPendingAssistantText() {
        guard !pendingAssistantText.isEmpty else { return }
        emit(eventType: "assistant_text.delta", payload: ["text": .string(pendingAssistantText)], role: "assistant")
        pendingAssistantText = ""
    }

    private func decodeAny(_ value: AnyCodable) -> Any {
        if let dict = value.value as? [String: AnyCodable] {
            return decodeAnyDict(dict)
        }
        if let arr = value.value as? [AnyCodable] {
            return arr.map { decodeAny($0) }
        }
        return value.value
    }

    private func decodeAnyDict(_ dict: [String: AnyCodable]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            out[k] = decodeAny(v)
        }
        return out
    }

    private func sanitizeJSONObject(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in dict {
            out[key] = sanitizeJSONValue(value)
        }
        return out
    }

    private func sanitizeJSONValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return sanitizeJSONObject(dict)
        }
        if let arr = value as? [Any] {
            return arr.map { sanitizeJSONValue($0) }
        }
        if let decimal = value as? NSDecimalNumber {
            return decimal
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return roundDecimal(number.doubleValue, places: 6)
        }
        if let dbl = value as? Double {
            return roundDecimal(dbl, places: 6)
        }
        if let flt = value as? Float {
            return roundDecimal(Double(flt), places: 6)
        }
        return value
    }

    private func sanitizeTurnDetection(_ dict: [String: Any]) -> [String: Any] {
        var out = dict
        let numericKeys = ["threshold", "silence_duration_ms", "prefix_padding_ms"]
        for key in numericKeys {
            if let value = out[key], let normalized = normalizeNumber(value) {
                let rounded = roundDecimal(normalized, places: 4)
                out[key] = NSDecimalNumber(string: String(format: "%.4f", rounded))
            }
        }
        return out
    }

    private func normalizeNumber(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let dbl = value as? Double { return dbl }
        if let flt = value as? Float { return Double(flt) }
        if let str = value as? String { return Double(str) }
        return nil
    }

    private func roundDecimal(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    private func decimalPlaces(_ str: String) -> Int {
        guard let dot = str.firstIndex(of: ".") else { return 0 }
        let decimals = str[str.index(after: dot)...].trimmingCharacters(in: CharacterSet(charactersIn: "0"))
        return decimals.count
    }

    private func redactedJSONString(_ obj: Any) -> String? {
        let redacted = redactSensitive(obj)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func redactSensitive(_ obj: Any) -> Any {
        let sensitive = ["token", "secret", "key", "authorization", "cookie"]
        if let dict = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if sensitive.contains(where: { k.lowercased().contains($0) }) {
                    out[k] = "<redacted>"
                } else {
                    out[k] = redactSensitive(v)
                }
            }
            return out
        }
        if let arr = obj as? [Any] {
            return arr.map { redactSensitive($0) }
        }
        return obj
    }

    private func eventMeta(obj: [String: Any]) -> (responseId: String?, itemId: String?, callId: String?) {
        let responseId = obj["response_id"] as? String ?? (obj["response"] as? [String: Any])?["id"] as? String
        let itemId = obj["item_id"] as? String ?? (obj["item"] as? [String: Any])?["id"] as? String
        let callId = obj["call_id"] as? String ?? (obj["item"] as? [String: Any])?["call_id"] as? String
        return (responseId, itemId, callId)
    }

    private func dbg(_ component: String, _ event: String, message: String? = nil, fields: [String: Any] = [:]) {
        DebugLogger.shared.log(
            component: component,
            event: event,
            message: message,
            fields: fields,
            sessionId: sessionID,
            turnId: currentTurnID,
            messageId: nil
        )
    }

    private func ensureTurnForResponse(reason: String) {
        guard currentTurnID == nil else { return }
        startTurnIfNeeded(inputMode: "voice")
        emit(eventType: "state.change", payload: ["from": .string("idle"), "to": .string("thinking"), "reason": .string(reason)], role: "system")
    }
}

// MARK: - WebRTC delegates
extension ChatRealtimeSession: LKRTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {
        dbg("ChatRealtime", "webrtc_signaling", fields: ["state": stateChanged.rawValue])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        dbg("ChatRealtime", "webrtc_ice_connection", fields: ["state": newState.rawValue])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        dbg("ChatRealtime", "webrtc_ice_gathering", fields: ["state": newState.rawValue])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        dbg("ChatRealtime", "webrtc_connection", fields: ["state": newState.rawValue])
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        self.dataChannel = dataChannel
        dataChannel.delegate = self
        dbg("ChatRealtime", "webrtc_data_channel_open")
        sendSessionUpdate(caller: "dataChannel.open")
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {}
}

extension ChatRealtimeSession: LKRTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debugLog("dataChannel state=\(dataChannel.readyState.rawValue)")
        dbg("ChatRealtime", "data_channel_state", fields: ["state": dataChannel.readyState.rawValue])
        if dataChannel.readyState == .open {
            // IMPORTANT: We create the data channel locally, so `peerConnection(_:didOpen:)`
            // may never fire. Bootstrap session.update when the local channel becomes open.
            sendSessionUpdate(caller: "dataChannel.state.open")
            return
        }
        if dataChannel.readyState == .closed {
            DispatchQueue.main.async {
                self.lastError = "Realtime data channel closed"
                self.state = .error
            }
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {}

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary else { return }
        guard let text = String(data: buffer.data, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        handleIncomingEvent(obj)
    }
}

private struct PendingToolCall {
    let callId: String
    let toolName: String
    let arguments: Any
    var confirmationID: String?
    var turnID: String?
}

private struct ChatAgentConfigResponse: Codable {
    let ok: Bool
    let data: ChatAgentConfig?
}

private struct ChatAgentTokenResponse: Codable {
    let ok: Bool
    let data: ChatAgentToken?
}

private struct ChatAgentToken: Codable {
    let client_secret: String?
    let model: String?
}

private struct ChatAgentConfig: Codable {
    let instructions: String
    let tools: [[String: AnyCodable]]
    let realtime: ChatRealtimeConfig?
}

private struct ChatRealtimeConfig: Codable {
    let model: String?
    let turn_detection: [String: AnyCodable]?
}

private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let dbl = try? container.decode(Double.self) {
            value = dbl
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        case let arr as [AnyCodable]:
            try container.encode(arr)
        case let str as String:
            try container.encode(str)
        case let dbl as Double:
            try container.encode(dbl)
        case let bool as Bool:
            try container.encode(bool)
        default:
            try container.encodeNil()
        }
    }
}
