import SwiftUI
import UIKit

struct ChatView: View {
    @StateObject private var store = ChatStore()
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

                ScrollViewReader { proxy in
                    ZStack {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(store.activeMessages) { msg in
                                    let isLast = isLastAssistant(msg)
                                    let hideControls = (msg.role == .assistant && msg.id == animatingAssistantID)

                                    MessageRow(
                                        message: msg,
                                        isLastAssistant: isLast,
                                        hideControls: hideControls,
                                        isSpeaking: speech.currentMessageID == msg.id && speech.isPlaying,
                                        isLoadingTTS: speech.currentMessageID == msg.id && speech.isLoading,
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

                                if showTyping { TypingIndicatorView().id("typing") }
                            }
                            .padding(.vertical, 12)
                        }

                        if store.activeMessages.isEmpty {
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
                        }
                    }
                    .onChange(of: store.activeMessages.last?.id) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .bottom) }

                            if let last = store.activeMessages.last, last.role == .assistant {
                                animatingAssistantID = id
                                let textLength = last.text.count
                                let totalTime = Double(textLength) * 0.01 + 0.25
                                Task {
                                    try? await Task.sleep(nanoseconds: UInt64(totalTime * 1_000_000_000))
                                    await MainActor.run {
                                        if animatingAssistantID == id { animatingAssistantID = nil }
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: showTyping) { _, typing in
                        if typing {
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("typing", anchor: .bottom) }
                        }
                    }
                }

                Divider().background(HVTheme.stroke)

                HStack {
                    ComposerView(
                        text: $input,
                        isSending: sending,
                        disabled: sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onSend: { Task { await send() } }
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .background(HVTheme.bg.ignoresSafeArea())

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
        .alert("Connect Google to Continue", isPresented: $showGoogleGate) {
            Button("Go to Settings") { showingSettings = true }
            Button("Sign in with Google") { auth.signIn() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To answer Gmail or Calendar questions, connect Google in Settings.")
        }
        .onAppear {
            randomizeEmptyPhrase()
            if !hasSeenIntro && hvDone {
                hasSeenIntro = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showingIntro = true }
            }
        }
        .onChange(of: store.activeChatID) { _ in randomizeEmptyPhrase() }
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
        showTyping = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        await store.send(q, googleToken: token)

        showTyping = false
        sending = false
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

#Preview { ChatView() }
