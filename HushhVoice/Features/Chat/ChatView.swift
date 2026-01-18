import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SafariServices

struct ChatView: View {
    @StateObject private var store = ChatStore()
    @ObservedObject private var audioCapture = AudioCaptureManager.shared
    @ObservedObject private var streamClient = ChatStreamClient.shared
    @ObservedObject var auth = GoogleSignInManager.shared
    @ObservedObject var speech = SpeechManager.shared

    @AppStorage("hv_has_completed_investor_onboarding") private var hvDone: Bool = false
    @State private var showInvestorOnboarding: Bool = false

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @AppStorage("hushh_kai_user_id") private var kaiUserID: String = ""
    @AppStorage("hushh_is_dark") private var isDarkMode: Bool = true
    @AppStorage("hushh_has_seen_intro") private var hasSeenIntro: Bool = false
    @AppStorage("hushh_guest_mode") private var isGuest: Bool = false

    @State private var input: String = ""
    @State private var sending = false
    @State private var showTyping = false
    @State private var showSidebar: Bool = false
    @State private var showingSettings = false
    @State private var showingIntro = false
    @State private var animatingAssistantID: UUID?
    @State private var showGoogleGate: Bool = false
    @State private var gatedPrompt: String = ""
    @State private var showAttachmentPicker = false
    @State private var lastAttachmentError: String?
    @State private var showEditConfirmation = false
    @State private var editingConfirmation: ChatConfirmation?
    @State private var editedConfirmationText: String = ""
    @StateObject private var micMonitor = MicLevelMonitor()

    @State private var isReviewingHistory = false
    @State private var isFollowingLive = true
    @State private var isAtBottom = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var contentOffset: CGFloat = 0
    @State private var autoSpeakNextAssistant = false
    @State private var assistantTextVisible = false
    @State private var assistantStatusText: String?
    @State private var audioStreamActive = false
    @State private var pendingSpeechText = ""
    @State private var streamingSpeechActive = false
    @State private var cancelledTurnID: String?
    @State private var safariLink: IdentifiedURL?
    @State private var scrollWorkItem: DispatchWorkItem?

    private let emptyPhrases = [
        "Hi, I'm HushhVoice. How may I help you?",
        "Ready when you are — ask me anything.",
        "Your data. Your business. How can I assist?",
        "Let’s build something useful. What’s on your mind?",
        "Ask away. I’ll keep it crisp."
    ]
    @State private var currentEmptyPhrase: String = ""

    private var isAuthenticated: Bool {
        isGuest || auth.isSignedIn || !appleUserID.isEmpty
    }

    private var isListeningActive: Bool {
        !audioCapture.isMuted && (audioCapture.isCapturing || store.turnState == .listening || store.turnState == .finalizingInput)
    }

    private var isStreamingReady: Bool {
        HushhAPI.enableStreaming && streamClient.state == .connected
    }

    var body: some View {
        Group {
            if !isAuthenticated {
                AuthGateView()
            } else {
                mainChat
                    .onAppear {
                        if !hvDone {
                            showInvestorOnboarding = true
                        }
                    }
                    .sheet(isPresented: $showInvestorOnboarding) {
                        Onboarding()
                    }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            HVTheme.setMode(isDark: isDarkMode)
            auth.loadFromDisk()
            if auth.isSignedIn || !appleUserID.isEmpty {
                isGuest = false
            }
            configureAudioCallbacks()
            configureStreamCallbacks()
        }
        .onDisappear {
            micMonitor.stop()
        }
        .onChange(of: isDarkMode) { _, newValue in
            HVTheme.setMode(isDark: newValue)
        }
    }

    private var mainChat: some View {
        // Core chat layout: header, messages, composer, sidebar.
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                HeaderBar {
                    withAnimation(.easeInOut(duration: 0.22)) { showSidebar.toggle() }
                } onGoToHushhTech: {
                    showInvestorOnboarding = true
                }

                GeometryReader { scrollGeo in
                    ScrollViewReader { proxy in
                        let scrollToBottom = {
                            if let id = store.activeMessages.last?.id {
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) }
                            } else if let draft = store.draftUserMessage {
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(draft.id, anchor: .bottom) }
                            } else if let streaming = store.streamingAssistantMessage {
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(streaming.id, anchor: .bottom) }
                            }
                        }

                        let snapToBottom = {
                            if let id = store.activeMessages.last?.id {
                                withAnimation(.none) { proxy.scrollTo(id, anchor: .bottom) }
                            } else if let draft = store.draftUserMessage {
                                withAnimation(.none) { proxy.scrollTo(draft.id, anchor: .bottom) }
                            } else if let streaming = store.streamingAssistantMessage {
                                withAnimation(.none) { proxy.scrollTo(streaming.id, anchor: .bottom) }
                            }
                        }

                        ZStack(alignment: .bottomTrailing) {
                            ScrollView {
                                VStack(spacing: 0) {
                                    Color.clear
                                        .frame(height: 0)
                                        .background(
                                            GeometryReader { geo in
                                                Color.clear.preference(
                                                    key: ChatScrollOffsetKey.self,
                                                    value: geo.frame(in: .named("chatScroll")).minY
                                                )
                                            }
                                        )

                                    LazyVStack(alignment: .leading, spacing: 14) {
                                        ForEach(store.activeMessages) { msg in
                                            let isLast = isLastAssistant(msg)
                                            let hideControls = (msg.role == .assistant && msg.id == animatingAssistantID)

                                            MessageRow(
                                                message: msg,
                                                isLastAssistant: isLast,
                                                hideControls: hideControls,
                                                isSpeaking: speech.currentMessageID == msg.id && speech.isPlaying,
                                                isLoadingTTS: speech.currentMessageID == msg.id && speech.isLoading,
                                                isSubdued: msg.role == .assistant && (speech.isPlaying || store.isAssistantStreaming),
                                                onOpenURL: { safariLink = IdentifiedURL(url: $0) },
                                                onCopy: { UIPasteboard.general.string = msg.text },
                                                onSpeakToggle: { handleSpeakToggle(for: msg) },
                                                onReload: {
                                                    Task {
                                                        let token = await auth.ensureValidAccessToken()
                                                        await store.regenerate(at: msg.id, googleToken: token)
                                                    }
                                                }
                                            )
                                            .id(msg.id)
                                        }

                                        if let draft = store.draftUserMessage {
                                            MessageRow(
                                                message: draft,
                                                isLastAssistant: false,
                                                hideControls: true,
                                                isSpeaking: false,
                                                isLoadingTTS: false,
                                                isSubdued: false,
                                                isDraft: true,
                                                onOpenURL: { safariLink = IdentifiedURL(url: $0) }
                                            )
                                            .id(draft.id)
                                        }

                                        if let streaming = store.streamingAssistantMessage, assistantTextVisible {
                                            MessageRow(
                                                message: streaming,
                                                isLastAssistant: false,
                                                hideControls: true,
                                                isSpeaking: false,
                                                isLoadingTTS: false,
                                                isSubdued: true,
                                                isStreaming: true,
                                                onOpenURL: { safariLink = IdentifiedURL(url: $0) }
                                            )
                                            .id(streaming.id)
                                        }

                                        if let status = assistantStatusText {
                                            ProgressRowView(text: status)
                                                .id("assistant-status")
                                        }

                                        if let progress = store.progressText {
                                            ProgressRowView(text: progress)
                                                .id("tool-progress")
                                        }

                                        ForEach(store.confirmations.filter { $0.status == .pending }) { confirmation in
                                            ConfirmationCardView(
                                                confirmation: confirmation,
                                                onConfirm: { handleConfirmationDecision(confirmation, decision: "accept") },
                                                onEdit: { openConfirmationEdit(confirmation) },
                                                onCancel: { handleConfirmationDecision(confirmation, decision: "reject") }
                                            )
                                            .id(confirmation.id)
                                        }

                                        if showTyping { TypingIndicatorView().id("typing") }
                                    }
                                    .padding(.vertical, 12)
                                }
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(key: ChatContentHeightKey.self, value: geo.size.height)
                                    }
                                )
                            }
                            .coordinateSpace(name: "chatScroll")
                            .onPreferenceChange(ChatScrollOffsetKey.self) { offset in
                                contentOffset = offset
                                updateScrollState()
                            }
                            .onPreferenceChange(ChatContentHeightKey.self) { height in
                                contentHeight = height
                                updateScrollState()
                            }
                            .simultaneousGesture(
                                DragGesture().onChanged { _ in
                                    if isFollowingLive {
                                        isFollowingLive = false
                                        isReviewingHistory = true
                                    }
                                }
                            )
                            if store.activeMessages.isEmpty
                                && store.draftUserMessage == nil
                                && store.streamingAssistantMessage == nil {
                                VStack {
                                    Spacer()
                                    VStack(spacing: 10) {
                                        Text(currentEmptyPhrase)
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(HVTheme.botText.opacity(0.9))

                                        Rectangle().fill(HVTheme.botText.opacity(0.06)).frame(width: 220, height: 8).cornerRadius(4)
                                        Rectangle().fill(HVTheme.botText.opacity(0.06)).frame(width: 260, height: 8).cornerRadius(4)
                                        Rectangle().fill(HVTheme.botText.opacity(0.06)).frame(width: 180, height: 8).cornerRadius(4)
                                    }
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .transition(.opacity.combined(with: .scale))
                                    Spacer()
                                }
                            }

                            if !isFollowingLive && !isAtBottom {
                                Button(action: {
                                    isFollowingLive = true
                                    isReviewingHistory = false
                                    snapToBottom()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        snapToBottom()
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.down")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("Jump to Live")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(HVTheme.surfaceAlt.opacity(0.96))
                                            .overlay(Capsule().stroke(HVTheme.stroke))
                                    )
                                }
                                .foregroundStyle(HVTheme.botText)
                                .padding(.trailing, 18)
                                .padding(.bottom, 18)
                            }
                        }
                        .onAppear { scrollViewHeight = scrollGeo.size.height }
                        .onChange(of: scrollGeo.size.height) { _, newValue in
                            scrollViewHeight = newValue
                            updateScrollState()
                        }
                        .onChange(of: store.activeMessages.last?.id) { _, id in
                            if let id, isFollowingLive {
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) }
                            }

                            if let last = store.activeMessages.last, last.role == .assistant {
                                animatingAssistantID = last.id
                                let textLength = last.text.count
                                let totalTime = Double(textLength) * 0.01 + 0.25
                                Task {
                                    try? await Task.sleep(nanoseconds: UInt64(totalTime * 1_000_000_000))
                                    await MainActor.run {
                                        if animatingAssistantID == last.id { animatingAssistantID = nil }
                                    }
                                }

                            if autoSpeakNextAssistant, !speech.isPlaying, !speech.isLoading {
                                autoSpeakNextAssistant = false
                                speech.speak(last.text, messageID: last.id)
                            }
                        }
                        }
                        .onChange(of: store.draftUserText) { _, _ in
                            if isFollowingLive { scheduleScrollToBottom(scrollToBottom) }
                        }
                        .onChange(of: store.streamingAssistantText) { _, _ in
                            if isFollowingLive { scheduleScrollToBottom(scrollToBottom) }
                        }
                        .onChange(of: store.progressText) { _, _ in
                            if isFollowingLive { scheduleScrollToBottom(scrollToBottom) }
                        }
                        .onChange(of: showTyping) { _, typing in
                            if typing && isFollowingLive { scheduleScrollToBottom(scrollToBottom) }
                        }
                    }
                }

                Divider().background(HVTheme.stroke)

                if isListeningActive {
                    VoiceCaptureBar(
                        micLevel: micMonitor.level,
                        isMuted: audioCapture.isMuted,
                        onMicToggle: { toggleMic() }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack {
                        ComposerView(
                            text: $input,
                            isSending: sending,
                            isSendDisabled: sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            isMicMuted: audioCapture.isMuted,
                            attachments: store.pendingAttachments,
                            onSend: { Task { await send() } },
                            onAttach: { showAttachmentPicker = true },
                            onMicToggle: { toggleMic() },
                            onRemoveAttachment: { store.removePendingAttachment($0) }
                        )
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isListeningActive)
            .background(HVTheme.bg.ignoresSafeArea())

            if let hint = store.hintText {
                VStack {
                    ChatHintBanner(text: hint)
                        .padding(.top, 10)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            }

            if showSidebar {
                Color.black.opacity(HVTheme.scrimOpacity)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.22)) { showSidebar = false }
                    }

                ChatSidebar(store: store, showingSettings: $showingSettings, isCollapsed: $showSidebar)
                    .frame(width: HVTheme.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .tint(HVTheme.accent)
        .sheet(isPresented: $showingSettings) {
            SettingsView(isDarkMode: $isDarkMode, google: auth, store: store, isGuest: $isGuest, onSignOutAll: handleSignOut)
        }
        .sheet(isPresented: $showingIntro) {
            OnboardingView()
        }
        .sheet(isPresented: $showEditConfirmation) {
            ConfirmationEditSheet(
                text: $editedConfirmationText,
                onSave: { applyConfirmationEdit() },
                onCancel: { cancelConfirmationEdit() }
            )
        }
        .sheet(item: $safariLink) { item in
            SafariView(url: item.url)
        }
        .alert("Connect Google to Continue", isPresented: $showGoogleGate) {
            Button("Go to Settings") { showingSettings = true }
            Button("Sign in with Google") { auth.signIn() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To answer Gmail or Calendar questions, connect Google in Settings.")
        }
        .alert("Attachment Error", isPresented: Binding(
            get: { lastAttachmentError != nil },
            set: { _ in lastAttachmentError = nil }
        )) {
            Button("OK", role: .cancel) { lastAttachmentError = nil }
        } message: {
            Text(lastAttachmentError ?? "Unknown error.")
        }
        .onAppear {
            randomizeEmptyPhrase()
            if !hasSeenIntro && hvDone {
                hasSeenIntro = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingIntro = true }
            }
        }
        .onChange(of: store.activeChatID) { _ in randomizeEmptyPhrase() }
        .onChange(of: audioCapture.lastError) { _, newValue in
            if let newValue {
                store.showHint(newValue)
            }
        }
        .onChange(of: audioCapture.isMuted) { _, muted in
            if muted {
                micMonitor.setMuted(true)
            } else {
                micMonitor.start()
                micMonitor.setMuted(false)
            }
            if !muted {
                self.isFollowingLive = true
                self.isReviewingHistory = false
            }
        }
        .onChange(of: speech.isPlaying) { _, playing in
            if playing {
                store.setTurnState(.speaking)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if audioCapture.isCapturing {
                    audioCapture.pauseCaptureForPlayback()
                }
            } else if store.turnState == .speaking {
                store.setTurnState(audioCapture.isMuted ? .idle : .listening)
                if !audioCapture.isMuted {
                    audioCapture.resumeCaptureAfterPlayback()
                }
            }
        }
        .fileImporter(
            isPresented: $showAttachmentPicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let attachment = ChatAttachment(fileName: url.lastPathComponent, sizeBytes: size)
                    store.addPendingAttachment(attachment)
                }
            case .failure(let err):
                lastAttachmentError = err.localizedDescription
            }
        }
    }


    private func isLastAssistant(_ msg: Message) -> Bool {
        // Used to decide which assistant message gets typing animation.
        guard msg.role == .assistant else { return false }
        guard let last = store.activeMessages.last(where: { $0.role == .assistant }) else { return false }
        return last.id == msg.id
    }

    private func randomizeEmptyPhrase() {
        // Pick a random empty-state prompt.
        currentEmptyPhrase = emptyPhrases.randomElement() ?? emptyPhrases[0]
    }

    private func send() async {
        // Send message, show typing state, and gate Google features if needed.
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        let needsGoogle = requiresGoogleIntegration(for: q)
        let token = await auth.ensureValidAccessToken()

        if needsGoogle && token == nil {
            gatedPrompt = q
            showGoogleGate = true
            return
        }

        sending = true
        input = ""
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        if isStreamingReady {
            store.setTurnState(.thinking)
            await sendStreaming(q, source: "keyboard")
        } else {
            if HushhAPI.enableStreaming {
                store.showHint("Live stream offline. Sending normally.")
            }
            showTyping = true
            await store.send(q, googleToken: token)
            showTyping = false
        }
        sending = false
    }

    private func toggleMic() {
        if audioCapture.isMuted {
            print("🎙️ [Chat] mic unmuted")
            if speech.isPlaying || speech.isLoading {
                speech.stop()
                store.setTurnState(.cancelled)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                isReviewingHistory = false
            }
            isFollowingLive = true
            store.setTurnState(.listening)
            audioCapture.setMuted(false)
        } else {
            print("🎙️ [Chat] mic muted")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            audioCapture.setMuted(true)
            store.cancelVoiceDraft()
            store.setTurnState(.idle)
        }
    }

    private func configureAudioCallbacks() {
        audioCapture.onSpeechStart = { [weak store, weak speech] in
            DispatchQueue.main.async {
                if speech?.isPlaying == true || speech?.isLoading == true || store?.isAssistantStreaming == true {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    if store?.isAssistantStreaming == true {
                        store?.finalizeAssistantStream(status: .interrupted)
                    } else if let currentID = speech?.currentMessageID {
                        store?.markMessageInterrupted(currentID)
                    }
                    if HushhAPI.enableStreaming, let turnID = store?.currentTurnID {
                        self.streamClient.send(
                            eventType: "user.interrupt",
                            payload: [
                                "reason": .string("barge_in"),
                                "cancel_turn_id": .string(turnID)
                            ],
                            turnID: turnID,
                            role: "user"
                        )
                        self.cancelledTurnID = turnID
                        store?.clearCurrentTurn()
                    }
                    speech?.stop()
                    store?.setTurnState(.cancelled)
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                store?.clearAssistantStream()
                self.autoSpeakNextAssistant = false
                self.assistantTextVisible = false
                self.assistantStatusText = nil
                self.pendingSpeechText = ""
                self.streamingSpeechActive = false
                self.audioStreamActive = false
                self.isFollowingLive = true
                self.isReviewingHistory = false
                store?.beginVoiceDraft()
                store?.setTurnState(.listening)
            }
        }
        audioCapture.onPartialTranscript = { [weak store] text in
            DispatchQueue.main.async {
                self.isFollowingLive = true
                store?.updateVoiceDraft(text)
            }
        }
        audioCapture.onSpeechEnd = { [weak store] in
            DispatchQueue.main.async {
                store?.setTurnState(.finalizingInput)
            }
        }
        audioCapture.onFinalTranscript = { text in
            Task { await handleVoiceFinalTranscript(text) }
        }
    }

    private func configureStreamCallbacks() {
        streamClient.onEvent = { event in
            DispatchQueue.main.async {
                handleStreamEvent(event)
            }
        }
            if HushhAPI.enableStreaming, let baseURL = HushhAPI.streamURL {
                var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                comps?.queryItems = [URLQueryItem(name: "session_id", value: streamClient.sessionID)]
                if let url = comps?.url {
                    print("🛰️ [Chat] connecting stream \(url.absoluteString)")
                    streamClient.connect(url: url, headers: ["X-Session-Token": HushhAPI.streamSessionToken])
                }
            }
        }

    private func handleStreamEvent(_ event: StreamEventEnvelope) {
        if let incomingTurn = event.turn_id,
           let cancelled = cancelledTurnID,
           incomingTurn == cancelled,
           event.event_type != "turn.start" {
            return
        }
        if let incomingTurn = event.turn_id,
           let currentTurn = store.currentTurnID,
           incomingTurn != currentTurn,
           event.event_type != "turn.start" {
            return
        }
        print("🛰️ [Chat] event \(event.event_type) turn=\(event.turn_id ?? "-")")
        switch event.event_type {
        case "assistant_audio.start":
            audioStreamActive = true
            assistantTextVisible = true
            assistantStatusText = nil
            pendingSpeechText = ""
            streamingSpeechActive = false
            if audioCapture.isCapturing {
                audioCapture.pauseCaptureForPlayback()
            }
            let sampleRate = event.payload.doubleValue("sample_rate") ?? 24_000
            let channels = Int(event.payload.doubleValue("channels") ?? 1)
            speech.startAudioStream(sampleRate: sampleRate, channels: channels, messageID: store.streamingAssistantID)
        case "assistant_audio.chunk":
            if let b64 = event.payload.string("pcm16_b64"),
               let data = Data(base64Encoded: b64) {
                speech.appendAudioChunk(data)
            }
        case "assistant_audio.end":
            audioStreamActive = false
            speech.finishAudioStream()
            if !audioCapture.isMuted {
                audioCapture.resumeCaptureAfterPlayback()
            }
        case "assistant_text.delta":
            store.applyStreamEvent(event)
            if audioStreamActive {
                assistantTextVisible = true
                assistantStatusText = nil
            } else if let text = event.payload.string("text") {
                handleAssistantTextDelta(text)
            }
        case "assistant_text.final":
            store.applyStreamEvent(event)
            if !audioStreamActive {
                flushPendingSpeech()
                speech.finishStreamingSpeech()
            }
            assistantStatusText = nil
            assistantTextVisible = false
        case "state.change":
            store.applyStreamEvent(event)
            if let toState = event.payload.string("to"), toState == "speaking" {
                if audioCapture.isCapturing {
                    audioCapture.pauseCaptureForPlayback()
                }
            }
        case "tool_call.progress":
            store.applyStreamEvent(event)
        case "turn.start":
            assistantStatusText = "Preparing response…"
            assistantTextVisible = false
            pendingSpeechText = ""
            streamingSpeechActive = false
            audioStreamActive = false
            cancelledTurnID = nil
            store.applyStreamEvent(event)
        case "turn.end":
            assistantStatusText = nil
            assistantTextVisible = false
            pendingSpeechText = ""
            streamingSpeechActive = false
            audioStreamActive = false
            speech.finishStreamingSpeech()
            store.applyStreamEvent(event)
            if !audioCapture.isMuted
                && !audioCapture.isCapturing
                && !speech.isPlaying
                && !speech.isLoading
                && !streamingSpeechActive
                && !audioStreamActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !audioCapture.isMuted {
                        audioCapture.startCapture()
                    }
                }
            }
        case "turn.cancelled":
            assistantStatusText = nil
            assistantTextVisible = false
            pendingSpeechText = ""
            streamingSpeechActive = false
            audioStreamActive = false
            cancelledTurnID = event.turn_id
            speech.finishStreamingSpeech()
            store.finalizeAssistantStream(status: .interrupted)
            store.applyStreamEvent(event)
            if !audioCapture.isMuted
                && !audioCapture.isCapturing
                && !speech.isPlaying
                && !speech.isLoading
                && !streamingSpeechActive
                && !audioStreamActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !audioCapture.isMuted {
                        audioCapture.startCapture()
                    }
                }
            }
        default:
            store.applyStreamEvent(event)
        }
    }

    private func handleAssistantTextDelta(_ text: String) {
        pendingSpeechText += text
        if !streamingSpeechActive {
            assistantStatusText = "Preparing response…"
        }
        guard let (segment, remaining) = nextSpeechSegment(from: pendingSpeechText) else { return }
        pendingSpeechText = remaining
        if !streamingSpeechActive {
            streamingSpeechActive = true
            assistantStatusText = nil
            assistantTextVisible = true
            if audioCapture.isCapturing {
                audioCapture.pauseCaptureForPlayback()
            }
            speech.startStreamingSpeech(messageID: store.streamingAssistantID)
        }
        speech.enqueueStreamingSegment(segment)
    }

    private func flushPendingSpeech() {
        let trimmed = pendingSpeechText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !streamingSpeechActive {
                streamingSpeechActive = true
                assistantTextVisible = true
                if audioCapture.isCapturing {
                    audioCapture.pauseCaptureForPlayback()
                }
                speech.startStreamingSpeech(messageID: store.streamingAssistantID)
            }
            speech.enqueueStreamingSegment(trimmed)
        }
        pendingSpeechText = ""
    }

    private func nextSpeechSegment(from text: String) -> (String, String)? {
        let threshold = 80
        let delimiters = [".", "?", "!", "\n"]
        for delimiter in delimiters {
            if let range = text.range(of: delimiter) {
                let idx = text.index(after: range.lowerBound)
                let segment = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let remaining = String(text[idx...])
                if !segment.isEmpty {
                    return (segment, remaining)
                }
            }
        }
        if text.count >= threshold {
            let idx = text.index(text.startIndex, offsetBy: threshold)
            let segment = String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let remaining = String(text[idx...])
            return (segment, remaining)
        }
        return nil
    }

    private func handleVoiceFinalTranscript(_ text: String?) async {
        if let text {
            store.updateVoiceDraft(text)
        }
        let sendText = store.finalizeVoiceDraft(appendToChat: true)
        if let sendText, !sendText.isEmpty {
            print("🎙️ [Chat] final transcript: \(sendText)")
            store.setTurnState(.thinking)
            if isStreamingReady {
                await sendStreaming(sendText, source: "voice")
            } else {
                if HushhAPI.enableStreaming {
                    store.showHint("Live stream offline. Sending normally.")
                }
                autoSpeakNextAssistant = true
                await sendVoice(sendText)
            }
        } else {
            print("🎙️ [Chat] empty transcript")
            store.setTurnState(audioCapture.isMuted ? .idle : .listening)
        }
    }

    private func sendVoice(_ transcript: String) async {
        let needsGoogle = requiresGoogleIntegration(for: transcript)
        let token = await auth.ensureValidAccessToken()

        if needsGoogle && token == nil {
            gatedPrompt = transcript
            showGoogleGate = true
            store.setTurnState(.idle)
            return
        }

        showTyping = true
        await store.sendVoiceTranscript(transcript, googleToken: token)
        showTyping = false
        store.setTurnState(audioCapture.isMuted ? .idle : .listening)
    }

    private func sendStreaming(_ text: String, source: String) async {
        let needsGoogle = requiresGoogleIntegration(for: text)
        let token = await auth.ensureValidAccessToken()

        if needsGoogle && token == nil {
            gatedPrompt = text
            showGoogleGate = true
            store.setTurnState(.idle)
            return
        }

        if source == "keyboard" {
            store.appendUserMessage(text)
        }

        assistantTextVisible = false
        assistantStatusText = "Preparing response…"
        pendingSpeechText = ""
        streamingSpeechActive = false
        audioStreamActive = false

        print("🛰️ [Chat] sendStreaming source=\(source) textLen=\(text.count)")
        var payload: [String: JSONValue] = [
            "text": .string(text),
            "source": .string(source)
        ]
        if let token {
            payload["google_access_token"] = .string(token)
        }
        streamClient.send(eventType: "text.input", payload: payload, role: "user")
    }

    private func handleConfirmationDecision(_ confirmation: ChatConfirmation, decision: String) {
        let payload: [String: JSONValue] = [
            "confirmation_request_id": .string(confirmation.id.uuidString),
            "decision": .string(decision),
        ]
        streamClient.send(eventType: "confirm.response", payload: payload, role: "user")
        if decision == "accept" {
            store.updateConfirmation(confirmation.id, status: .accepted)
        } else {
            store.updateConfirmation(confirmation.id, status: .rejected)
        }
    }

    private func openConfirmationEdit(_ confirmation: ChatConfirmation) {
        editingConfirmation = confirmation
        editedConfirmationText = confirmation.previewText
        showEditConfirmation = true
    }

    private func applyConfirmationEdit() {
        guard let confirmation = editingConfirmation else { return }
        let payload: [String: JSONValue] = [
            "confirmation_request_id": .string(confirmation.id.uuidString),
            "decision": .string("edit"),
            "edited_payload": .object(["text": .string(editedConfirmationText)])
        ]
        streamClient.send(eventType: "confirm.response", payload: payload, role: "user")
        store.updateConfirmation(confirmation.id, status: .edited)
        cancelConfirmationEdit()
    }

    private func cancelConfirmationEdit() {
        showEditConfirmation = false
        editingConfirmation = nil
        editedConfirmationText = ""
    }

    private func updateScrollState() {
        let threshold: CGFloat = 24
        let atBottom = (contentHeight + contentOffset) <= (scrollViewHeight + threshold)
        isAtBottom = atBottom
        if !atBottom {
            isFollowingLive = false
            isReviewingHistory = true
        } else {
            isFollowingLive = true
            if !audioCapture.isMuted {
                isReviewingHistory = false
            }
        }
    }

    private func scheduleScrollToBottom(_ action: @escaping () -> Void) {
        scrollWorkItem?.cancel()
        let work = DispatchWorkItem { action() }
        scrollWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func handleSpeakToggle(for msg: Message) {
        // Toggle TTS playback for the selected assistant message.
        if speech.currentMessageID == msg.id && (speech.isPlaying || speech.isLoading) {
            speech.stop()
        } else {
            speech.speak(msg.text, messageID: msg.id)
        }
    }

    private func handleSignOut() {
        // Sign out of all services and clear local state.
        AppleSupabaseAuth.shared.signOut()
        appleUserID = ""
        auth.signOut()
        isGuest = true
        speech.stop()
        store.clearMessagesInActiveChat()
    }

    private func requiresGoogleIntegration(for text: String) -> Bool {
        // Simple keyword check to decide if Google token is required.
        let lower = text.lowercased()
        let keywords = ["gmail", "email", "inbox", "calendar", "event", "meeting", "schedule"]
        return keywords.contains { lower.contains($0) }
    }
}

private struct VoiceCaptureBar: View {
    let micLevel: CGFloat
    let isMuted: Bool
    let onMicToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            WaveformView(level: micLevel, isMuted: isMuted, accent: HVTheme.accent, height: 32)
                .frame(height: 32)
                .opacity(isMuted ? 0.45 : 0.85)

            Button(action: onMicToggle) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isMuted ? HVTheme.surfaceAlt : HVTheme.accent.opacity(0.2)))
                    .overlay(Circle().stroke(HVTheme.stroke))
            }
            .tint(isMuted ? HVTheme.botText : HVTheme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surfaceAlt)
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        )
    }
}

private struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct ProgressRowView: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(HVTheme.surfaceAlt.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
        )
        .padding(.horizontal, 20)
    }
}

private struct ChatHintBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(HVTheme.botText.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(HVTheme.surfaceAlt.opacity(0.95))
                    .overlay(Capsule().stroke(HVTheme.stroke))
            )
    }
}

private struct ChatScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview { ChatView() }
