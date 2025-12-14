//
//  Onboarding.swift
//  HushhVoice
//

import SwiftUI
import Foundation
import Speech
import AVFoundation

struct Onboarding: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Completion flag: set true only after final submit success
    @AppStorage("hv_has_completed_investor_onboarding") private var done: Bool = false

    // Resume state
    @AppStorage("hv_onboarding_page") private var savedPage: Int = 0
    @AppStorage("hv_onboarding_a0") private var a0: String = ""
    @AppStorage("hv_onboarding_a1") private var a1: String = ""
    @AppStorage("hv_onboarding_a2") private var a2: String = ""
    @AppStorage("hv_onboarding_a3") private var a3: String = ""

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""

    @ObservedObject private var google = GoogleSignInManager.shared
    @ObservedObject private var speech = SpeechManager.shared

    // 0=intro, 1..4 questions, 5 final choices
    @State private var page: Int = 0
    @State private var didInitialRestore: Bool = false

    // Answers stored locally (editable)
    @State private var answers: [String] = ["", "", "", ""]

    // Permissions
    @State private var permissionDenied: Bool = false
    @State private var didRequestPermsOnce: Bool = false

    // Save / error
    @State private var isSaving: Bool = false
    @State private var errorText: String?

    // Typing animation
    @State private var typingText: String = ""
    @State private var typingTask: Task<Void, Never>?
    @State private var appearTick: Int = 0

    // Gate interaction until prompt was heard once
    @State private var hasHeardPage: [Bool] = [false, false, false, false, false, false] // 0..5
    @State private var ttsCooldownUntil: Date = .distantPast

    // STT controller (fresh engine each start)
    @StateObject private var stt = STTController(localeID: "en-US")

    // MARK: Copy

    private let introLine =
    "Welcome! I’m HushhVoice — your AI-powered, voice-first financial copilot. I’ll guide you through a few quick questions to set up your profile, so you can start making smarter, more informed financial decisions. Once you’re onboarded, I’ll also introduce you to some powerful features along the way."

    private let questions: [String] = [
        "What is your approximate net worth? This helps us understand your financial position for personalized insights.",
        "What are your current investment goals or plans? Feel free to share anything you’re considering right now.",
        "What about your health can we help you with?",
        "What about your wealth can we help you with?"
    ]

    // MARK: Supabase (single write at end)

    private let SB_URL = "https://ibsisfnjxeowvdtvgzff.supabase.co"
    private let SB_TABLE = "investor_onboarding_via_hushhvoice"
    private let SB_ANON_KEY =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlic2lzZm5qeGVvd3ZkdHZnemZmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQ1NTk1NzgsImV4cCI6MjA4MDEzNTU3OH0.K16sO1R9L2WZGPueDP0mArs2eDYZc-TnIk2LApDw_fs"

    private var userID: String {
        if !appleUserID.isEmpty { return appleUserID }
        if let token = google.accessToken { return "google:\(token.prefix(16))" }
        return UUID().uuidString
    }

    private var pagePrompt: String {
        if page == 0 { return introLine }
        if (1...4).contains(page) { return questions[page - 1] }
        return "All set. Choose what you want to do next."
    }

    private var canInteract: Bool {
        hasHeardPage.indices.contains(page) ? hasHeardPage[page] : true
    }

    private var currentAnswerBinding: Binding<String> {
        Binding(
            get: { (1...4).contains(page) ? answers[page - 1] : "" },
            set: { newValue in
                guard (1...4).contains(page) else { return }
                answers[page - 1] = newValue
            }
        )
    }

    private var currentAnswerIsEmpty: Bool {
        guard (1...4).contains(page) else { return false }
        return answers[page - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var allAnswersFilled: Bool {
        answers.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isTTSBusy: Bool { speech.isPlaying || speech.isLoading }

    // MARK: UI

    var body: some View {
        ZStack {
            HVTheme.bg.ignoresSafeArea()

            RadialGradient(
                colors: [HVTheme.accent.opacity(0.22), Color.clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 460
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                header

                Spacer(minLength: 6)

                card
                    .padding(.horizontal, 16)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(page)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }

                Spacer()

                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.top, 10)
        }
        .onAppear {
            restoreState()
        }
        .onChange(of: page) { _, newPage in
            if didInitialRestore {
                persistState()
                enterPage(newPage, speak: true)
            }
        }
        .onChange(of: answers) { _, _ in
            if didInitialRestore { persistState() }
        }
        .onChange(of: speech.isPlaying) { _, playing in
            if !playing { markHeardIfNeeded() }
        }
        .onChange(of: speech.isLoading) { _, loading in
            if !loading && !speech.isPlaying { markHeardIfNeeded() }
        }
        .onDisappear {
            stt.stop(commit: true) { finalText in
                appendTranscriptToCurrentAnswer(finalText)
            }
            typingTask?.cancel()
            speech.stop()
        }
    }

    // MARK: - Restore / Persist

    private func restoreState() {
        answers = [a0, a1, a2, a3]

        if done {
            page = 5
        } else {
            let p = min(max(savedPage, 0), 4)
            page = p
        }

        didInitialRestore = true
        enterPage(page, speak: true)
    }

    private func persistState() {
        savedPage = page
        a0 = answers[0]
        a1 = answers[1]
        a2 = answers[2]
        a3 = answers[3]
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("HushhVoice")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(HVTheme.botText)
                    .opacity(0.95)

                Text(subtitleText)
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
            }

            Spacer()

            Button {
                speech.stop()
                stt.stop(commit: true) { finalText in
                    appendTranscriptToCurrentAnswer(finalText)
                }
                persistState()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(10)
                    .background(Circle().fill(HVTheme.surfaceAlt))
                    .overlay(Circle().stroke(HVTheme.stroke))
            }
            .foregroundStyle(HVTheme.botText)
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: page)
    }

    private var subtitleText: String {
        if page == 0 { return "Investor onboarding" }
        if (1...4).contains(page) { return "Question \(page) of 4" }
        return "Completed"
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack(alignment: .center) {
                Text(pageTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.95))

                Spacer()

                if (1...4).contains(page) {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { idx in
                            Capsule()
                                .fill(idx < page ? HVTheme.accent : HVTheme.stroke)
                                .frame(width: idx < page ? 18 : 8, height: 6)
                                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: page)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                }
            }

            Text(typingText.isEmpty ? pagePrompt : typingText)
                .font(page == 0 ? .body : .title3.weight(.semibold))
                .foregroundStyle(HVTheme.botText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0.98)
                .animation(.easeOut(duration: 0.2), value: typingText)

            if page == 0 {
                introControls
            } else if (1...4).contains(page) {
                answerBox
                controlsRow
            } else {
                finalChoices
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(HVTheme.surface)
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(HVTheme.stroke, lineWidth: 1))
        .scaleEffect(0.985)
        .animation(.spring(response: 0.55, dampingFraction: 0.88), value: appearTick)
    }

    private var pageTitle: String {
        if page == 0 { return "Welcome" }
        if (1...4).contains(page) { return "Let’s personalize you" }
        return "You’re set"
    }

    // MARK: - Intro controls

    private var introControls: some View {
        HStack(spacing: 10) {
            Button {
                toggleSpeakPrompt()
            } label: {
                Label(isTTSBusy ? "Stop" : "Play", systemImage: isTTSBusy ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.surfaceAlt))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
            .foregroundStyle(HVTheme.botText)
            .disabled(!isTTSBusy && Date() < ttsCooldownUntil)

            if !canInteract {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.9)
                    Text("Listening…")
                        .font(.footnote)
                        .foregroundStyle(HVTheme.botText.opacity(0.6))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.surfaceAlt))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: canInteract)
    }

    // MARK: - Answer box

    private var answerBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your answer")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.6))

            TextField("Type and/or speak…", text: currentAnswerBinding, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .foregroundStyle(HVTheme.botText)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.surfaceAlt))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))

            if stt.isRecording {
                Text(stt.transcript.isEmpty ? "Listening…" : "Heard: \(stt.transcript)")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.78))
                    .padding(.horizontal, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: stt.transcript)
        .animation(.easeOut(duration: 0.2), value: stt.isRecording)
    }

    // MARK: - Controls row

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await micTapped() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: stt.isRecording ? "stop.fill" : "mic.fill")
                    Text(stt.isRecording ? "Stop" : "Mic")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .foregroundStyle(.black)
            .opacity((canInteract || stt.isRecording) ? 1.0 : 0.85) // still tappable; mic will unlock

            Button {
                toggleSpeakPrompt()
            } label: {
                Image(systemName: isTTSBusy ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.headline)
                    .padding(12)
            }
            .background(Circle().fill(HVTheme.surfaceAlt))
            .overlay(Circle().stroke(HVTheme.stroke))
            .foregroundStyle(HVTheme.botText)
            .disabled(!isTTSBusy && Date() < ttsCooldownUntil)
            .opacity((!isTTSBusy && Date() < ttsCooldownUntil) ? 0.55 : 1.0)
        }
        .animation(.easeOut(duration: 0.25), value: canInteract)
        .animation(.easeOut(duration: 0.2), value: isTTSBusy)
    }

    // MARK: - Final choices

    private var finalChoices: some View {
        VStack(spacing: 12) {
            Text("Your investor profile is saved.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.9))

            Button {
                if let url = URL(string: "https://www.hushhtech.com/") {
                    openURL(url)
                }
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text("Go to HushhTech")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.surfaceAlt))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
            .foregroundStyle(HVTheme.botText)

            Button {
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "message.fill")
                    Text("Continue HushhVoice")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.accent))
            .foregroundStyle(.white)

            Text("You can re-run onboarding anytime from the top-right button in chat.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 12) {

            if page > 0 && page != 5 {
                Button {
                    stt.stop(commit: true) { finalText in
                        appendTranscriptToCurrentAnswer(finalText)
                    }
                    page -= 1
                } label: {
                    Text("Back")
                        .font(.headline)
                        .frame(width: 96)
                        .padding(.vertical, 12)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.surfaceAlt))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
                .foregroundStyle(HVTheme.botText)
            }

            if page != 5 {
                Button {
                    Task { await nextTapped() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text((page == 4) ? "Finish" : "Next")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.accent))
                .foregroundStyle(.white)
                .disabled(isSaving || ((1...4).contains(page) && currentAnswerIsEmpty) || (!canInteract && page != 0))
                .opacity((!canInteract && page != 0) ? 0.75 : 1.0)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.clear)
                    .frame(height: 46)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: canInteract)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: page)
    }

    // MARK: - Core flow

    private func enterPage(_ newPage: Int, speak: Bool) {
        errorText = nil
        appearTick += 1

        // stop STT (commit) and stop TTS
        stt.stop(commit: true) { finalText in
            appendTranscriptToCurrentAnswer(finalText)
        }
        speech.stop()

        startTyping(pagePrompt)

        if speak {
            // auto-speak should not be blocked by cooldown
            playTTS(text: pagePrompt, bypassCooldown: true)
        }

        // Always unlock within a short window to prevent "dead" UI
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if self.page == newPage, !self.canInteract {
                self.hasHeardPage[newPage] = true
            }
        }
    }

    private func startTyping(_ text: String) {
        typingTask?.cancel()
        typingText = ""

        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        typingTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            var buffer = ""
            for ch in t {
                if Task.isCancelled { return }
                buffer.append(ch)
                await MainActor.run { typingText = buffer }
                try? await Task.sleep(nanoseconds: 9_000_000)
            }
        }
    }

    private func markHeardIfNeeded() {
        guard hasHeardPage.indices.contains(page) else { return }
        if !hasHeardPage[page] {
            hasHeardPage[page] = true
        }
    }

    private func toggleSpeakPrompt() {
        // If currently speaking/loading: stop immediately (true toggle)
        if isTTSBusy {
            speech.stop()
            markHeardIfNeeded()
            return
        }
        playTTS(text: pagePrompt, bypassCooldown: false)
    }

    private func playTTS(text: String, bypassCooldown: Bool) {
        let now = Date()
        if !bypassCooldown && now < ttsCooldownUntil { return }
        if !bypassCooldown {
            ttsCooldownUntil = now.addingTimeInterval(1.0)
        }

        // stop STT first
        stt.stop(commit: true) { finalText in
            appendTranscriptToCurrentAnswer(finalText)
        }

        // stop any existing TTS then speak
        speech.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.speech.speak(text, messageID: nil)
        }
    }

    // MARK: - Mic / STT

    private func micTapped() async {
        errorText = nil

        // If UI is gated, tapping mic means "interrupt and go"
        if !canInteract, hasHeardPage.indices.contains(page) {
            hasHeardPage[page] = true
        }

        if stt.isRecording {
            stt.stop(commit: true) { finalText in
                appendTranscriptToCurrentAnswer(finalText)
            }
            return
        }

        // Make absolutely sure TTS is stopped and audio session is clean
        await stopTTSAndWait()

        if !didRequestPermsOnce {
            await requestPermissions()
            didRequestPermsOnce = true
        }

        guard !permissionDenied else {
            errorText = "Microphone & Speech permissions are required."
            return
        }

        do {
            try await stt.start()
        } catch {
            print("❌ STT start error: \(error)")
            errorText = "Could not start recording."
        }
    }

    private func requestPermissions() async {
        permissionDenied = false

        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }

        guard micGranted else {
            permissionDenied = true
            return
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus =
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }

        if speechStatus != .authorized {
            permissionDenied = true
        }
    }

    private func stopTTSAndWait() async {
        // Stop TTS immediately
        await MainActor.run { speech.stop() }

        // Wait briefly for SpeechManager to settle (isLoading/isPlaying -> false)
        for _ in 0..<25 {
            if !(speech.isPlaying || speech.isLoading) { break }
            try? await Task.sleep(nanoseconds: 40_000_000) // 40ms
        }

        // Safety: ensure session is not left active by TTS path
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func appendTranscriptToCurrentAnswer(_ heard: String) {
        let finalText = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...4).contains(page), !finalText.isEmpty else { return }

        var current = currentAnswerBinding.wrappedValue
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current = finalText
        } else {
            let needsSpace = !(current.hasSuffix(" ") || current.hasSuffix("\n"))
            current = current + (needsSpace ? " " : "") + finalText
        }
        currentAnswerBinding.wrappedValue = current
    }

    // MARK: - Next / Submit

    private func nextTapped() async {
        errorText = nil

        // Stop STT and commit transcript
        stt.stop(commit: true) { finalText in
            appendTranscriptToCurrentAnswer(finalText)
        }

        if page == 0 {
            page = 1
            return
        }

        if (1...3).contains(page) {
            guard canInteract else { return }
            guard !currentAnswerIsEmpty else { return }
            page += 1
            return
        }

        if page == 4 {
            guard canInteract else { return }
            guard allAnswersFilled else {
                errorText = "Please answer all questions before finishing."
                return
            }

            isSaving = true
            do {
                try await submitAllAnswersOnce()
                done = true
                page = 5
                persistState()
            } catch let e as NSError {
                let msg = (e.userInfo[NSLocalizedDescriptionKey] as? String) ?? e.localizedDescription
                errorText = "Could not save. (\(e.code)) \(msg)"
            } catch {
                errorText = "Could not save. Please try again."
            }
            isSaving = false
        }
    }

    private func submitAllAnswersOnce() async throws {
        guard let url = URL(string: "\(SB_URL)/rest/v1/\(SB_TABLE)") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SB_ANON_KEY, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(SB_ANON_KEY)", forHTTPHeaderField: "Authorization")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let payload: [String: Any] = [
            "user_id": userID,
            "net_worth": answers[0],
            "next_step": answers[1],
            "health_help": answers[2],
            "wealth_help": answers[3]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "(non-utf8 body)"
            print("❌ Supabase FINAL write failed")
            print("❌ status: \(http.statusCode)")
            print("❌ body: \(body)")
            throw NSError(domain: "Onboarding", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
    }
}

// MARK: - STTController (fresh AVAudioEngine per start; eliminates “works once” failures)

@MainActor
final class STTController: ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init(localeID: String) {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }

    func start() async throws {
        stop(commit: false, onFinal: { _ in })

        // Configure session for recognition
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: [])

        transcript = ""
        isRecording = true

        let engine = AVAudioEngine()
        audioEngine = engine

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }

            if let result {
                Task { @MainActor in
                    self.transcript = result.bestTranscription.formattedString
                }
            }

            if error != nil {
                Task { @MainActor in
                    // Stop safely on error; don’t commit garbage mid-error
                    self.stop(commit: true, onFinal: { _ in })
                }
            }
        }
    }

    func stop(commit: Bool, onFinal: (String) -> Void) {
        guard isRecording || audioEngine != nil || task != nil || request != nil else { return }

        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
        }
        audioEngine?.inputNode.removeTap(onBus: 0)

        request?.endAudio()
        task?.cancel()

        audioEngine = nil
        request = nil
        task = nil

        isRecording = false

        if commit, !final.isEmpty {
            onFinal(final)
        }

        // Deactivate if not needed
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

