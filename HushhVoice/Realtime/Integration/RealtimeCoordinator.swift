import Foundation

@MainActor
final class RealtimeCoordinator: NSObject {
    private static var appHookCoordinator: RealtimeCoordinator?

    let store: RealtimeStore
    private let debugStore: RealtimeDebugStore?

    private let webRTCClient: WebRTCClient
    private let toolExecutor: ToolExecutor
    private var transportTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastClientSecret: String?
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private(set) var isRunning = false
    private var didBootstrapSession = false
    private var isDataChannelOpen = false
    private var isMicEnabled = false
    private var connectionGeneration: Int = 0
    private var pendingOutboundJSON: [[String: Any]] = []

    // Aggregated stream metrics (avoid per-delta spam).
    private var assistantDeltaCharsThisSecond: Int = 0
    private var assistantDeltaCountThisSecond: Int = 0
    private var metricsTask: Task<Void, Never>?

    // Barge-in hardening (server-VAD): require sustained speech + transcript content before cancelling.
    private var awaitingBargeInConfirmation = false
    private var bargeInSpeechStartedAt: Date?
    private var bargeInTranscriptBuffer: String = ""
    private var bargeInTask: Task<Void, Never>?
    private var lastBargeInCancelledResponseId: String?

    private let bargeInMinSpeechDuration: TimeInterval = 1.5
    private let bargeInMinTranscriptChars: Int = 6

    private var speechLogsEnabled: Bool {
        if ProcessInfo.processInfo.environment["HV_REALTIME_DEBUG"] == "1" { return true }
        return debugStore?.snapshotValue().verbosity == .verbose
    }

    init(
        store: RealtimeStore,
        webRTCClient: WebRTCClient = WebRTCClient(),
        toolExecutor: ToolExecutor = StubToolExecutor(),
        debugStore: RealtimeDebugStore? = nil
    ) {
        self.store = store
        self.webRTCClient = webRTCClient
        self.toolExecutor = toolExecutor
        self.debugStore = debugStore
        super.init()

        // Emit aggregated metrics once/sec when debug UI is enabled (BASIC/VERBOSE).
        metricsTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    guard let dbg = self.debugStore else { return }
                    guard dbg.snapshotValue().verbosity != .off else {
                        self.assistantDeltaCharsThisSecond = 0
                        self.assistantDeltaCountThisSecond = 0
                        return
                    }
                    guard self.assistantDeltaCharsThisSecond > 0 || self.assistantDeltaCountThisSecond > 0 else { return }
                    dbg.log(
                        level: .info,
                        category: "stream",
                        message: "assistant deltas=\(self.assistantDeltaCountThisSecond) chars=\(self.assistantDeltaCharsThisSecond)/s"
                    )
                    self.assistantDeltaCharsThisSecond = 0
                    self.assistantDeltaCountThisSecond = 0
                }
            }
        }
    }

    convenience override init() {
        self.init(store: RealtimeStore(), webRTCClient: WebRTCClient(), toolExecutor: StubToolExecutor())
    }

    deinit {
        transportTask?.cancel()
        reconnectTask?.cancel()
        metricsTask?.cancel()
        for task in toolTasks.values {
            task.cancel()
        }
        Task { [webRTCClient] in
            await webRTCClient.close()
        }
    }

    func start(clientSecret: String) {
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            store.send(.transport(.error("Realtime client secret is empty")))
            debugStore?.log(level: .error, category: "config", message: "client secret is empty")
            return
        }

        lastClientSecret = trimmedSecret
        reconnectTask?.cancel()
        reconnectTask = nil
        stopTransport()
        isRunning = true
        didBootstrapSession = false
        isDataChannelOpen = false
        isMicEnabled = false
        pendingOutboundJSON.removeAll()
        clearBargeInConfirmation()

        debugStore?.log(level: .info, category: "transport", message: "start()")
        startTransport(clientSecret: trimmedSecret)
    }

    func stop() {
        isRunning = false
        transportTask?.cancel()
        transportTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        for task in toolTasks.values {
            task.cancel()
        }
        toolTasks.removeAll()
        isRunning = false
        didBootstrapSession = false
        isDataChannelOpen = false
        isMicEnabled = false
        pendingOutboundJSON.removeAll()
        clearBargeInConfirmation()
        connectionGeneration &+= 1

        debugStore?.log(level: .info, category: "transport", message: "stop()")
        Task { [webRTCClient] in
            await webRTCClient.close()
        }
    }

    @objc
    class func sharedForAppHook() -> RealtimeCoordinator {
        if let existing = appHookCoordinator {
            return existing
        }
        let created = RealtimeCoordinator()
        appHookCoordinator = created
        return created
    }

    @objc
    func startFromAppEnvironment() {
        if store.onStateChange == nil {
            store.onStateChange = { state in
                let activeResponseId = state.activeTurnId
                    .flatMap { state.turns[$0]?.activeResponseId }
                    ?? state.streaming.activeResponseId
                let activeStatus = activeResponseId
                    .flatMap { state.responses[$0]?.status.rawValue }
                    ?? "none"
                let assistantLength = activeResponseId
                    .flatMap { state.responses[$0]?.textBuffer.count }
                    ?? state.streaming.activeAssistantText.count
                self.debugStore?.log(
                    level: .debug,
                    category: "shim",
                    message: "response=\(activeResponseId ?? "nil") status=\(activeStatus) assistantChars=\(assistantLength)"
                )
            }
        }

        let clientSecret = ProcessInfo.processInfo.environment["OPENAI_REALTIME_CLIENT_SECRET"] ?? ""
        if clientSecret.isEmpty {
            debugStore?.log(level: .error, category: "config", message: "OPENAI_REALTIME_CLIENT_SECRET missing; not started")
            return
        }

        start(clientSecret: clientSecret)
    }

    func sendSessionUpdate(_ session: [String: Any]) async {
        var payload: [String: Any] = ["type": "session.update"]
        payload["session"] = session
        await sendJSON(payload)
    }

    func sendResponseCreate(_ response: [String: Any] = [:]) async {
        var payload: [String: Any] = ["type": "response.create"]
        if !response.isEmpty {
            payload["response"] = response
        }
        await sendJSON(payload)
    }

    func sendUserText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        debugStore?.log(
            level: .info,
            category: "outbound",
            message: "sendUserText chars=\(trimmed.count) dataChannelOpen=\(isDataChannelOpen)"
        )

        let payload: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": trimmed
                    ]
                ]
            ]
        ]

        await sendJSON(payload)
        await sendResponseCreate()
    }

    func sendToolOutput(callId: String, output: String) async {
        let payload: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ]

        await sendJSON(payload)
        await sendResponseCreate()
    }

    func cancelActiveResponse() async {
        if let activeResponseId = activeResponseId() {
            store.send(.internal(.markResponseCancelled(responseId: activeResponseId)))
        }

        debugStore?.log(
            level: .warn,
            category: "cancel",
            message: "response.cancel response=\(activeResponseId() ?? "nil")"
        )

        await sendJSON(["type": "response.cancel"])
        await sendJSON(["type": "output_audio_buffer.clear"])
    }

    func setMicEnabled(_ enabled: Bool) {
        isMicEnabled = enabled
        debugStore?.setMicEnabled(enabled)
        Task { [webRTCClient] in
            await webRTCClient.setMicEnabled(enabled)
        }
    }

    private func consumeTransportEvent(_ event: TransportEvent) {
        switch event {
        case .stateChanged(let state):
            store.send(.transport(.stateChanged(state)))
            switch state {
            case .connected:
                debugStore?.log(level: .info, category: "transport", message: "connected")
                if reconnectTask != nil {
                    store.send(.internal(.reconnectSucceeded))
                    reconnectTask?.cancel()
                    reconnectTask = nil
                }
            case .disconnected:
                debugStore?.log(level: .warn, category: "transport", message: "disconnected")
                didBootstrapSession = false
                isDataChannelOpen = false
                handleDisconnect(reason: "transport_disconnected")
            case .reconnecting:
                debugStore?.log(level: .warn, category: "transport", message: "reconnecting")
                didBootstrapSession = false
                isDataChannelOpen = false
                handleDisconnect(reason: "transport_reconnecting")
            }

        case .dataChannel(let state):
            store.send(.transport(.dataChannel(state)))
            switch state {
            case .open:
                isDataChannelOpen = true
                debugStore?.setDataChannel("open")
                debugStore?.log(level: .info, category: "dataChannel", message: "open")
                if !didBootstrapSession {
                    didBootstrapSession = true
                    Task { [weak self] in
                        guard let self else { return }
                        await self.sendSessionUpdate(self.defaultSessionConfiguration())
                        await self.flushPendingOutboundIfPossible()
                    }
                } else {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.flushPendingOutboundIfPossible()
                    }
                }
                if reconnectTask != nil {
                    store.send(.internal(.reconnectSucceeded))
                    reconnectTask?.cancel()
                    reconnectTask = nil
                }
            case .closed:
                debugStore?.setDataChannel("closed")
                debugStore?.log(level: .warn, category: "dataChannel", message: "closed")
                didBootstrapSession = false
                isDataChannelOpen = false
                clearBargeInConfirmation()
                handleDisconnect(reason: "data_channel_closed")
            }

        case .message(let rawJSON):
            store.send(.transport(.message(rawJSON)))
            do {
                let event = try RealtimeEventParser.parse(rawJSON: rawJSON)
                store.send(.openAIEvent(event))
                maybeStartToolExecution(from: event)
                handleBargeInSignals(event)

                if let delta = event.assistantTextDelta, !delta.isEmpty {
                    assistantDeltaCountThisSecond += 1
                    assistantDeltaCharsThisSecond += delta.count
                }

                if let message = event.errorMessage, !message.isEmpty {
                    debugStore?.log(level: .error, category: "realtime", message: message, responseId: event.responseId, turnId: nil)
                    let lower = message.lowercased()
                    if lower.contains("session") || lower.contains("update") || lower.contains("auth") || lower.contains("unauthorized") {
                        store.send(.transport(.error(message)))
                    }
                }
            } catch {
                store.send(.transport(.error("Realtime parser error: \(error.localizedDescription)")))
                debugStore?.log(level: .error, category: "parser", message: error.localizedDescription)
            }

        case .error(let error):
            store.send(.transport(.error(error.localizedDescription)))
            debugStore?.log(level: .error, category: "transport", message: error.localizedDescription)
            isDataChannelOpen = false
            handleDisconnect(reason: "transport_error")
        }
    }

    private func sendJSON(_ json: [String: Any]) async {
        do {
            try await webRTCClient.send(json: json)
        } catch {
            // Common at startup: user sends before data channel opens. Queue and flush on open.
            if let transportError = error as? TransportError,
               transportError == .dataChannelNotOpen || transportError == .dataChannelUnavailable {
                if pendingOutboundJSON.count < 50 {
                    pendingOutboundJSON.append(json)
                    debugStore?.log(
                        level: .debug,
                        category: "outbound",
                        message: "queued type=\(json[\"type\"] ?? \"?\") pending=\(pendingOutboundJSON.count)"
                    )
                    return
                }
            }
            store.send(.transport(.error(error.localizedDescription)))
            debugStore?.log(level: .error, category: "outbound", message: error.localizedDescription)
        }
    }

    private func flushPendingOutboundIfPossible() async {
        guard isDataChannelOpen else { return }
        guard !pendingOutboundJSON.isEmpty else { return }

        // Send in-order. If the channel closes mid-flush, remaining items will stay queued.
        let toSend = pendingOutboundJSON
        pendingOutboundJSON.removeAll()
        for payload in toSend {
            await sendJSON(payload)
            if !isDataChannelOpen {
                // Re-queue anything not sent.
                pendingOutboundJSON.insert(payload, at: 0)
                break
            }
        }

        debugStore?.log(level: .info, category: "outbound", message: "flush done remaining=\(pendingOutboundJSON.count)")
    }

    // MARK: - Barge-In Hardening

    private func handleBargeInSignals(_ event: OpenAIEvent) {
        // Evidence log: correlate VAD with assistant audio state (only in VERBOSE or HV_REALTIME_DEBUG=1).
        if speechLogsEnabled,
           event.eventType == "input_audio_buffer.speech_started" || event.eventType == "input_audio_buffer.speech_stopped" {
            let active = activeResponseId()
            let audioActive = active.flatMap { store.state.responses[$0]?.audioActive } ?? false
            debugStore?.log(
                level: .debug,
                category: "speech",
                message: "\(event.eventType) mic=\(isMicEnabled) activeResponse=\(active ?? "nil") assistantAudioActive=\(audioActive)",
                responseId: active
            )
        }

        switch event.eventType {
        case "input_audio_buffer.speech_started":
            armBargeInConfirmationIfNeeded()
        case "input_audio_buffer.speech_stopped":
            clearBargeInConfirmation()
        default:
            break
        }

        if let delta = event.userTranscriptDelta, !delta.isEmpty {
            _ = maybeConfirmBargeIn(with: delta)
        }
        if let final = event.userTranscriptFinal, !final.isEmpty {
            _ = maybeConfirmBargeIn(with: final)
        }
    }

    private func armBargeInConfirmationIfNeeded() {
        guard isMicEnabled else { return }
        guard let active = activeResponseId() else { return }
        guard let response = store.state.responses[active], response.status == .streaming else { return }
        guard response.audioActive else {
            // Only arm barge-in while assistant is actually speaking; avoids random server-VAD during silence.
            return
        }
        guard !awaitingBargeInConfirmation else { return }

        awaitingBargeInConfirmation = true
        bargeInSpeechStartedAt = Date()
        bargeInTranscriptBuffer = ""
        lastBargeInCancelledResponseId = nil

        bargeInTask?.cancel()
        bargeInTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.bargeInMinSpeechDuration * 1_000_000_000))
            await MainActor.run {
                _ = self.maybeConfirmBargeIn(with: nil)
            }
        }

        debugStore?.log(level: .debug, category: "bargeIn", message: "armed minDuration=\(bargeInMinSpeechDuration)s", responseId: active)
    }

    private func clearBargeInConfirmation() {
        awaitingBargeInConfirmation = false
        bargeInSpeechStartedAt = nil
        bargeInTranscriptBuffer = ""
        bargeInTask?.cancel()
        bargeInTask = nil
    }

    @discardableResult
    private func maybeConfirmBargeIn(with transcriptDelta: String?) -> Bool {
        guard awaitingBargeInConfirmation else { return false }
        guard let startedAt = bargeInSpeechStartedAt else {
            clearBargeInConfirmation()
            return false
        }

        if let transcriptDelta, !transcriptDelta.isEmpty {
            let incoming = transcriptDelta.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incoming.isEmpty {
                if bargeInTranscriptBuffer.isEmpty {
                    bargeInTranscriptBuffer = incoming
                } else if incoming.lowercased().contains(bargeInTranscriptBuffer.lowercased()) {
                    bargeInTranscriptBuffer = incoming
                } else if !bargeInTranscriptBuffer.lowercased().contains(incoming.lowercased()) {
                    bargeInTranscriptBuffer += " " + incoming
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= bargeInMinSpeechDuration else { return false }

        let buffered = bargeInTranscriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableBargeInTranscript(buffered) else {
            debugStore?.log(
                level: .debug,
                category: "bargeIn",
                message: "waiting content elapsedMs=\(Int(elapsed*1000)) chars=\(buffered.count)"
            )
            return false
        }

        // Confirmed: cancel the active response, idempotently.
        guard isMicEnabled else {
            clearBargeInConfirmation()
            return false
        }
        guard let active = activeResponseId(),
              let response = store.state.responses[active],
              response.status == .streaming,
              response.audioActive else {
            clearBargeInConfirmation()
            return false
        }
        if lastBargeInCancelledResponseId == active {
            clearBargeInConfirmation()
            return true
        }

        lastBargeInCancelledResponseId = active
        clearBargeInConfirmation()

        debugStore?.log(
            level: .warn,
            category: "bargeIn",
            message: "confirmed elapsedMs=\(Int(elapsed*1000))",
            responseId: active
        )

        Task { [weak self] in
            guard let self else { return }
            await self.cancelActiveResponse()
        }
        return true
    }

    private func isUsableBargeInTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= bargeInMinTranscriptChars else { return false }
        let alnumCount = trimmed.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return alnumCount >= bargeInMinTranscriptChars
    }

    private func activeResponseId() -> String? {
        if let activeTurnId = store.state.activeTurnId,
           let responseId = store.state.turns[activeTurnId]?.activeResponseId {
            return responseId
        }
        return store.state.streaming.activeResponseId
    }

    private func startTransport(clientSecret: String) {
        connectionGeneration &+= 1
        let generation = connectionGeneration

        transportTask?.cancel()
        transportTask = nil
        didBootstrapSession = false
        isDataChannelOpen = false

        debugStore?.log(level: .info, category: "transport", message: "startTransport gen=\(generation)")
        transportTask = Task { [weak self] in
            guard let self else { return }
            await self.webRTCClient.close()
            let stream = await self.webRTCClient.connect(clientSecret: clientSecret)

            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    if generation != self.connectionGeneration { continue }
                    await MainActor.run {
                        if generation != self.connectionGeneration { return }
                        self.consumeTransportEvent(event)
                    }
                }
            } catch {
                await MainActor.run {
                    if generation != self.connectionGeneration { return }
                    self.store.send(.transport(.error(error.localizedDescription)))
                    self.debugStore?.log(level: .error, category: "transport", message: "connect failed: \(error.localizedDescription)")
                    self.handleDisconnect(reason: "connect_failed")
                }
            }
        }
    }

    private func stopTransport() {
        connectionGeneration &+= 1
        transportTask?.cancel()
        transportTask = nil
        didBootstrapSession = false
        isDataChannelOpen = false
        debugStore?.log(level: .info, category: "transport", message: "stopTransport gen=\(connectionGeneration)")
        Task { [webRTCClient] in
            await webRTCClient.close()
        }
    }

    private func handleDisconnect(reason: String) {
        guard isRunning else { return }
        guard reconnectTask == nil else { return }
        guard let secret = lastClientSecret, !secret.isEmpty else { return }

        store.send(.internal(.reconnectRequested))
        debugStore?.log(level: .warn, category: "reconnect", message: "requested reason=\(reason)")

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            let maxBackoff: Double = 10.0
            let connectTimeout: Double = 8.0
            let maxAttempts = 12

            for attempt in 1...maxAttempts {
                if Task.isCancelled { return }

                self.store.send(.internal(.reconnectAttempt(attempt)))
                await MainActor.run {
                    self.debugStore?.log(level: .info, category: "reconnect", message: "attempt=\(attempt)")
                }
                let delay = min(maxBackoff, 0.5 * pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }

                await MainActor.run {
                    self.startTransport(clientSecret: secret)
                }

                let deadline = Date().addingTimeInterval(connectTimeout)
                while Date() < deadline {
                    if Task.isCancelled { return }
                    if self.isDataChannelOpen {
                        await MainActor.run {
                            self.store.send(.internal(.reconnectSucceeded))
                            self.debugStore?.log(level: .info, category: "reconnect", message: "succeeded")
                        }
                        await MainActor.run {
                            self.reconnectTask?.cancel()
                            self.reconnectTask = nil
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            await MainActor.run {
                self.store.send(.internal(.reconnectFailed("Reconnect failed (\(reason))")))
                self.debugStore?.log(level: .error, category: "reconnect", message: "failed reason=\(reason)")
                self.reconnectTask = nil
            }
        }
    }

    private func maybeStartToolExecution(from event: OpenAIEvent) {
        guard event.isToolArgumentsDone else { return }
        guard let callId = event.callId else { return }
        guard toolTasks[callId] == nil else { return }

        debugStore?.log(level: .info, category: "tool", message: "start callId=\(callId) name=\(event.toolName ?? "unknown")", responseId: event.responseId)
        toolTasks[callId] = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Tool context can be created slightly after the args.done event is received (race with reducer/store).
            // Retry a few times to reliably pick up name/args.
            var toolSnapshot: ToolContext?
            for _ in 0..<10 {
                if Task.isCancelled { return }
                toolSnapshot = await MainActor.run { self.store.state.tools[callId] }
                if let toolSnapshot, !toolSnapshot.name.isEmpty, !toolSnapshot.argsJSON.isEmpty {
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            guard let tool = toolSnapshot, !tool.name.isEmpty, !tool.argsJSON.isEmpty else {
                await MainActor.run {
                    self.store.send(.internal(.toolResult(callId: callId, output: "Tool context missing name/args", success: false)))
                    self.toolTasks[callId] = nil
                    self.debugStore?.log(level: .error, category: "tool", message: "missing name/args callId=\(callId)")
                }
                return
            }

            // If bound response is already cancelled, ignore deterministically.
            let cancelledAtStart = await MainActor.run { () -> Bool in
                if let responseId = tool.boundResponseId {
                    return self.store.state.responses[responseId]?.status == .cancelled
                }
                return false
            }
            if cancelledAtStart {
                await MainActor.run {
                    self.store.send(.internal(.toolResult(callId: callId, output: "", success: false)))
                    self.toolTasks[callId] = nil
                    self.debugStore?.log(level: .warn, category: "tool", message: "ignored (response cancelled) callId=\(callId)")
                }
                return
            }

            do {
                let output = try await self.toolExecutor.execute(name: tool.name, argsJSON: tool.argsJSON)

                let shouldIgnore = await MainActor.run { () -> Bool in
                    if let responseId = tool.boundResponseId {
                        return self.store.state.responses[responseId]?.status == .cancelled
                    }
                    return false
                }

                if shouldIgnore {
                    await MainActor.run {
                        self.store.send(.internal(.toolResult(callId: callId, output: output, success: false)))
                        self.toolTasks[callId] = nil
                        self.debugStore?.log(level: .warn, category: "tool", message: "result ignored after cancel callId=\(callId)")
                    }
                    return
                }

                await self.sendToolOutput(callId: callId, output: output)

                await MainActor.run {
                    self.store.send(.internal(.toolResult(callId: callId, output: output, success: true)))
                    self.toolTasks[callId] = nil
                    self.debugStore?.log(level: .info, category: "tool", message: "result sent callId=\(callId)")
                }
            } catch {
                await MainActor.run {
                    self.store.send(.internal(.toolResult(callId: callId, output: error.localizedDescription, success: false)))
                    self.toolTasks[callId] = nil
                    self.debugStore?.log(level: .error, category: "tool", message: "failed callId=\(callId) err=\(error.localizedDescription)")
                }
            }
        }
    }

    private func defaultSessionConfiguration() -> [String: Any] {
        [
            "modalities": ["text", "audio"],
            "turn_detection": [
                "type": "server_vad"
            ],
            "input_audio_transcription": [
                "model": "gpt-4o-mini-transcribe"
            ],
            "tools": []
        ]
    }
}
