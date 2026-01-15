import Foundation
import SwiftUI
import AVFoundation
import LiveKitWebRTC
import Orb

// MARK: - ViewModel (Realtime WebRTC)
// ======================================================

final class KaiVoiceViewModel: NSObject, ObservableObject {

    @Published var state: OrbState = .connecting
    @Published var isMuted: Bool = true
    @Published var errorText: String? = nil
    @Published var notes: [KaiNoteEntry] = []
    @Published var completedQuestions: Int = 0
    @Published var totalQuestions: Int = 8
    @Published var isComplete: Bool = false
    @Published var missingKeys: [String] = []
    @Published var discovery: [String: String] = [:]
    @Published var nextQuestionId: String = ""
    @Published var nextQuestionText: String = ""
    @Published var isRunningSession: Bool = false
    @Published var toolStatusText: String = ""
    @Published var shouldExitOnboarding: Bool = false

    // Orb “mood” configuration
    @Published var orbConfiguration: OrbConfiguration = KaiVoiceViewModel.makeOrbConfig(state: .connecting, energy: 0.5)

    // Use your shared app base URL
    private let backendBase: URL = HushhAPI.base
    // If you want hardcoded:
    // private let backendBase: URL = URL(string: "https://YOUR_BACKEND")!
    private var userId: String = ""

    // WebRTC
    private var factory: LKRTCPeerConnectionFactory?
    private var peer: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var localAudioTrack: LKRTCAudioTrack?
    private var pendingToolCalls: [String: String] = [:]
    private var pendingToolArgs: [String: String] = [:]
    private var processedToolCallIds = Set<String>()
    private var introAutoMuteTask: Task<Void, Never>?
    private var introAutoMuted = false
    private var pendingExitConfirmation = false
    private var userTranscriptBuffer = ""
    private var lastUserUtterance = ""
    private var isOutputAudioActive = false
    private var pendingAudioWaitTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts: Int = 0
    private var allowReconnect = false
    private let backendTimeout: TimeInterval = 20
    private let backendRetryCount: Int = 2
    private let backendRetryDelay: TimeInterval = 0.4
    private let voiceId: String = "alloy"
    private var responseInProgress = false
    private var lastResponseHadSpeech = false
    private var lastUserTurnSignature = ""
    private var lastUserTurnAt: Date = .distantPast
    private var didMuteForOutput = false
    private var sessionReady = false
    private var pendingInitialResponse: [String: Any]?
    private var pendingInitialReason: String?
    private var pendingQueuedResponse: [String: Any]?
    private var pendingQueuedReason: String?
    private var lastTranscriptFailureAt: Date = .distantPast

    private let debugEnabled = true
    private let debugVerboseJSON = false
    private let debugEventWhitelist: Set<String> = [
        "session.created",
        "session.updated",
        "response.created",
        "response.started",
        "response.output_item.added",
        "response.done",
        "response.completed",
        "response.failed",
        "response.canceled",
        "response.stopped",
        "response.audio.started",
        "response.audio.done",
        "output_audio_buffer.started",
        "output_audio_buffer.stopped",
        "output_audio_buffer.cleared",
        "input_audio_buffer.speech_started",
        "input_audio_buffer.speech_stopped",
        "input_audio_buffer.committed",
        "input_audio_transcript.done",
        "conversation.item.input_audio_transcription.completed",
        "conversation.item.input_audio_transcription.failed",
        "error"
    ]
    private let debugOutgoingEventTypes: Set<String> = ["response.create", "conversation.item.create", "session.update"]

    // Config from backend
    private var instructions: String = ""
    private var tools: [[String: Any]] = []
    private var turnDetection: [String: Any] = [:]
    private var kickoffResponse: [String: Any] = [:]
    private var hasSentSessionUpdate = false
    private var lastSpokenPrompt: String = ""
    private var shouldRepeatOnConnect = false
    private let repeatPromptKey = "hushh_kai_last_prompt"
    private var lastRepeatPrompt: String = UserDefaults.standard.string(forKey: "hushh_kai_last_prompt") ?? ""
    private var responseWatchdogTask: Task<Void, Never>?
    private var lastResponseCreateAt: Date?
    private var lastResponseEventAt: Date?
    private var pendingNextQuestionCallId: String?
    private var pendingNextQuestionTask: Task<Void, Never>?
    private var responseRetryCount: Int = 0
    private var lastResponseInstructions: String?
    private var lastResponseWasAuto: Bool = false
    private var awaitingToolContinuation = false
    private var pendingNoteQuestionId: String?
    private var lastQuestionId: String?
    private var createdAt: Date = Date()

    private let localStatePrefix = "hushh_kai_onboarding_state_v1_"
    private let syncPendingPrefix = "hushh_kai_onboarding_sync_pending_"

    // Small speaking detection
    private var speakingHoldTask: Task<Void, Never>?
    private var speakingPulseToken = UUID()

    override init() {
        super.init()
    }

    var subtitle: String {
        switch state {
        case .connecting: return "Connecting…"
        case .listening: return isMuted ? "Muted" : "Listening"
        case .speaking: return "Kai is speaking"
        case .muted: return "Muted"
        case .error: return "Connection error"
        }
    }

    var footerText: String {
        switch state {
        case .connecting:
            return "Bringing Kai online…"
        case .error:
            return "Couldn’t connect. Try again."
        default:
            return isMuted ? "Mic muted." : "Kai is live. Speak anytime."
        }
    }

    var userIdValue: String { userId }

    func setUserId(_ id: String) {
        userId = id
        loadLocalState()
    }

    func start(userId: String, preserveState: Bool = false) {
        stop(keepReconnect: true)
        allowReconnect = true
        reconnectAttempts = 0
        self.userId = userId
        debugLog("start() userId=\(userId)")

        DispatchQueue.main.async {
            let shouldReset = !preserveState
            self.state = .connecting
            self.errorText = nil
            self.orbConfiguration = Self.makeOrbConfig(state: .connecting, energy: 0.5)
            if shouldReset {
                self.notes = []
                self.completedQuestions = 0
                self.totalQuestions = 8
                self.isComplete = false
                self.shouldExitOnboarding = false
                self.discovery = [:]
                self.missingKeys = []
                self.nextQuestionId = ""
                self.nextQuestionText = ""
                self.lastQuestionId = nil
            }
            self.isMuted = true
        }

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureRecordPermission()
                let configured = self.configureAudioSession()
                self.debugLog("audio session configured=\(configured)")

                try await self.fetchConfig()
                self.debugLog("config fetched: instructions_len=\(self.instructions.count) tools=\(self.tools.count)")
                let clientSecret = try await self.fetchClientSecret()
                self.debugLog("token fetched: \(clientSecret.prefix(8))...")

                try await self.connectWebRTC(clientSecret: clientSecret)
                self.debugLog("WebRTC connected")

                await MainActor.run {
                    self.isRunningSession = true
                    self.state = self.isMuted ? .muted : .listening
                    self.orbConfiguration = Self.makeOrbConfig(state: self.state, energy: 0.55)
                }
            } catch {
                await MainActor.run {
                    self.isRunningSession = false
                    self.state = .error
                    self.errorText = error.localizedDescription
                    self.orbConfiguration = Self.makeOrbConfig(state: .error, energy: 0.3)
                }
                self.debugLog("start() failed: \(error.localizedDescription)")
            }
        }
    }

    func stop(keepReconnect: Bool = false) {
        debugLog("stop()")
        allowReconnect = keepReconnect
        speakingHoldTask?.cancel()
        speakingHoldTask = nil
        introAutoMuteTask?.cancel()
        introAutoMuteTask = nil
        pendingAudioWaitTask?.cancel()
        pendingAudioWaitTask = nil
        pendingNextQuestionTask?.cancel()
        pendingNextQuestionTask = nil
        responseWatchdogTask?.cancel()
        responseWatchdogTask = nil
        if !allowReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        hasSentSessionUpdate = false
        isRunningSession = false
        pendingToolCalls.removeAll()
        pendingToolArgs.removeAll()
        processedToolCallIds.removeAll()
        introAutoMuted = false
        pendingNextQuestionCallId = nil
        lastResponseCreateAt = nil
        lastResponseEventAt = nil
        isOutputAudioActive = false
        userTranscriptBuffer = ""
        awaitingToolContinuation = false
        responseInProgress = false
        lastUserTurnSignature = ""
        lastUserTurnAt = .distantPast
        didMuteForOutput = false
        lastResponseHadSpeech = false
        sessionReady = false
        pendingInitialResponse = nil
        pendingInitialReason = nil
        pendingQueuedResponse = nil
        pendingQueuedReason = nil
        lastTranscriptFailureAt = .distantPast

        dataChannel?.close()
        dataChannel = nil

        peer?.close()
        peer = nil

        localAudioTrack = nil
        factory = nil
    }

    func setMuted(_ muted: Bool) {
        introAutoMuted = false
        if isMuted != muted { isMuted = muted }

        localAudioTrack?.isEnabled = !muted
        debugLog("mic setMuted=\(muted) localTrackEnabled=\(localAudioTrack?.isEnabled == true)")

        if state != .error && state != .connecting {
            state = muted ? .muted : .listening
            orbConfiguration = Self.makeOrbConfig(state: state, energy: muted ? 0.35 : 0.55)
        }
    }

    // ------------------------------------------------------
    // Backend: /onboarding/agent/config
    // ------------------------------------------------------

    private func dataWithRetry(_ req: URLRequest, attempts: Int, delay: TimeInterval) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for idx in 0..<max(1, attempts) {
            do {
                return try await URLSession.shared.data(for: req)
            } catch {
                lastError = error
                if idx < attempts - 1 {
                    let nanos = UInt64(delay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    func fetchConfig() async throws {
        var url = backendBase.appendingPathComponent("/onboarding/agent/config")
        if !userId.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
            if let updated = components.url { url = updated }
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = backendTimeout
        let (data, resp) = try await dataWithRetry(req, attempts: backendRetryCount, delay: backendRetryDelay)

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "KaiConfig", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Config error"
            ])
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any]
        else {
            throw NSError(domain: "KaiConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad config JSON"])
        }

        let newInstructions = (dataObj["instructions"] as? String) ?? ""

        let newTools: [[String: Any]]
        if let rawTools = dataObj["tools"] as? [[String: Any]] {
            newTools = rawTools
        } else if let rawAny = dataObj["tools"] as? [Any] {
            newTools = rawAny.compactMap { $0 as? [String: Any] }
        } else {
            newTools = []
        }

        let newTurnDetection: [String: Any]
        if let realtime = dataObj["realtime"] as? [String: Any],
           let td = realtime["turn_detection"] as? [String: Any] {
            newTurnDetection = td
        } else {
            newTurnDetection = [:]
        }

        let newKickoff: [String: Any]
        if let kickoff = dataObj["kickoff"] as? [String: Any],
           let respObj = kickoff["response"] as? [String: Any] {
            newKickoff = respObj
        } else {
            newKickoff = [:]
        }

        var newDiscovery: [String: String] = [:]
        var newIsComplete = (dataObj["is_complete"] as? Bool) ?? false
        var newCompletedQuestions = (dataObj["completed_questions"] as? Int) ?? completedQuestions
        var newTotalQuestions = (dataObj["total_questions"] as? Int) ?? totalQuestions
        var newMissingKeys = parseStringArray(dataObj["missing_keys"])
        var newLastQuestionId: String? = nil
        let newNextQuestionId = (dataObj["next_question"] as? String) ?? ""
        var didLoadNotes = false
        var newNotes: [KaiNoteEntry] = []
        if let compact = dataObj["state_compact"] as? [String: Any] {
            if let disc = compact["discovery"] as? [String: Any] {
                for (key, value) in disc {
                    if let str = value as? String, !str.isEmpty {
                        newDiscovery[key] = str
                    }
                }
            }
            if newMissingKeys.isEmpty {
                newMissingKeys = parseStringArray(compact["missing_keys"])
            }
            if let compactComplete = compact["is_complete"] as? Bool {
                newIsComplete = compactComplete
            }
            if let compactCompleted = compact["completed_questions"] as? Int {
                newCompletedQuestions = compactCompleted
            }
            if let compactTotal = compact["total_questions"] as? Int {
                newTotalQuestions = compactTotal
            }
            if let lastQ = compact["last_question_id"] as? String, !lastQ.isEmpty {
                newLastQuestionId = lastQ
            }
            if let notesTail = compact["notes_tail"] {
                didLoadNotes = true
                newNotes = parseNotesTail(notesTail)
            }
        }
        let newNextQuestionText = (dataObj["next_question_text"] as? String) ?? ""

        debugLog("config parsed tools=\(newTools.count) instructions_len=\(newInstructions.count)")
        await MainActor.run {
            self.instructions = newInstructions
            self.tools = newTools
            self.turnDetection = newTurnDetection
            self.kickoffResponse = newKickoff
            self.discovery = newDiscovery
            self.isComplete = newIsComplete
            self.completedQuestions = newCompletedQuestions
            self.totalQuestions = newTotalQuestions
            self.missingKeys = newMissingKeys
            if !newNextQuestionId.isEmpty {
                self.nextQuestionId = newNextQuestionId
            }
            self.nextQuestionText = newNextQuestionText
            if let newLastQuestionId {
                self.lastQuestionId = newLastQuestionId
            }
            if didLoadNotes {
                self.notes = newNotes
            }
            self.saveLocalState()
        }
    }

    // ------------------------------------------------------
    // Backend: /onboarding/agent/token
    // ------------------------------------------------------

    private func fetchClientSecret() async throws -> String {
        let url = backendBase.appendingPathComponent("/onboarding/agent/token")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = backendTimeout
        var body: [String: Any] = ["model": "gpt-4o-realtime-preview"]
        if !userId.isEmpty {
            body["user_id"] = userId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await dataWithRetry(req, attempts: backendRetryCount, delay: backendRetryDelay)

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "KaiToken", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Token error"
            ])
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any],
            let secret = dataObj["client_secret"] as? String,
            !secret.isEmpty
        else {
            throw NSError(domain: "KaiToken", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad token JSON"])
        }

        return secret
    }

    // ------------------------------------------------------
    // WebRTC: connect to OpenAI Realtime
    // ------------------------------------------------------

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

        // Local audio track
        let audioSource = factory!.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory!.audioTrack(with: audioSource, trackId: "audio0")
        self.localAudioTrack = audioTrack
        audioTrack.isEnabled = !isMuted
        debugLog("local audio track created enabled=\(audioTrack.isEnabled) muted=\(isMuted)")
        _ = peer.add(audioTrack, streamIds: ["stream0"])

        // Data channel
        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = peer.dataChannel(forLabel: "oai-events", configuration: dcConfig) else {
            throw NSError(domain: "WebRTC", code: 11, userInfo: [NSLocalizedDescriptionKey: "DataChannel failed"])
        }
        self.dataChannel = dc
        dc.delegate = self

        // Create offer
        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LKRTCSessionDescription, Error>) in
            peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let sdp = sdp else {
                    cont.resume(throwing: NSError(domain: "WebRTC", code: 12, userInfo: [NSLocalizedDescriptionKey: "Offer SDP nil"]))
                    return
                }
                cont.resume(returning: sdp)
            }
        }

        // Set local
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: ())
            }
        }

        // Exchange SDP with OpenAI
        let answerSdp = try await postOfferToOpenAI(clientSecret: clientSecret, offerSdp: offer.sdp)

        let answer = LKRTCSessionDescription(type: .answer, sdp: answerSdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(answer) { err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: ())
            }
        }
    }

    private func postOfferToOpenAI(clientSecret: String, offerSdp: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/realtime/calls") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        req.timeoutInterval = 30
        req.httpBody = offerSdp.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "OpenAIRealtime", code: 20, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "SDP exchange error"
            ])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    // ------------------------------------------------------
    // AEC: Audio session
    // ------------------------------------------------------

    private func configureAudioSession() -> Bool {
        return AudioSessionCoordinator.shared.configureIfNeeded()
    }

    private func ensureRecordPermission() async throws {
        let session = AVAudioSession.sharedInstance()
        debugLog("mic permission status=\(session.recordPermission.rawValue)")
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone access is denied"])
        case .undetermined:
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
            debugLog("mic permission prompt granted=\(granted)")
            if !granted {
                throw NSError(domain: "Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Microphone access is required"])
            }
        @unknown default:
            throw NSError(domain: "Audio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone permission unavailable"])
        }
    }

    // ------------------------------------------------------
    // DataChannel helpers
    // ------------------------------------------------------

    private func logOutgoingJSON(_ obj: [String: Any], label: String) {
        guard debugEnabled && debugVerboseJSON else { return }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("🟣 \(label):\n\(json)")
        }
    }

    private func sendEvent(_ obj: [String: Any]) {
        guard let dc = dataChannel else {
            debugLog("sendEvent dropped: dataChannel nil")
            return
        }
        if dc.readyState != .open {
            debugLog("sendEvent dropped: dataChannel state=\(dc.readyState.rawValue)")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        if let type = obj["type"] as? String {
            if debugVerboseJSON, debugOutgoingEventTypes.contains(type) {
                if type == "conversation.item.create",
                   let item = obj["item"] as? [String: Any],
                   (item["type"] as? String) == "function_call_output" {
                    logOutgoingJSON(obj, label: "outgoing conversation.item.create(function_call_output)")
                } else {
                    logOutgoingJSON(obj, label: "outgoing \(type)")
                }
            }
        }
        dc.sendData(LKRTCDataBuffer(data: data, isBinary: false))
        if let type = obj["type"] as? String {
            debugLog("sendEvent type=\(type)")
        }
    }

    private func appendNote(summary: String, questionId: String?) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let qid = (questionId?.isEmpty == false) ? questionId! : "Q?"
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                self.notes.append(KaiNoteEntry(questionId: qid, text: trimmed))
            }
            self.saveLocalState()
        }
    }

    @MainActor
    private func applyMemorySetPatchToLocalState(arguments: Any) {
        guard let dict = arguments as? [String: Any] else { return }
        guard let patch = dict["patch"] as? [String: Any] else { return }
        if let discoveryPatch = patch["discovery"] as? [String: Any], !discoveryPatch.isEmpty {
            var updated = discovery
            for (key, value) in discoveryPatch {
                if let str = stringValueForPatch(value) {
                    updated[key] = str
                }
            }
            discovery = updated
        }
        if let lastQ = patch["last_question_id"] as? String, !lastQ.isEmpty {
            lastQuestionId = lastQ
        }
        saveLocalState()
    }

    @MainActor
    private func appendLocalNoteFromMemorySet(arguments: Any) {
        guard let dict = arguments as? [String: Any] else { return }
        let patch = dict["patch"] as? [String: Any]
        let questionId = (patch?["last_question_id"] as? String) ?? lastQuestionId

        if let rawNote = dict["note"] as? String {
            let trimmed = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendNote(summary: trimmed, questionId: questionId)
                return
            }
        }

        guard let discoveryPatch = patch?["discovery"] as? [String: Any] else { return }
        let orderedKeys = noteKeyOrder()
        var statements: [String] = []
        for key in orderedKeys {
            guard let value = discoveryPatch[key],
                  let str = stringValueForPatch(value),
                  let statement = noteStatement(for: key, value: str)
            else { continue }
            statements.append(statement)
        }
        if statements.isEmpty {
            for (key, value) in discoveryPatch {
                guard !orderedKeys.contains(key),
                      let str = stringValueForPatch(value)
                else { continue }
                let keyLabel = key.replacingOccurrences(of: "_", with: " ")
                let fallback = "You shared \(keyLabel) as \(str)."
                statements.append(fallback)
            }
        }
        guard !statements.isEmpty else { return }
        let suffix = statements.count == 1 ? " That gives me a clearer picture." : ""
        appendNote(summary: statements.joined(separator: " ") + suffix, questionId: questionId)
    }

    private func noteKeyOrder() -> [String] {
        [
            "net_worth",
            "asset_breakdown",
            "investor_identity",
            "capital_intent",
            "allocation_comfort_12_24m",
            "experience_proud",
            "experience_regret",
            "fund_fit_alignment",
            "allocation_mechanics_depth",
            "contact_country"
        ]
    }

    private func noteStatement(for key: String, value: String) -> String? {
        switch key {
        case "net_worth":
            return "You mentioned your net worth is \(value)."
        case "asset_breakdown":
            return "You described the split as \(value)."
        case "investor_identity":
            return "You see yourself as \(value)."
        case "capital_intent":
            return "Your capital intent is \(value)."
        case "allocation_comfort_12_24m":
            return "You are comfortable allocating \(value) over the next 12-24 months."
        case "experience_proud":
            return "A decision you are proud of: \(value)."
        case "experience_regret":
            return "A decision you would revisit: \(value)."
        case "fund_fit_alignment":
            return "You are looking for a fund that aligns with \(value)."
        case "allocation_mechanics_depth":
            return "You prefer \(value) depth on allocation mechanics."
        case "contact_country":
            return "You are based in \(value)."
        default:
            return nil
        }
    }

    private func stringValueForPatch(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let num = value as? NSNumber {
            return num.stringValue
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let json = String(data: data, encoding: .utf8) {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let desc = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return desc.isEmpty ? nil : desc
    }


    private func sendSessionUpdatePayload() {
        var session: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": instructions,
            "tools": tools,
            "voice": voiceId,
            "input_audio_transcription": ["model": "gpt-4o-mini-transcribe"],
            "tool_choice": "auto"
        ]
        if let td = sanitizedTurnDetection() {
            session["turn_detection"] = td
        }

        let toolNames = tools.compactMap { $0["name"] as? String }
        debugLog("session.update tools=\(toolNames) instructions_len=\(instructions.count)")
        sendEvent([
            "event_id": "session_update_\(Int(Date().timeIntervalSince1970))",
            "type": "session.update",
            "session": session
        ])
        debugLog("session.update sent")
    }

    private func queueInitialResponse(_ response: [String: Any], reason: String) {
        pendingInitialResponse = response
        pendingInitialReason = reason
        if sessionReady {
            sendResponseCreateResponse(response, reason: reason)
            pendingInitialResponse = nil
            pendingInitialReason = nil
        } else {
            debugLog("initial response queued reason=\(reason)")
        }
    }

    private func sendKickoffIfNeeded() {
        let fallback = "Hi, I’m Kai. Let’s begin. Before we talk about investing, what does your net worth look like and how is it split across assets?"
        let kickoff = kickoffResponse.isEmpty
            ? [
                "modalities": ["audio", "text"],
                "instructions": fallback
              ]
            : kickoffResponse
        if let instructions = kickoff["instructions"] as? String {
            lastSpokenPrompt = instructions
            persistRepeatPrompt(instructions)
        }
        queueInitialResponse(kickoff, reason: "kickoff")
    }

    private func sendInitialSessionUpdate() {
        guard !hasSentSessionUpdate else { return }
        guard !instructions.isEmpty else { return }

        hasSentSessionUpdate = true

        sendSessionUpdatePayload()
        if shouldRepeatOnConnect, !lastSpokenPrompt.isEmpty {
            shouldRepeatOnConnect = false
            queueInitialResponse(
                ["modalities": ["audio", "text"], "instructions": "Repeat this exactly: \"\(lastSpokenPrompt)\""],
                reason: "repeat_on_connect"
            )
        } else {
            sendKickoffIfNeeded()
        }
        debugLog("initial session update complete")
    }

    private func refreshSessionUpdate() {
        guard !instructions.isEmpty else { return }
        sendSessionUpdatePayload()
    }

    private func applyIntroAutoMute(durationSeconds: Double = 4.5) {
        introAutoMuteTask?.cancel()
        introAutoMuted = true
        if !isMuted {
            localAudioTrack?.isEnabled = false
        }
        let nanos = UInt64(durationSeconds * 1_000_000_000)
        introAutoMuteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            if self.introAutoMuted && !self.isMuted {
                self.localAudioTrack?.isEnabled = true
            }
            self.introAutoMuted = false
        }
    }

    private func sendResponseCreate(instructions: String) {
        sendResponseCreatePayload(instructions: instructions, isRetry: false, reason: "manual")
    }

    private func nextQuestionInstruction() -> String {
        if isComplete {
            return """
            Briefly acknowledge the user and reflect a short insight. Then say you have everything you need and that a summary is ready to review. Keep it calm and concise.
            """
        }
        if !nextQuestionText.isEmpty {
            return """
            Acknowledge the last answer in one short line, then add a 1–2 sentence insight. After that, smoothly transition and ask the next question with the same intent as: "\(nextQuestionText)". Ask ONLY one question. Then wait. After the user answers, call memory_set.
            """
        }
        return """
        Acknowledge the last answer in one short line, then add a 1–2 sentence insight. Then ask ONLY the next missing question (Q#) as per pinned state. Ask one question. Then wait. After the user answers, call memory_set.
        """
    }

    private func sendNextQuestionIfAvailable() {
        if isOutputAudioActive {
            debugLog("next question delayed: output audio active")
            pendingAudioWaitTask?.cancel()
            pendingAudioWaitTask = Task { @MainActor in
                while self.isOutputAudioActive {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                self.sendNextQuestionIfAvailable()
            }
            return
        }
        if !nextQuestionText.isEmpty {
            persistRepeatPrompt(nextQuestionText)
            lastSpokenPrompt = nextQuestionText
        } else if isComplete {
            lastSpokenPrompt = "Thanks — I have everything I need. I’ll show you a concise summary now."
        }
        let instruction = nextQuestionInstruction()
        sendResponseCreate(instructions: instruction)
        debugLog("next question sent")
    }

    func markRepeatOnNextConnect() {
        shouldRepeatOnConnect = true
    }

    func repeatLastPromptIfNeeded() {
        guard isRunningSession else { return }
        let toRepeat = lastRepeatPrompt.isEmpty ? lastSpokenPrompt : lastRepeatPrompt
        guard !toRepeat.isEmpty else { return }
        sendResponseCreate(instructions: "Repeat this exactly: \"\(toRepeat)\"")
    }

    private func persistRepeatPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastRepeatPrompt = trimmed
        UserDefaults.standard.set(trimmed, forKey: repeatPromptKey)
    }

    private func sanitizedTurnDetection() -> [String: Any]? {
        guard !turnDetection.isEmpty else { return nil }
        var td = turnDetection

        if let raw = td["threshold"] {
            let decimalValue: Decimal?
            switch raw {
            case let num as NSNumber:
                decimalValue = Decimal(string: num.stringValue) ?? Decimal(num.doubleValue)
            case let str as String:
                decimalValue = Decimal(string: str)
            default:
                decimalValue = nil
            }

            if var value = decimalValue {
                var rounded = Decimal()
                NSDecimalRound(&rounded, &value, 6, .plain)
                td["threshold"] = NSDecimalNumber(decimal: rounded)
            } else {
                td.removeValue(forKey: "threshold")
            }
        }

        return td.isEmpty ? nil : td
    }

    @MainActor
    private func updateFromToolOutput(_ output: Any) {
        guard let dict = normalizedToolOutput(output) else { return }
        if let isComplete = dict["is_complete"] as? Bool {
            self.isComplete = isComplete
            if isComplete {
                self.shouldExitOnboarding = true
            }
        }
        if let completed = dict["completed_questions"] as? Int {
            self.completedQuestions = completed
        }
        if let total = dict["total_questions"] as? Int {
            self.totalQuestions = total
        }
        if let nextText = dict["next_question_text"] as? String {
            self.nextQuestionText = nextText
        }
        let missing = parseStringArray(dict["missing_keys"])
        if !missing.isEmpty {
            self.missingKeys = missing
        }
        if let nextId = dict["next_question"] as? String, !nextId.isEmpty {
            self.nextQuestionId = nextId
        }
        if let lastQ = dict["last_question_id"] as? String, !lastQ.isEmpty {
            pendingNoteQuestionId = lastQ
            lastQuestionId = lastQ
        }
        self.saveLocalState()
    }

    private func normalizedToolOutput(_ output: Any) -> [String: Any]? {
        guard let dict = output as? [String: Any] else { return nil }
        if let data = dict["data"] as? [String: Any],
           let inner = data["output"] as? [String: Any] {
            return inner
        }
        if let inner = dict["output"] as? [String: Any] {
            return inner
        }
        return dict
    }

    private func parseStringArray(_ value: Any?) -> [String] {
        if let items = value as? [String] {
            return items
        }
        if let items = value as? [Any] {
            return items.compactMap { $0 as? String }
        }
        return []
    }

    private func parseNotesTail(_ value: Any) -> [KaiNoteEntry] {
        let items: [[String: Any]]
        if let list = value as? [[String: Any]] {
            items = list
        } else if let list = value as? [Any] {
            items = list.compactMap { $0 as? [String: Any] }
        } else {
            return []
        }

        let formatter = ISO8601DateFormatter()
        var entries: [KaiNoteEntry] = []
        for item in items {
            guard let note = item["note"] as? String, !note.isEmpty else { continue }
            let tsString = item["ts"] as? String
            let parsedDate = tsString.flatMap { formatter.date(from: $0) } ?? Date()
            entries.append(KaiNoteEntry(ts: parsedDate, questionId: "Q?", text: note))
        }
        return entries
    }

    private func parseArgumentsValue(_ raw: Any?) -> Any {
        if let argsDict = raw as? [String: Any] {
            return argsDict
        } else if let argsArray = raw as? [Any] {
            return argsArray
        } else if let argsString = raw as? String,
                  let data = argsString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        } else if let argsString = raw as? String {
            return ["raw": argsString]
        } else {
            return [:]
        }
    }

    private func handleResponseDoneForTools(_ obj: [String: Any]) {
        guard let response = obj["response"] as? [String: Any] else { return }
        guard let output = response["output"] as? [[String: Any]] else { return }
        for item in output {
            guard (item["type"] as? String) == "function_call" else { continue }
            let callId = (item["call_id"] as? String) ?? (item["id"] as? String)
            let name = item["name"] as? String
            let args = item["arguments"]
            guard let callId, let name else { continue }
            guard shouldProcessToolCall(callId: callId, toolName: name) else { continue }
            let arguments = parseArgumentsValue(args)
            debugLog("tool call response.done name=\(name) id=\(callId)")
            DispatchQueue.main.async {
                self.toolStatusText = "Tool (done): \(name)"
            }
            handleToolCall(callId: callId, toolName: name, arguments: arguments)
        }
    }

    private func handleToolEvent(type: String, obj: [String: Any]) {
        if type == "response.done" {
            handleResponseDoneForTools(obj)
        }
        if type == "response.output_item.added" {
            if let item = obj["item"] as? [String: Any] {
                if (item["type"] as? String) == "function_call" {
                    let callId = (item["call_id"] as? String) ?? (item["id"] as? String)
                    let name = item["name"] as? String
                    if let callId, let name {
                        pendingToolCalls[callId] = name
                    }
                    if let callId, let args = item["arguments"] {
                        pendingToolArgs[callId] = (args as? String) ?? "\(args)"
                    }
                    debugLog("tool call queued name=\(name ?? "unknown") id=\(callId ?? "nil")")
                    DispatchQueue.main.async {
                        self.toolStatusText = "Tool queued: \(name ?? "unknown")"
                    }
                } else if let itemType = item["type"] as? String,
                          itemType == "message" || itemType == "output_text" || itemType == "text" {
                    lastResponseHadSpeech = true
                }
            }
        }

        if type == "response.output_item.done" {
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let callId = (item["call_id"] as? String) ?? (item["id"] as? String)
                let name = item["name"] as? String
                let args = item["arguments"]
                if let callId, let name {
                    guard shouldProcessToolCall(callId: callId, toolName: name) else { return }
                    let arguments = parseArgumentsValue(args ?? pendingToolArgs[callId])
                    pendingToolCalls.removeValue(forKey: callId)
                    pendingToolArgs.removeValue(forKey: callId)
                    debugLog("tool call done name=\(name) id=\(callId)")
                    DispatchQueue.main.async {
                        self.toolStatusText = "Tool done: \(name)"
                    }
                    handleToolCall(callId: callId, toolName: name, arguments: arguments)
                    return
                }
            }
        }

        if type.contains("function_call_arguments.delta") {
            if let callId = obj["call_id"] as? String,
               let delta = obj["delta"] as? String {
                pendingToolArgs[callId, default: ""].append(delta)
            }
        }

        if type.contains("function_call_arguments.done") || type.contains("tool_call_arguments.done") {
            let callId = (obj["call_id"] as? String)
                ?? (obj["id"] as? String)
                ?? (obj["call"] as? [String: Any])?["id"] as? String
                ?? (obj["item"] as? [String: Any])?["call_id"] as? String
            guard let callId else { return }

            let toolName = (obj["name"] as? String)
                ?? (obj["tool_name"] as? String)
                ?? (obj["item"] as? [String: Any])?["name"] as? String
                ?? pendingToolCalls[callId]

            guard let toolName else { return }
            guard shouldProcessToolCall(callId: callId, toolName: toolName) else { return }

            let rawArgs = obj["arguments"]
                ?? (obj["call"] as? [String: Any])?["arguments"]
                ?? (obj["item"] as? [String: Any])?["arguments"]
                ?? pendingToolArgs[callId]
            let arguments = parseArgumentsValue(rawArgs)

            pendingToolCalls.removeValue(forKey: callId)
            pendingToolArgs.removeValue(forKey: callId)
            debugLog("tool args done name=\(toolName) id=\(callId)")
            DispatchQueue.main.async {
                self.toolStatusText = "Tool args done: \(toolName)"
            }
            handleToolCall(callId: callId, toolName: toolName, arguments: arguments)
        }
    }


    func forceToolCallDebug() async {
        guard !userId.isEmpty else { return }
        let url = backendBase.appendingPathComponent("/onboarding/agent/tool")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId,
            "tool_name": "memory_set",
            "arguments": [
                "patch": [
                    "discovery": [
                        "net_worth": "debug",
                        "asset_breakdown": "debug"
                    ],
                    "last_question_id": "Q1",
                    "phase": "discovery"
                ],
                "note": "debug tool call"
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        await MainActor.run {
            self.toolStatusText = "Debug: forcing tool call"
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                await MainActor.run { self.toolStatusText = "Debug: no HTTP response" }
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run { self.toolStatusText = "Debug failed: HTTP \(http.statusCode) \(body)" }
                return
            }
            await MainActor.run { self.toolStatusText = "Debug tool call ok" }
            await refreshConfigOnly()
        } catch {
            await MainActor.run { self.toolStatusText = "Debug error: \(error.localizedDescription)" }
        }
    }

    private func extractUserText(from obj: [String: Any]) -> String? {
        guard let item = obj["item"] as? [String: Any] else { return nil }
        guard (item["role"] as? String) == "user" else { return nil }

        if let text = item["text"] as? String, !text.isEmpty {
            return text
        }

        if let content = item["content"] as? [[String: Any]] {
            for part in content {
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
                if let transcript = part["transcript"] as? String, !transcript.isEmpty {
                    return transcript
                }
            }
        }

        return nil
    }

    private func containsExitIntent(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = lower.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount <= 6 else { return false }
        let phrases = [
            "stop",
            "stop now",
            "stop please",
            "pause",
            "pause please",
            "continue later",
            "done",
            "i'm done",
            "im done",
            "quit",
            "exit",
            "end chat",
            "end the chat",
            "end this",
            "that's enough",
            "thats enough",
            "no more",
            "can we stop",
            "can we pause",
            "let's stop",
            "lets stop",
            "wrap up"
        ]
        return phrases.contains { lower == $0 }
    }

    private func isAffirmative(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = ["yes", "yeah", "yep", "sure", "ok", "okay", "please do", "let's go", "lets go"]
        return phrases.contains { lower.contains($0) }
    }

    private func isNegative(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = ["no", "nope", "not yet", "keep going", "continue", "carry on"]
        return phrases.contains { lower.contains($0) }
    }

    @discardableResult
    private func handleUserUtterance(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == lastUserUtterance { return false }
        lastUserUtterance = trimmed

        if pendingExitConfirmation {
            if isAffirmative(trimmed) {
                pendingExitConfirmation = false
                DispatchQueue.main.async {
                    self.toolStatusText = "Exit confirmed"
                    self.shouldExitOnboarding = true
                }
                return true
            }
            if isNegative(trimmed) {
                pendingExitConfirmation = false
                sendResponseCreate(instructions: "No problem. We can continue. Please answer the last question.")
                return true
            }
        }

        if containsExitIntent(trimmed) {
            pendingExitConfirmation = true
            sendResponseCreate(instructions: "Got it. Do you want to review your summary now?")
            return true
        }
        return false
    }

    func requestExitConfirmation(reason: String) {
        guard !pendingExitConfirmation else { return }
        pendingExitConfirmation = true
        let msg: String
        if reason == "complete" {
            msg = "I have everything I need. Do you want to review your summary now?"
        } else {
            msg = "Got it. Do you want to review your summary now?"
        }
        sendResponseCreate(instructions: msg)
    }

    private func shouldProcessUserTurn(transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let signature = trimmed.lowercased()
        let now = Date()
        if now.timeIntervalSince(lastUserTurnAt) < 1.2 {
            return false
        }
        if signature == lastUserTurnSignature, now.timeIntervalSince(lastUserTurnAt) < 1.6 {
            return false
        }
        lastUserTurnSignature = signature
        lastUserTurnAt = now
        return true
    }

    private func handleUserTurnComplete(transcript: String, source: String) {
        guard shouldProcessUserTurn(transcript: transcript) else {
            debugLog("user turn ignored source=\(source)")
            return
        }
        let handled = handleUserUtterance(transcript)
        if handled {
            debugLog("user turn handled by intent source=\(source)")
            return
        }
        let instruction = """
        Call memory_set with the relevant keys for the last question_id in pinned state. Then speak a short, human reflection (1–2 sentences) based on the user's last answer. Then gently transition and ask the next missing question (ONE question only). Then wait. Do not invent facts.
        """
        sendResponseCreate(instructions: instruction)
        debugLog("user turn committed source=\(source) transcript_len=\(transcript.count)")
    }

    private func handleTranscriptionFailure(source: String) {
        let now = Date()
        if now.timeIntervalSince(lastTranscriptFailureAt) < 1.5 {
            return
        }
        lastTranscriptFailureAt = now
        debugLog("transcription failed source=\(source) in_progress=\(responseInProgress) audio=\(isOutputAudioActive)")
        sendResponseCreate(instructions: "I did not catch that. Please repeat.")
    }

    private func extractTranscript(from obj: [String: Any]) -> String? {
        if let transcript = obj["transcript"] as? String, !transcript.isEmpty {
            return transcript
        }
        if let item = obj["item"] as? [String: Any] {
            if let transcript = item["transcript"] as? String, !transcript.isEmpty {
                return transcript
            }
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if let transcript = part["transcript"] as? String, !transcript.isEmpty {
                        return transcript
                    }
                }
            }
        }
        return nil
    }

    private func requestHighlightSummary() async {
        guard !userId.isEmpty else { return }
        let noteQuestionId = pendingNoteQuestionId
        pendingNoteQuestionId = nil
        let url = backendBase.appendingPathComponent("/onboarding/agent/tool")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId,
            "tool_name": "memory_review",
            "arguments": ["style": "highlight"]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            if
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let inner = json["data"] as? [String: Any],
                let output = inner["output"] as? [String: Any],
                let summary = output["summary"] as? String
            {
                appendNote(summary: summary, questionId: noteQuestionId)
            }
        } catch {
            return
        }
    }

    private func localStateKey() -> String {
        guard !userId.isEmpty else { return localStatePrefix + "default" }
        return localStatePrefix + userId
    }

    private func syncPendingKey() -> String {
        guard !userId.isEmpty else { return syncPendingPrefix + "default" }
        return syncPendingPrefix + userId
    }

    private func loadLocalState() {
        let key = localStateKey()
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            let state = try JSONDecoder().decode(KaiLocalState.self, from: data)
            DispatchQueue.main.async {
                self.discovery = state.discovery
                self.notes = state.notes
                self.completedQuestions = state.completedQuestions
                self.totalQuestions = state.totalQuestions
                self.isComplete = state.isComplete
                self.missingKeys = []
                self.nextQuestionId = ""
                self.createdAt = state.createdAt
                self.lastQuestionId = state.lastQuestionId
            }
        } catch {
            return
        }
    }

    private func saveLocalState() {
        let key = localStateKey()
        let state = KaiLocalState(
            createdAt: createdAt,
            discovery: discovery,
            notes: notes,
            completedQuestions: completedQuestions,
            totalQuestions: totalQuestions,
            isComplete: isComplete,
            lastQuestionId: lastQuestionId
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func syncStateToSupabase() async {
        guard !userId.isEmpty else { return }
        let url = backendBase.appendingPathComponent("/onboarding/agent/sync")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "user_id": userId,
            "state": exportStateForSync()
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                UserDefaults.standard.set(true, forKey: syncPendingKey())
                return
            }
            UserDefaults.standard.set(false, forKey: syncPendingKey())
        } catch {
            UserDefaults.standard.set(true, forKey: syncPendingKey())
        }
    }

    func scheduleSupabaseSyncIfNeeded() {
        let pending = UserDefaults.standard.bool(forKey: syncPendingKey())
        if pending || isComplete {
            Task.detached { [weak self] in
                await self?.syncStateToSupabase()
            }
        }
    }

    func markSyncPending() {
        UserDefaults.standard.set(true, forKey: syncPendingKey())
    }

    private func exportStateForSync() -> [String: Any] {
        let noteDicts: [[String: Any]] = notes.map {
            [
                "id": $0.id.uuidString,
                "ts": ISO8601DateFormatter().string(from: $0.ts),
                "question_id": $0.questionId,
                "text": $0.text
            ]
        }
        return [
            "agent": ["name": "Kai"],
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: Date()),
            "phase": isComplete ? "complete" : "discovery",
            "last_question_id": lastQuestionId ?? "",
            "discovery": discovery,
            "notes": noteDicts
        ]
    }

    func updateDiscovery(patch: [String: String]) async {
        guard !userId.isEmpty else { return }
        let url = backendBase.appendingPathComponent("/onboarding/agent/tool")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId,
            "tool_name": "memory_set",
            "arguments": [
                "patch": [
                    "discovery": patch
                ]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            _ = data
            try await fetchConfig()
        } catch {
            return
        }
    }

    private func handleToolCall(callId: String, toolName: String, arguments: Any) {
        guard !userId.isEmpty else { return }
        Task.detached { [weak self] in
            await self?.forwardToolCall(callId: callId, toolName: toolName, arguments: arguments)
        }
    }

    private func forwardToolCall(callId: String, toolName: String, arguments: Any) async {
        guard !userId.isEmpty else { return }
        let url = backendBase.appendingPathComponent("/onboarding/agent/tool")
        debugLog("tool call start: \(toolName) callId=\(callId)")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = backendTimeout
        let payload: [String: Any] = [
            "user_id": userId,
            "tool_name": toolName,
            "arguments": arguments
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        debugLog("tool call forward name=\(toolName) user_id=\(userId)")
        if debugVerboseJSON, let body = String(data: req.httpBody ?? Data(), encoding: .utf8) {
            debugLog("tool payload \(body)")
        }
        await MainActor.run {
            self.toolStatusText = "Sending tool: \(toolName)"
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Tool error"
                debugLog("tool call failed name=\(toolName) status=\(String(describing: (resp as? HTTPURLResponse)?.statusCode)) msg=\(msg)")
                await MainActor.run {
                    self.toolStatusText = "Tool failed: \(toolName)"
                }
                debugLog("tool call failed: \(toolName) callId=\(callId)")
                let errorOutput = stringifyToolOutput(["error": msg])
                sendEvent([
                    "type": "conversation.item.create",
                    "item": [
                        "type": "function_call_output",
                        "call_id": callId,
                        "output": errorOutput
                    ]
                ])
                return
            }
            if debugVerboseJSON, let raw = String(data: data, encoding: .utf8) {
                debugLog("tool response \(raw)")
            }
            await MainActor.run {
                self.toolStatusText = "Tool ok: \(toolName)"
            }
            debugLog("tool call ok: \(toolName) callId=\(callId)")

            let output: Any
            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let dict = json as? [String: Any], let inner = dict["output"] {
                    output = inner
                } else {
                    output = json
                }
            } else {
                output = String(data: data, encoding: .utf8) ?? ""
            }

            let outputString = stringifyToolOutput(output)
            sendEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": outputString
                ]
            ])

            if toolName == "memory_set" {
                await updateFromToolOutput(output)
                await applyMemorySetPatchToLocalState(arguments: arguments)
                await appendLocalNoteFromMemorySet(arguments: arguments)
                queueNextQuestion(afterToolCallId: callId)
            } else {
                debugLog("tool output sent (no auto response): \(toolName)")
            }
        } catch {
            let errorOutput = stringifyToolOutput(["error": error.localizedDescription])
            sendEvent([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": errorOutput
                ]
            ])
            await MainActor.run {
                self.toolStatusText = "Tool error: \(toolName)"
            }
            debugLog("tool call error: \(toolName) callId=\(callId) err=\(error.localizedDescription)")
        }
    }

    private func shouldProcessToolCall(callId: String, toolName: String) -> Bool {
        if processedToolCallIds.contains(callId) {
            debugLog("tool call skipped (duplicate) \(toolName) callId=\(callId)")
            return false
        }
        processedToolCallIds.insert(callId)
        return true
    }

    private func stringifyToolOutput(_ output: Any) -> String {
        if let str = output as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: []) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return "\(output)"
    }

    private func queueNextQuestion(afterToolCallId callId: String) {
        pendingNextQuestionTask?.cancel()
        pendingNextQuestionCallId = callId
        awaitingToolContinuation = true
        debugLog("awaiting tool continuation id=\(callId)")
        pendingNextQuestionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !self.awaitingToolContinuation { return }
            if self.responseInProgress {
                self.debugLog("tool continuation still in progress; deferring fallback")
                return
            }
            if self.lastResponseHadSpeech {
                self.awaitingToolContinuation = false
                self.debugLog("tool continuation skipped (assistant already spoke)")
                return
            }
            self.awaitingToolContinuation = false
            self.sendNextQuestionIfAvailable()
            self.debugLog("sent next question after tool fallback timeout")
        }
    }

    private func refreshConfigAndSession() async {
        do {
            try await fetchConfig()
            await MainActor.run {
                self.refreshSessionUpdate()
            }
        } catch {
            return
        }
    }

    private func refreshConfigOnly() async {
        do {
            try await fetchConfig()
        } catch {
            return
        }
    }

    private func setSpeakingState(_ speaking: Bool) {
        guard !isMuted else { return }
        if speaking {
            if state != .speaking {
                state = .speaking
                orbConfiguration = Self.makeOrbConfig(state: .speaking, energy: 0.85)
            }
        } else {
            if state == .speaking {
                state = isMuted ? .muted : .listening
                orbConfiguration = Self.makeOrbConfig(state: state, energy: isMuted ? 0.35 : 0.55)
            }
        }
    }

    private func markSpeakingActive() {
        setSpeakingState(true)

        // Fallback if response lifecycle events are missing.
        speakingPulseToken = UUID()
        let token = speakingPulseToken
        speakingHoldTask?.cancel()
        speakingHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000) // 1.4s hold
            if self.speakingPulseToken == token {
                self.setSpeakingState(false)
            }
        }
    }

    private func markSpeakingInactive() {
        speakingHoldTask?.cancel()
        setSpeakingState(false)
    }

    // Orb config mapping
    static func makeOrbConfig(state: OrbState, energy: Double) -> OrbConfiguration {
        // Blue/purple like reference
        let bg: [Color] = [.purple, .blue, .indigo]
        let glow = Color.white

        let speed: Double
        let core: Double

        switch state {
        case .connecting:
            speed = 22
            core = 0.8
        case .listening:
            speed = 45
            core = 1.0
        case .speaking:
            speed = 90
            core = 1.6
        case .muted:
            speed = 18
            core = 0.6
        case .error:
            speed = 10
            core = 0.4
        }

        return OrbConfiguration(
            backgroundColors: bg,
            glowColor: glow,
            coreGlowIntensity: core * energy,
            showBackground: true,
            showWavyBlobs: true,
            showParticles: true,
            showGlowEffects: true,
            showShadow: true,
            speed: speed
        )
    }
}

// ======================================================
// MARK: - LKRTCPeerConnectionDelegate
// ======================================================

extension KaiVoiceViewModel: LKRTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        debugLog("ice connection state=\(newState.rawValue)")
        switch newState {
        case .failed, .disconnected:
            scheduleReconnect(reason: "ice_\(newState.rawValue)")
        default:
            break
        }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        // Remote audio plays automatically through WebRTC once connected.
    }
}

// ======================================================
// MARK: - LKRTCDataChannelDelegate
// ======================================================

extension KaiVoiceViewModel: LKRTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        debugLog("dataChannel state=\(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            reconnectAttempts = 0
            reconnectTask = nil
            DispatchQueue.main.async {
                self.state = self.isMuted ? .muted : .listening
                self.orbConfiguration = Self.makeOrbConfig(state: self.state, energy: self.isMuted ? 0.35 : 0.55)
            }
            if !isMuted {
                localAudioTrack?.isEnabled = true
            }
            debugLog("dataChannel open localTrackEnabled=\(localAudioTrack?.isEnabled == true) muted=\(isMuted)")
            debugLog("dataChannel open")
            sendInitialSessionUpdate()
        } else if dataChannel.readyState == .closed || dataChannel.readyState == .closing {
            debugLog("dataChannel closed")
            scheduleReconnect(reason: "datachannel_closed")
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary else { return }
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }

        let type = (obj["type"] as? String) ?? ""
        logEvent(type, obj: obj)

        if type == "session.created" {
            sessionReady = true
            if let pending = pendingInitialResponse {
                sendResponseCreateResponse(pending, reason: pendingInitialReason ?? "initial_pending")
                pendingInitialResponse = nil
                pendingInitialReason = nil
            }
        }
        if type == "session.updated" {
            sessionReady = true
            if let pending = pendingInitialResponse {
                sendResponseCreateResponse(pending, reason: pendingInitialReason ?? "initial_pending")
                pendingInitialResponse = nil
                pendingInitialReason = nil
            }
        }

        if type == "output_audio_buffer.started" || type == "response.audio.started" {
            isOutputAudioActive = true
            lastResponseHadSpeech = true
            if !isMuted && !didMuteForOutput {
                localAudioTrack?.isEnabled = false
                didMuteForOutput = true
            }
            debugLog("output audio started localTrackEnabled=\(localAudioTrack?.isEnabled == true) didMuteForOutput=\(didMuteForOutput)")
        }
        if type == "output_audio_buffer.cleared"
            || type == "output_audio_buffer.stopped"
            || type == "response.audio.done"
            || type == "response.completed"
            || type == "response.canceled"
            || type == "response.failed"
            || type == "response.stopped" {
            isOutputAudioActive = false
            if !isMuted {
                localAudioTrack?.isEnabled = true
            }
            didMuteForOutput = false
            debugLog("output audio stopped localTrackEnabled=\(localAudioTrack?.isEnabled == true)")
            flushPendingResponseIfReady()
        }

        if type == "response.created" || type == "response.started" {
            responseInProgress = true
            lastResponseHadSpeech = false
        }
        if type == "response.done"
            || type == "response.completed"
            || type == "response.canceled"
            || type == "response.failed"
            || type == "response.stopped" {
            responseInProgress = false
            if awaitingToolContinuation {
                let shouldSend = !lastResponseHadSpeech
                awaitingToolContinuation = false
                pendingNextQuestionTask?.cancel()
                pendingNextQuestionCallId = nil
                if shouldSend {
                    sendNextQuestionIfAvailable()
                    debugLog("sent next question after response done")
                } else {
                    debugLog("tool continuation skipped (assistant already spoke)")
                }
            }
            flushPendingResponseIfReady()
        }

        if type.hasPrefix("response.") {
            let isTerminal = type == "response.done"
                || type == "response.completed"
                || type == "response.canceled"
                || type == "response.failed"
                || type == "response.stopped"
            if !isTerminal {
                responseInProgress = true
            }
            lastResponseEventAt = Date()
            responseWatchdogTask?.cancel()
            responseRetryCount = 0
        }

        if type == "input_audio_transcript.delta" {
            if let delta = obj["delta"] as? String {
                userTranscriptBuffer.append(delta)
            }
        }

        if type == "input_audio_buffer.speech_stopped" {
            debugLog("speech_stopped")
        }
        if type == "input_audio_buffer.speech_started" {
            debugLog("speech_started localTrackEnabled=\(localAudioTrack?.isEnabled == true) muted=\(isMuted)")
        }

        if type == "input_audio_buffer.committed" {
            let fallback = userTranscriptBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                handleUserTurnComplete(transcript: fallback, source: "buffer.committed")
                userTranscriptBuffer = ""
            }
        }

        if type == "input_audio_transcript.done" {
            if Date().timeIntervalSince(lastUserTurnAt) < 0.8 {
                userTranscriptBuffer = ""
                debugLog("input_audio_transcript.done ignored (recent turn)")
                return
            }
            let transcript = (obj["transcript"] as? String) ?? userTranscriptBuffer
            userTranscriptBuffer = ""
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                handleTranscriptionFailure(source: "input_audio_transcript.done")
                return
            }
            handleUserTurnComplete(transcript: transcript, source: "input_audio_transcript.done")
        }

        if type == "conversation.item.input_audio_transcription.completed" {
            if let transcript = extractTranscript(from: obj) {
                handleUserTurnComplete(transcript: transcript, source: "transcription.completed")
            } else {
                handleTranscriptionFailure(source: "transcription.completed")
            }
        }
        if type == "conversation.item.input_audio_transcription.failed" {
            handleTranscriptionFailure(source: "transcription.failed")
        }

        if type == "conversation.item.created" {
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call_output",
               let callId = item["call_id"] as? String,
               callId == pendingNextQuestionCallId {
                pendingNextQuestionCallId = nil
                pendingNextQuestionTask?.cancel()
                debugLog("function_call_output acked for \(callId)")
            }
            if let userText = extractUserText(from: obj) {
                _ = handleUserUtterance(userText)
            }
        }

        handleToolEvent(type: type, obj: obj)

        if type == "response.started" || type == "response.created" || type == "response.output_item.added" {
            DispatchQueue.main.async { self.markSpeakingActive() }
        } else if type == "response.completed" || type == "response.canceled" || type == "response.failed" || type == "response.stopped" {
            DispatchQueue.main.async { self.markSpeakingInactive() }
        } else if type.hasPrefix("response.") && type.contains("delta") {
            // Fallback for streaming deltas when lifecycle events are not emitted.
            DispatchQueue.main.async { self.markSpeakingActive() }
        }

        if type == "error" {
            let errDict = obj["error"] as? [String: Any]
            let errMsg = errDict?["message"] as? String
            let errCode = errDict?["code"] as? String
            if let errMsg, errMsg.contains("turn_detection.threshold") || errMsg.contains("max decimal places") {
                return
            }
            if errCode == "conversation_already_has_active_response" {
                responseInProgress = true
                debugLog("response.create rejected: active response")
                return
            }
            DispatchQueue.main.async {
                self.state = .error
                self.errorText = errMsg ?? "Realtime error"
                self.orbConfiguration = Self.makeOrbConfig(state: .error, energy: 0.35)
                self.toolStatusText = "Realtime error"
            }
            debugLog("realtime error: \(errMsg ?? "unknown")")
        }
    }
}

private extension KaiVoiceViewModel {
    func scheduleReconnect(reason: String) {
        guard allowReconnect else {
            debugLog("reconnect skipped (disabled) reason=\(reason)")
            return
        }
        guard !userId.isEmpty else { return }
        if reconnectTask != nil {
            debugLog("reconnect already scheduled reason=\(reason)")
            return
        }
        guard reconnectAttempts < 2 else {
            debugLog("reconnect attempts exhausted reason=\(reason)")
            return
        }
        reconnectAttempts += 1
        reconnectTask = Task { @MainActor in
            self.debugLog("reconnect scheduled reason=\(reason) attempt=\(self.reconnectAttempts)")
            self.state = .connecting
            self.errorText = nil
            self.orbConfiguration = Self.makeOrbConfig(state: .connecting, energy: 0.4)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.stop(keepReconnect: true)
            self.start(userId: self.userId, preserveState: true)
            self.reconnectTask = nil
        }
    }

    func sendResponseCreateResponse(_ response: [String: Any], reason: String) {
        guard dataChannel?.readyState == .open else {
            debugLog("response.create dropped reason=\(reason) dataChannel not open")
            return
        }
        var response = response
        let instructions = response["instructions"] as? String
        let instructionLen = instructions?.count ?? 0
        let modalitiesArray = response["modalities"] as? [String] ?? []
        let modalities = modalitiesArray.joined(separator: ",")
        if modalitiesArray.contains("audio"), response["voice"] == nil {
            response["voice"] = voiceId
        }
        if responseInProgress || isOutputAudioActive {
            pendingQueuedResponse = response
            pendingQueuedReason = reason
            debugLog("response.create queued reason=\(reason) inProgress=\(responseInProgress) audio=\(isOutputAudioActive) modalities=\(modalities) instr_len=\(instructionLen)")
            return
        }
        lastResponseHadSpeech = false
        responseInProgress = true
        beginResponseTracking(isRetry: false, instructions: instructions, wasAuto: false)
        sendEvent([
            "type": "response.create",
            "response": response
        ])
        debugLog("response.create sent reason=\(reason) modalities=\(modalities) instr_len=\(instructionLen)")
    }

    func flushPendingResponseIfReady() {
        guard !responseInProgress, !isOutputAudioActive else { return }
        guard let pending = pendingQueuedResponse else { return }
        let reason = pendingQueuedReason ?? "queued"
        pendingQueuedResponse = nil
        pendingQueuedReason = nil
        sendResponseCreateResponse(pending, reason: reason)
    }

    func logEvent(_ type: String, obj: [String: Any]) {
        guard debugEnabled, debugEventWhitelist.contains(type) else { return }
        var details: [String] = []

        if type == "input_audio_buffer.committed" {
            details.append("buffer_len=\(userTranscriptBuffer.count)")
        }

        if type == "input_audio_transcript.done" {
            let transcript = (obj["transcript"] as? String) ?? ""
            details.append("transcript_len=\(transcript.count)")
        }

        if type == "conversation.item.input_audio_transcription.failed" || type == "error" {
            let err = obj["error"] as? [String: Any]
            if let code = err?["code"] as? String {
                details.append("error_code=\(code)")
            }
            if let message = (err?["message"] as? String) ?? (obj["message"] as? String) {
                details.append("error_message=\(message)")
            }
        }

        if let itemId = (obj["item"] as? [String: Any])?["id"] as? String {
            details.append("item_id=\(itemId)")
        }

        let suffix = details.isEmpty ? "" : " " + details.joined(separator: " ")
        debugLog("event=\(type)\(suffix)")

        if debugVerboseJSON && (type == "conversation.item.input_audio_transcription.failed" || type == "error") {
            logOutgoingJSON(obj, label: "event \(type)")
        }
    }

    func debugLog(_ message: String) {
        guard debugEnabled else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        print("🧭 [KaiDebug] \(ts) \(message)")
    }

    func beginResponseTracking(isRetry: Bool, instructions: String?, wasAuto: Bool) {
        if !isRetry {
            responseRetryCount = 0
        }
        lastResponseInstructions = instructions
        lastResponseWasAuto = wasAuto
        startResponseWatchdog(reason: wasAuto ? "response.create(auto)" : "response.create")
    }

    func sendResponseCreatePayload(instructions: String?, isRetry: Bool, reason: String) {
        guard let instructions, !instructions.isEmpty else {
            debugLog("response.create blocked (no instructions) reason=\(reason)")
            return
        }
        let response: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": instructions
        ]
        sendResponseCreateResponse(response, reason: reason)
    }

    func sendToolOnlyResponse(instructions: String, reason: String) {
        let response: [String: Any] = [
            "modalities": ["text"],
            "instructions": instructions
        ]
        sendResponseCreateResponse(response, reason: reason)
    }

    func retryLastResponse(reason: String) {
        _ = reason
    }

    func startResponseWatchdog(reason: String) {
        _ = reason
    }
}
