import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Foundation
import SafariServices

struct ChatView: View {
    // Local fallback definition: some support files may not be in the build target membership.
    // Keeping this nested type unblocks compilation without requiring pbxproj edits.
    struct IdentifiedURL: Identifiable, Hashable {
        let id: UUID
        let url: URL

        init(url: URL) {
            self.id = UUID()
            self.url = url
        }
    }

    // MARK: - Local UI support types (compile-time)
    // If `ChatViewSupportViews.swift` is not added to the app target membership, these nested types
    // ensure ChatView continues to compile.

    struct SafariView: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> SFSafariViewController {
            SFSafariViewController(url: url)
        }

        func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    }

    struct ChatScrollOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    struct ChatContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    struct ProgressRowView: View {
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

    struct ChatHintBanner: View {
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

    struct GoogleConnectBanner: View {
        let onConnect: () -> Void
        let onSignIn: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(HVTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect Google to enable Gmail + Calendar.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HVTheme.botText)
                    Text("Tools are disabled until you sign in.")
                        .font(.caption)
                        .foregroundStyle(HVTheme.botText.opacity(0.7))
                }
                Spacer(minLength: 0)
                Button("Connect") { onConnect() }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HVTheme.accent.opacity(0.18)))
                Button("Sign in") { onSignIn() }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HVTheme.surfaceAlt))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(HVTheme.surfaceAlt.opacity(0.95))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
            )
        }
    }

    struct VoiceCaptureBar: View {
        let micLevel: CGFloat
        let isMuted: Bool
        let onMicToggle: () -> Void

        var body: some View {
            HStack(spacing: 12) {
                WaveformView(level: micLevel, isMuted: isMuted, accent: HVTheme.accent)
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

    @StateObject private var store = ChatStore()
    @ObservedObject var auth = GoogleSignInManager.shared
    @StateObject private var realtime = ChatRealtimeSession()
    @StateObject private var audioCapture = AudioCaptureManager.shared
    @StateObject private var speech = SpeechManager.shared
    @StateObject private var micMonitor = MicLevelMonitor()

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

    @State private var isReviewingHistory = false
    @State private var isFollowingLive = true
    @State private var isAtBottom = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var contentOffset: CGFloat = 0
    @State private var assistantTextVisible = false
    @State private var assistantStatusText: String?
    @State private var cancelledTurnID: String?
    @State private var safariLink: IdentifiedURL?
    @State private var scrollWorkItem: DispatchWorkItem?
    @State private var useFallback = false
    @State private var allowLocalTranscription = true
    @State private var usedLocalTranscriptInTurn = false
    @State private var receivedRealtimeTranscriptInTurn = false
    @State private var enableLocalTranscription = false
    @State private var useLocalSTTOnly = false
    @State private var didCommitUserForCurrentSpeech = false
    @State private var pendingLocalCommitForTurnStart = false
    @State private var shouldReplaceBufferedUserTranscript = false
    @State private var pendingSpeechTranscript: String = ""
    @State private var pendingSpeechCommitWorkItem: DispatchWorkItem?

    private let speechCommitDelay: TimeInterval = 0.2
    private let useFallbackMode = false
    private let realtimeOnlyMode = true

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

    private var isMicMuted: Bool {
        if useFallback || useLocalSTTOnly {
            return audioCapture.isMuted
        }
        return realtime.isMuted
    }

    private var isListeningActive: Bool {
        !isMicMuted && (store.turnState == .listening || store.turnState == .finalizingInput)
    }

    private var localCaptureCallbacksEnabled: Bool {
        (useFallbackMode && useFallback) || useLocalSTTOnly || enableLocalTranscription
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
            dbg("ChatView", "appear", fields: ["user_id": effectiveUserId()])
            configureAudioCaptureCallbacks()
            configureRealtimeCallbacks()
            useFallback = useFallbackMode
            if realtimeOnlyMode {
                useFallback = false
                useLocalSTTOnly = false
                enableLocalTranscription = false
            }
            let effectiveUserID = !kaiUserID.isEmpty ? kaiUserID : (!appleUserID.isEmpty ? appleUserID : UUID().uuidString)
            realtime.useLocalSTTOnly = useLocalSTTOnly
            realtime.start(userId: effectiveUserID)
            Task {
                let token = await auth.ensureValidAccessToken()
                realtime.updateGoogleToken(token)
            }
            if useLocalSTTOnly {
                realtime.setMuted(true)
            }
            audioCapture.setMuted(true)
        }
        .onDisappear {
            pendingSpeechCommitWorkItem?.cancel()
            pendingSpeechCommitWorkItem = nil
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

                if !isGuest && !auth.hasConnectedGoogle {
                    GoogleConnectBanner(
                        onConnect: { showingSettings = true },
                        onSignIn: { auth.signIn() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
                                                isSpeaking: false,
                                                isLoadingTTS: false,
                                                isSubdued: msg.role == .assistant && store.isAssistantStreaming,
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
                        isMuted: isMicMuted,
                        onMicToggle: { toggleMic() }
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    ComposerView(
                        text: $input,
                        isSending: sending,
                        isSendDisabled: sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        isMicMuted: isMicMuted,
                        attachments: store.pendingAttachments,
                        onSend: { Task { await send() } },
                        onAttach: { showAttachmentPicker = true },
                        onMicToggle: { toggleMic() },
                        onRemoveAttachment: { store.removePendingAttachment($0) }
                    )
                    .frame(maxWidth: .infinity)
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
        .onChange(of: realtime.lastError) { _, newValue in
            if let newValue {
                store.showHint(newValue)
                DebugLogger.shared.lastOpenAIError = newValue
                dbg("ChatView", "realtime_error", message: newValue)
            }
        }
        .onChange(of: realtime.state) { _, newValue in
            dbg("ChatView", "realtime_state", fields: ["state": newValue.rawValue])
            if newValue == .error {
                useFallback = false
                let msg = "Realtime connection is unhealthy. Reconnecting..."
                print("🔁 [Chat] \(msg)")
                store.showHint(msg)
                realtime.setMuted(true)
                audioCapture.setAutoRestartAfterFinal(false)
                audioCapture.setMuted(true)
            } else if newValue == .connected {
                useFallback = false
                if realtimeOnlyMode {
                    useLocalSTTOnly = false
                    enableLocalTranscription = false
                    realtime.useLocalSTTOnly = false
                }
                if !useLocalSTTOnly {
                    if enableLocalTranscription && !realtime.isMuted {
                        audioCapture.setAutoRestartAfterFinal(true)
                        audioCapture.setMuted(false)
                    } else {
                        audioCapture.setAutoRestartAfterFinal(false)
                        audioCapture.setMuted(true)
                    }
                }
            }
        }
        .onChange(of: realtime.isMuted) { _, muted in
            guard !useFallback, !useLocalSTTOnly else { return }
            if !muted {
                self.isFollowingLive = true
                self.isReviewingHistory = false
            }
            if enableLocalTranscription {
                audioCapture.setAutoRestartAfterFinal(!muted)
                audioCapture.setMuted(muted)
            }
            micMonitor.setMuted(muted)
            dbg("ChatView", "realtime_mute", fields: ["muted": muted])
        }
        .onChange(of: audioCapture.isMuted) { _, muted in
            guard useFallback || useLocalSTTOnly else { return }
            if !muted {
                self.isFollowingLive = true
                self.isReviewingHistory = false
            }
            micMonitor.setMuted(muted)
            dbg("ChatView", useFallback ? "local_stt_mute" : "local_stt_only_mute", fields: ["muted": muted])
        }
        .onChange(of: speech.isPlaying) { _, playing in
            guard useFallbackMode && useFallback else { return }
            if !playing && !audioCapture.isMuted {
                audioCapture.resumeCaptureAfterPlayback()
                store.setTurnState(.listening)
            }
        }
        .onAppear {
            micMonitor.setMuted(isMicMuted)
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
        .onChange(of: store.activeMessages.count) { _, newValue in
            dbg("ChatView", "messages_count", fields: ["count": newValue])
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

        dbg("ChatView", "send", fields: ["len": q.count, "fallback": useFallback])
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
        if useFallbackMode && useFallback {
            let reply = await store.send(q, googleToken: token)
            if let reply {
                let messageID = store.activeMessages.last?.id
                audioCapture.pauseCaptureForPlayback()
                speech.speak(reply, messageID: messageID)
            }
        } else {
            store.appendUserMessage(q)
            store.setTurnState(.thinking)
            realtime.updateGoogleToken(token)
            realtime.sendUserText(q)
        }
        sending = false
    }

    private func toggleMic() {
        if useFallbackMode && useFallback {
            if audioCapture.isMuted {
                print("🎙️ [Chat] mic unmuted (fallback)")
                dbg("ChatView", "mic_unmuted", fields: ["fallback": true])
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReviewingHistory = false
                }
                isFollowingLive = true
                store.setTurnState(.listening)
                store.beginVoiceDraft()
                pendingSpeechTranscript = ""
                pendingSpeechCommitWorkItem?.cancel()
                pendingSpeechCommitWorkItem = nil
                audioCapture.setAutoRestartAfterFinal(false)
                audioCapture.setMuted(false)
            } else {
                print("🎙️ [Chat] mic muted (fallback)")
                dbg("ChatView", "mic_muted", fields: ["fallback": true])
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                audioCapture.setAutoRestartAfterFinal(false)
                audioCapture.setMuted(true)
                store.cancelVoiceDraft()
                store.setTurnState(.idle)
                assistantStatusText = nil
            }
            return
        }

        if useLocalSTTOnly {
            if audioCapture.isMuted {
                print("🎙️ [Chat] mic unmuted (local)")
                dbg("ChatView", "mic_unmuted", fields: ["fallback": false])
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.2)) {
                    isReviewingHistory = false
                }
                isFollowingLive = true
                store.setTurnState(.listening)
                store.beginVoiceDraft()
                pendingSpeechTranscript = ""
                pendingSpeechCommitWorkItem?.cancel()
                pendingSpeechCommitWorkItem = nil
                allowLocalTranscription = true
                usedLocalTranscriptInTurn = false
                receivedRealtimeTranscriptInTurn = false
                audioCapture.setAutoRestartAfterFinal(true)
                audioCapture.setMuted(false)
                realtime.setMuted(true)
            } else {
                print("🎙️ [Chat] mic muted (local)")
                dbg("ChatView", "mic_muted", fields: ["fallback": false])
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                audioCapture.setAutoRestartAfterFinal(false)
                audioCapture.setMuted(true)
                store.cancelVoiceDraft()
                store.setTurnState(.idle)
                realtime.setMuted(true)
                assistantStatusText = nil
            }
            return
        }

        if realtime.isMuted {
            print("🎙️ [Chat] mic unmuted")
            dbg("ChatView", "mic_unmuted", fields: ["fallback": false])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) {
                isReviewingHistory = false
            }
            isFollowingLive = true
            store.setTurnState(.listening)
            store.beginVoiceDraft()
            pendingSpeechTranscript = ""
            pendingSpeechCommitWorkItem?.cancel()
            pendingSpeechCommitWorkItem = nil
            allowLocalTranscription = enableLocalTranscription
            usedLocalTranscriptInTurn = false
            receivedRealtimeTranscriptInTurn = false
            realtime.setMuted(false)
            if enableLocalTranscription {
                audioCapture.setAutoRestartAfterFinal(true)
                audioCapture.setMuted(false)
            } else {
                audioCapture.setAutoRestartAfterFinal(false)
                audioCapture.setMuted(true)
            }
        } else {
            print("🎙️ [Chat] mic muted")
            dbg("ChatView", "mic_muted", fields: ["fallback": false])
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            realtime.setMuted(true)
            if enableLocalTranscription {
                audioCapture.setAutoRestartAfterFinal(false)
                audioCapture.setMuted(true)
            }
            store.cancelVoiceDraft()
            store.setTurnState(.idle)
            assistantStatusText = nil
        }
    }

    @MainActor
    private func handleFallbackFinalTranscript(_ text: String) async {
        guard useFallbackMode && useFallback else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        print("🎙️ [Fallback] final transcript len=\(trimmed.count)")
        assistantStatusText = "Thinking..."
        _ = store.finalizeVoiceDraft(appendToChat: true)
        store.setTurnState(.thinking)
        let token = await auth.ensureValidAccessToken()
        let reply = await store.sendVoiceTranscript(trimmed, googleToken: token)
        if let reply {
            let messageID = store.activeMessages.last?.id
            audioCapture.pauseCaptureForPlayback()
            speech.speak(reply, messageID: messageID)
        } else {
            print("🎙️ [Fallback] no reply from backend")
        }
        store.setTurnState(.idle)
        assistantStatusText = nil
    }

    private func configureRealtimeCallbacks() {
        realtime.onEvent = { event in
            DispatchQueue.main.async {
                dbg("ChatView", "stream_event", fields: ["type": event.event_type])
                handleStreamEvent(event)
            }
        }
    }

    private func configureAudioCaptureCallbacks() {
        audioCapture.onSpeechStart = { [store] in
            DispatchQueue.main.async {
                guard localCaptureCallbacksEnabled, !audioCapture.isMuted else { return }
                dbg("AudioCapture", "speech_start")
                pendingSpeechCommitWorkItem?.cancel()
                pendingSpeechCommitWorkItem = nil
                if useFallbackMode && useFallback {
                    speech.stop()
                } else {
                    realtime.interruptForBargeIn()
                }
                store.setTurnState(.listening)
                didCommitUserForCurrentSpeech = false
                pendingLocalCommitForTurnStart = false
                shouldReplaceBufferedUserTranscript = false
                assistantStatusText = "Hearing your message..."
            }
        }
        audioCapture.onPartialTranscript = { text in
            DispatchQueue.main.async {
                guard localCaptureCallbacksEnabled, !audioCapture.isMuted else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                guard allowLocalTranscription,
                      !didCommitUserForCurrentSpeech
                else { return }
                if !useLocalSTTOnly && receivedRealtimeTranscriptInTurn {
                    return
                }
                dbg("AudioCapture", "partial", fields: ["len": text.count])
                if useFallbackMode && useFallback {
                    speech.stop()
                } else {
                    realtime.interruptForBargeIn()
                }
                assistantStatusText = "Hearing your message..."
            }
        }
        audioCapture.onFinalTranscript = { text in
            Task {
                let shouldHandle = await MainActor.run {
                    localCaptureCallbacksEnabled
                        && !audioCapture.isMuted
                        &&
                    allowLocalTranscription && (!receivedRealtimeTranscriptInTurn || useLocalSTTOnly) && !didCommitUserForCurrentSpeech
                }
                guard shouldHandle else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                await MainActor.run {
                    dbg("AudioCapture", "final", fields: ["len": text.count])
                    pendingSpeechTranscript = mergeSpeechTranscriptSegments(existing: pendingSpeechTranscript, incoming: trimmed)
                    store.setTurnState(.finalizingInput)
                    assistantStatusText = "Hearing your message..."
                    schedulePendingSpeechCommit()
                }
            }
        }
        audioCapture.onSpeechEnd = { [store] in
            DispatchQueue.main.async {
                guard localCaptureCallbacksEnabled, !audioCapture.isMuted else { return }
                dbg("AudioCapture", "speech_end")
                guard allowLocalTranscription, !didCommitUserForCurrentSpeech else {
                    return
                }
                store.setTurnState(.finalizingInput)
                assistantStatusText = "Hearing your message..."
                schedulePendingSpeechCommit()
            }
        }
    }

    private func schedulePendingSpeechCommit() {
        pendingSpeechCommitWorkItem?.cancel()
        let work = DispatchWorkItem {
            Task { await commitPendingSpeechTranscript() }
        }
        pendingSpeechCommitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + speechCommitDelay, execute: work)
    }

    @MainActor
    private func commitPendingSpeechTranscript() async {
        pendingSpeechCommitWorkItem = nil
        guard allowLocalTranscription, !didCommitUserForCurrentSpeech else { return }

        let transcript = pendingSpeechTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSpeechTranscript = ""

        guard isUsableTranscript(transcript) else {
            store.cancelVoiceDraft()
            store.setTurnState(isMicMuted ? .idle : .listening)
            assistantStatusText = nil
            dbg("ChatView", "speech_commit_skipped_empty")
            return
        }

        usedLocalTranscriptInTurn = true
        didCommitUserForCurrentSpeech = true
        pendingLocalCommitForTurnStart = (store.currentTurnID == nil)
        shouldReplaceBufferedUserTranscript = false
        assistantStatusText = "Thinking..."

        if useFallbackMode && useFallback {
            store.beginVoiceDraft()
            store.updateVoiceDraft(transcript)
            await handleFallbackFinalTranscript(transcript)
            return
        }

        store.beginVoiceDraft()
        store.updateVoiceDraft(transcript)
        store.setTurnState(.thinking)
        dbg("ChatView", "local_commit", fields: ["len": transcript.count])
        let token = await auth.ensureValidAccessToken()
        realtime.updateGoogleToken(token)
        realtime.sendUserText(transcript)
        _ = store.finalizeVoiceDraft(appendToChat: true)
    }

    private func mergeSpeechTranscriptSegments(existing: String, incoming: String) -> String {
        let current = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return current }
        guard !current.isEmpty else { return next }

        let currentLower = current.lowercased()
        let nextLower = next.lowercased()
        if currentLower == nextLower || currentLower.contains(nextLower) {
            return current
        }
        if nextLower.contains(currentLower) {
            return next
        }
        return current + " " + next
    }

    private func handleStreamEvent(_ event: StreamEventEnvelope) {
        let requiresTurn: Set<String> = [
            "assistant_audio.start",
            "assistant_audio.end",
            "assistant_text.delta",
            "assistant_text.final",
            "turn.start",
            "turn.end",
            "turn.cancelled",
            "state.change",
            "tool_call.progress",
            "confirmation.request",
        ]
        // Some upstream events (notably input transcription) may arrive without `turn_id`.
        // We still want to apply them to the current UI turn when possible.
        let allowedWithoutTurn: Set<String> = [
            "input_transcript.delta",
            "input_transcript.final",
            "hint",
            "assistant_text.delta",
            "assistant_text.final",
            "assistant_audio.start",
            "assistant_audio.end",
            "state.change",
        ]
        if event.turn_id == nil && requiresTurn.contains(event.event_type) {
            print("🛰️ [Chat] ignoring \(event.event_type) without turn_id")
            return
        }
        if let incomingTurn = event.turn_id,
           let cancelled = cancelledTurnID,
           incomingTurn == cancelled,
           event.event_type != "turn.start" {
            return
        }
        if event.event_type != "turn.start" {
            if let incomingTurn = event.turn_id {
                if let currentTurn = store.currentTurnID {
                    guard incomingTurn == currentTurn else { return }
                }
            } else {
                // No turn_id: allow only known-safe session-level UI events (especially user transcript).
                guard allowedWithoutTurn.contains(event.event_type) else {
                    dbg("ChatView", "event_dropped_no_turn", fields: ["type": event.event_type])
                    return
                }
            }
        }
        dbg("ChatView", "event_dispatch", fields: [
            "type": event.event_type,
            "turn": event.turn_id ?? "-",
        ])
        switch event.event_type {
        case "assistant_audio.start":
            commitDraftIfNeededBeforeAssistant()
            assistantTextVisible = true
            assistantStatusText = nil
        case "assistant_audio.end":
            break
        case "input_transcript.delta", "input_transcript.final":
            if useLocalSTTOnly {
                return
            }
            let text = event.payload.string("text") ?? ""
            if !text.isEmpty {
                receivedRealtimeTranscriptInTurn = true
                pendingSpeechTranscript = mergeSpeechTranscriptSegments(existing: pendingSpeechTranscript, incoming: text)
                assistantStatusText = "Hearing your message..."
            }
            if usedLocalTranscriptInTurn {
                dbg("ChatView", "realtime_transcript_ignored", fields: ["reason": "local_used"])
                return
            }
            if event.event_type == "input_transcript.delta" {
                return
            }
            if !text.isEmpty {
                if shouldReplaceBufferedUserTranscript {
                    store.replaceMostRecentUserTranscript(text)
                    shouldReplaceBufferedUserTranscript = false
                } else {
                    store.applyStreamEvent(event)
                }
                didCommitUserForCurrentSpeech = true
                pendingSpeechTranscript = ""
                assistantStatusText = assistantTextVisible ? nil : "Thinking..."
            }
        case "assistant_text.delta":
            commitDraftIfNeededBeforeAssistant()
            store.applyStreamEvent(event)
            assistantTextVisible = true
            assistantStatusText = nil
        case "assistant_text.final":
            commitDraftIfNeededBeforeAssistant()
            store.applyStreamEvent(event)
            assistantStatusText = nil
            assistantTextVisible = false
        case "state.change":
            store.applyStreamEvent(event)
            let toState = event.payload.string("to") ?? ""
            if toState == "listening" {
                assistantStatusText = "Hearing your message..."
            } else if toState == "thinking" || toState == "executing_tools" || toState == "awaiting_confirmation" {
                assistantStatusText = "Thinking..."
            } else if toState == "speaking" || toState == "idle" || toState == "cancelled" {
                assistantStatusText = nil
            }
        case "tool_call.progress":
            store.applyStreamEvent(event)
        case "turn.start":
            assistantStatusText = "Thinking..."
            assistantTextVisible = false
            cancelledTurnID = nil
            allowLocalTranscription = true
            receivedRealtimeTranscriptInTurn = false
            if pendingLocalCommitForTurnStart {
                usedLocalTranscriptInTurn = true
                didCommitUserForCurrentSpeech = true
            } else {
                usedLocalTranscriptInTurn = false
                didCommitUserForCurrentSpeech = false
            }
            pendingLocalCommitForTurnStart = false
            store.applyStreamEvent(event)
        case "turn.end":
            assistantStatusText = nil
            assistantTextVisible = false
            pendingSpeechTranscript = ""
            shouldReplaceBufferedUserTranscript = false
            store.applyStreamEvent(event)
        case "turn.cancelled":
            assistantStatusText = nil
            assistantTextVisible = false
            cancelledTurnID = event.turn_id
            pendingSpeechTranscript = ""
            shouldReplaceBufferedUserTranscript = false
            store.finalizeAssistantStream(status: .interrupted)
            store.applyStreamEvent(event)
        default:
            store.applyStreamEvent(event)
        }
    }

    private func commitDraftIfNeededBeforeAssistant() {
        guard !didCommitUserForCurrentSpeech else { return }

        if store.isDraftUserActive {
            let trimmed = store.draftUserText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                _ = store.finalizeVoiceDraft(appendToChat: true)
                didCommitUserForCurrentSpeech = true
                shouldReplaceBufferedUserTranscript = false
                dbg("ChatView", "force_user_commit", fields: ["len": trimmed.count])
                return
            }
        }

        let buffered = pendingSpeechTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !buffered.isEmpty {
            store.beginVoiceDraft()
            store.updateVoiceDraft(buffered)
            _ = store.finalizeVoiceDraft(appendToChat: true)
            didCommitUserForCurrentSpeech = true
            shouldReplaceBufferedUserTranscript = true
            pendingSpeechTranscript = ""
            dbg("ChatView", "force_user_commit_from_buffer", fields: ["len": buffered.count])
        } else {
            // If realtime input transcription is missing/late, we still want a visible user bubble.
            // We'll replace this placeholder when `input_transcript.final` arrives.
            store.beginVoiceDraft()
            store.updateVoiceDraft("Voice message")
            _ = store.finalizeVoiceDraft(appendToChat: true)
            didCommitUserForCurrentSpeech = true
            shouldReplaceBufferedUserTranscript = true
            dbg("ChatView", "force_user_commit_placeholder")
        }
    }

    private func isUsableTranscript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let allowed = trimmed.filter { $0.isLetter || $0.isNumber || $0 == " " }
        let ratio = Double(allowed.count) / Double(max(trimmed.count, 1))
        return ratio >= 0.4
    }


    private func effectiveUserId() -> String {
        if !kaiUserID.isEmpty { return kaiUserID }
        if !appleUserID.isEmpty { return appleUserID }
        return "unknown"
    }

    private func dbg(_ component: String, _ event: String, message: String? = nil, fields: [String: Any] = [:]) {
        DebugLogger.shared.log(
            component: component,
            event: event,
            message: message,
            fields: fields,
            sessionId: realtime.sessionId,
            turnId: store.currentTurnID,
            messageId: store.activeMessages.last?.id.uuidString
        )
    }


    private func handleConfirmationDecision(_ confirmation: ChatConfirmation, decision: String) {
        realtime.confirmToolCall(confirmationID: confirmation.id, decision: decision, editedText: nil)
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
        realtime.confirmToolCall(confirmationID: confirmation.id, decision: "accept", editedText: editedConfirmationText)
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
            if !isMicMuted {
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
        store.showHint("Replay is not available in realtime voice mode yet.")
    }

    private func handleSignOut() {
        // Sign out of all services and clear local state.
        AppleSupabaseAuth.shared.signOut()
        appleUserID = ""
        auth.signOut()
        isGuest = true
        realtime.stop()
        store.clearMessagesInActiveChat()
    }

    private func requiresGoogleIntegration(for text: String) -> Bool {
        // Simple keyword check to decide if Google token is required.
        let lower = text.lowercased()
        let keywords = ["gmail", "email", "inbox", "calendar", "event", "meeting", "schedule"]
        return keywords.contains { lower.contains($0) }
    }
}

#Preview { ChatView() }
