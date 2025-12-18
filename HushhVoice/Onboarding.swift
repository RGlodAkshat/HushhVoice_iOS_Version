//
//  Onboarding.swift
//  HushhVoice
//
//  FINAL FLOW (as per your latest requirements):
//   0) HushhVoice Intro screen (after sign-in) ✅
//   1) Voice picker screen (tap a voice -> plays 3–4s preview) ✅
//   2..5) 4 standard questions (same UI) ✅
//   6) Agent follow-ups using /onboarding/agent (EXACT SAME UI as questions) ✅
//        - loader while waiting ✅
//        - no “handoff” filler line ✅
//   7) Summary screen (Thanks + summary) ✅
//        - do NOT show “enough info to prefill…” ✅
//        - jump straight to summary when backend returns redirect ✅
//   8) Final choices ✅
//
//  NOTE:
//  - This file includes STTController + OnboardingTTSManager so “Cannot find STTController” won’t happen.
//

import SwiftUI
import Foundation
import Speech
import AVFoundation

// ======================================================
// MARK: - Onboarding
// ======================================================

struct Onboarding: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // Completion flag
    @AppStorage("hv_has_completed_investor_onboarding") private var done: Bool = false

    // Voice choice
    @AppStorage("hv_selected_voice") private var selectedVoice: String = "alloy"
    @AppStorage("hv_has_chosen_voice") private var hasChosenVoice: Bool = false

    // Resume state
    @AppStorage("hv_onboarding_page_v4") private var savedPage: Int = 0
    @AppStorage("hv_onboarding_a0") private var a0: String = ""
    @AppStorage("hv_onboarding_a1") private var a1: String = ""
    @AppStorage("hv_onboarding_a2") private var a2: String = ""
    @AppStorage("hv_onboarding_a3") private var a3: String = ""
    @AppStorage("hv_onboarding_summary") private var savedSummary: String = ""

    // Agent state (minimal)
    @AppStorage("hv_onboarding_agent_qcount") private var savedAgentQCount: Int = 1
    @AppStorage("hv_onboarding_agent_prompt") private var savedAgentPrompt: String = ""

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @ObservedObject private var google = GoogleSignInManager.shared

    // Pages:
    // 0=intro, 1=voice, 2..5=standard Qs, 6=agent Qs, 7=summary, 8=final
    @State private var page: Int = 0
    @State private var didInitialRestore: Bool = false

    // Standard answers (4)
    @State private var answers: [String] = ["", "", "", ""]

    // Agent follow-up prompt + answer (same UI as standard)
    @State private var agentPrompt: String = ""
    @State private var agentAnswer: String = ""
    @State private var agentQuestionsAsked: Int = 1
    @State private var didSeedAgent: Bool = false

    // Summary
    @State private var summaryText: String = ""

    // Permissions
    @State private var permissionDenied: Bool = false
    @State private var didRequestPermsOnce: Bool = false

    // Loading / errors
    @State private var isSaving: Bool = false
    @State private var isAgentLoading: Bool = false
    @State private var errorText: String?

    // Typing animation for prompt text
    @State private var typingText: String = ""
    @State private var typingTask: Task<Void, Never>?

    // Gate interaction until prompt heard once
    @State private var hasHeardPage: [Bool] = Array(repeating: false, count: 9)
    @State private var ttsCooldownUntil: Date = .distantPast

    // STT + TTS
    @StateObject private var stt = STTController(localeID: "en-US")
    @StateObject private var tts = OnboardingTTSManager()

    // Summary typing
    @State private var typingTextForSummary: String = ""
    @State private var summaryTypingTask: Task<Void, Never>?

    // MARK: Copy

    private let introLine =
    "Welcome! I’m Agent Kai by Hushh, your AI financial agent. I’ll guide you through investor onboarding with a few quick questions, so I can help you make smarter, more informed financial decisions. Let’s get started."

    private let voiceIntroLine =
    "Choose a voice to customize Agent Kai. Tap any voice to hear a quick preview."

    private let questions: [String] = [
        "What is your approximate net worth? This helps us understand your financial position for personalized insights. Feel free to answer in depth.",
        "What are your current investment goals or plans? Feel free to share anything you’re considering right now.",
        "What about your health can we help you with?",
        "What about your wealth can we help you with?"
    ]

    private let summaryIntro =
    "Thanks for the information — this helps us understand you better. Here’s a quick summary of what we understood about you."

    // MARK: Supabase (final write at end)

    private let SB_URL = "https://ibsisfnjxeowvdtvgzff.supabase.co"
    private let SB_TABLE = "investor_onboarding_via_hushhvoice"
    private let SB_ANON_KEY =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlic2lzZm5qeGVvd3ZkdHZnemZmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQ1NTk1NzgsImV4cCI6MjA4MDEzNTU3OH0.K16sO1R9L2WZGPueDP0mArs2eDYZc-TnIk2LApDw_fs"

    private var userID: String {
        if !appleUserID.isEmpty { return appleUserID }
        if let token = google.accessToken { return "google:\(token.prefix(16))" }
        return UUID().uuidString
    }

    // MARK: Prompt per page

    private var pagePrompt: String {
        switch page {
        case 0: return introLine
        case 1: return voiceIntroLine
        case 2...5: return questions[page - 2]
        case 6:
            // IMPORTANT: no filler line — either show current agent prompt or nothing while loading
            return agentPrompt
        case 7: return summaryIntro
        default: return "All set. Choose what you want to do next."
        }
    }

    private var isTTSBusy: Bool { tts.isPlaying || tts.isLoading }

    private var canInteract: Bool {
        hasHeardPage.indices.contains(page) ? hasHeardPage[page] : true
    }

    private var currentAnswerBinding: Binding<String> {
        Binding(
            get: {
                if (2...5).contains(page) { return answers[page - 2] }
                if page == 6 { return agentAnswer }
                return ""
            },
            set: { newValue in
                if (2...5).contains(page) { answers[page - 2] = newValue }
                if page == 6 { agentAnswer = newValue }
            }
        )
    }

    private var currentAnswerIsEmpty: Bool {
        if (2...5).contains(page) {
            return answers[page - 2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if page == 6 {
            return agentAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private var allStandardAnswersFilled: Bool {
        answers.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // ======================================================
    // MARK: UI
    // ======================================================

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
                    .id(page)

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }

                Spacer()

                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .padding(.top, 10)
        }
        .onAppear { restoreState() }
        .onChange(of: page) { _, newPage in
            if didInitialRestore {
                persistState()
                enterPage(newPage, speak: true)
            }
        }
        .onChange(of: answers) { _, _ in if didInitialRestore { persistState() } }
        .onChange(of: agentPrompt) { _, _ in if didInitialRestore { persistState() } }
        .onChange(of: summaryText) { _, _ in if didInitialRestore { persistState() } }
        .onChange(of: tts.isPlaying) { _, playing in if !playing { markHeardIfNeeded() } }
        .onChange(of: tts.isLoading) { _, loading in if !loading && !tts.isPlaying { markHeardIfNeeded() } }
        .onDisappear {
            stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }
            typingTask?.cancel()
            summaryTypingTask?.cancel()
            tts.stop()
        }
    }

    // ======================================================
    // MARK: Restore / Persist
    // ======================================================

    private func restoreState() {
        answers = [a0, a1, a2, a3]
        summaryText = savedSummary
        agentQuestionsAsked = max(1, savedAgentQCount)
        agentPrompt = savedAgentPrompt

        if done {
            page = 8
        } else {
            // Always show intro first after sign-in
            // then voice, then questions...
            page = 0
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
        savedSummary = summaryText
        savedAgentQCount_toggleSafe(agentQuestionsAsked)
        savedAgentPrompt = agentPrompt
    }

    private func savedAgentQCount_toggleSafe(_ v: Int) {
        savedAgentQCount = max(1, v)
    }

    // ======================================================
    // MARK: Header
    // ======================================================

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
                tts.stop()
                stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }
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
    }

    private var subtitleText: String {
        switch page {
        case 0: return "Investor onboarding"
        case 1: return "Choose voice"
        case 2...5: return "Question \(page - 1) of 4"
        case 6: return "Follow-ups"
        case 7: return "Summary"
        default: return "Completed"
        }
    }

    // ======================================================
    // MARK: Card
    // ======================================================

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack {
                Text(pageTitle)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.95))
                Spacer()

                if (2...5).contains(page) {
                    progressPills(current: page - 1, total: 4)
                } else if page == 6 {
                    Text("Step 6 of 8")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HVTheme.botText.opacity(0.7))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                } else if page == 7 {
                    Text("Step 7 of 8")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(HVTheme.botText.opacity(0.7))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                }
            }

            if page == 1 {
                voicePickerBlock
            } else if page == 7 {
                summaryScrollableBlock
            } else {
                // Prompt text
                Text(typingText.isEmpty ? pagePrompt : typingText)
                    .font(page == 0 ? .body : .title3.weight(.semibold))
                    .foregroundStyle(HVTheme.botText)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.98)

                // Loader for agent follow-ups (fixes "stuck on previous question")
                if page == 6 && isAgentLoading {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.95)
                        Text("One sec…")
                            .font(.footnote)
                            .foregroundStyle(HVTheme.botText.opacity(0.7))
                    }
                    .padding(.top, 4)
                }

                if page == 0 {
                    introControls
                } else if (2...6).contains(page) {
                    answerBox
                    controlsRow
                } else if page == 8 {
                    finalChoices
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(HVTheme.surface)
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(HVTheme.stroke, lineWidth: 1))
        .onAppear { appearTick() }
    }

    private func appearTick() {
        // kick typing animation on first render
    }

    private var pageTitle: String {
        switch page {
        case 0: return "Welcome"
        case 1: return "Pick your voice"
        case 2...5: return "Let’s personalize you"
        case 6: return "Let’s finish this"
        case 7: return "Summary"
        default: return "You’re set"
        }
    }

    private func progressPills(current: Int, total: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { idx in
                Capsule()
                    .fill(idx < current ? HVTheme.accent : HVTheme.stroke)
                    .frame(width: idx < current ? 18 : 8, height: 6)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
    }

    // ======================================================
    // MARK: Voice Picker (page 1)
    // ======================================================

    private var voicePickerBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tap a voice to hear how Kai will sound.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.65))

            VStack(spacing: 10) {
                voiceOption(
                    id: "alloy",
                    name: "Alloy",
                    vibe: "Balanced, crisp, professional",
                    preview: "Hey — I’m Alloy. I sound balanced, crisp, and professional. If you like clean and clear, I’m your voice."
                )
                voiceOption(
                    id: "verse",
                    name: "Verse",
                    vibe: "Warm, expressive, conversational",
                    preview: "Hey — I’m Verse. I sound warm and conversational. If you want something friendly and human, pick me."
                )
                voiceOption(
                    id: "nova",
                    name: "Nova",
                    vibe: "Bright, confident, energetic",
                    preview: "Hey — I’m Nova. I sound confident and energetic. If you like momentum and hype, I’m the one."
                )
                voiceOption(
                    id: "sage",
                    name: "Sage",
                    vibe: "Calm, slow, reassuring",
                    preview: "Hey — I’m Sage. I sound calm and reassuring. If you want something soothing and grounded, choose me."
                )
            }

            Text("You can change this later in Settings.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.6))
                .padding(.top, 4)
        }
    }

    private func voiceOption(id: String, name: String, vibe: String, preview: String) -> some View {
        Button {
            tts.stop()
            selectedVoice = id
            tts.speak(preview, voice: id) // play preview only on tap
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(HVTheme.botText)
                    Text(vibe)
                        .font(.footnote)
                        .foregroundStyle(HVTheme.botText.opacity(0.65))
                }
                Spacer()
                Image(systemName: selectedVoice == id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedVoice == id ? HVTheme.accent : HVTheme.botText.opacity(0.35))
                    .font(.system(size: 18, weight: .semibold))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(HVTheme.surfaceAlt))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(HVTheme.stroke))
        }
        .buttonStyle(.plain)
    }

    // ======================================================
    // MARK: Intro controls (page 0)
    // ======================================================

    private var introControls: some View {
        Button { toggleSpeakPrompt() } label: {
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
    }

    // ======================================================
    // MARK: Answer UI (pages 2..6 share)
    // ======================================================

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
                .disabled(page == 6 && isAgentLoading) // lock while waiting

            if stt.isRecording {
                Text(stt.transcript.isEmpty ? "Listening…" : "Heard: \(stt.transcript)")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.78))
                    .padding(.horizontal, 6)
            }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {

            Button { Task { await micTapped() } } label: {
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
            .disabled(page == 6 && isAgentLoading)
            .opacity((page == 6 && isAgentLoading) ? 0.6 : 1.0)

            Button { toggleSpeakPrompt() } label: {
                Image(systemName: isTTSBusy ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.headline)
                    .padding(12)
            }
            .background(Circle().fill(HVTheme.surfaceAlt))
            .overlay(Circle().stroke(HVTheme.stroke))
            .foregroundStyle(HVTheme.botText)
            .disabled(page == 6 && isAgentLoading)
            .opacity((page == 6 && isAgentLoading) ? 0.6 : 1.0)
        }
    }

    // ======================================================
    // MARK: Summary (page 7)
    // ======================================================

    private var summaryScrollableBlock: some View {
        VStack(alignment: .leading, spacing: 10) {

            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(typingText.isEmpty ? pagePrompt : typingText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(HVTheme.botText)
                        .lineSpacing(4)

                    if !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(typingTextForSummary.isEmpty ? summaryText : typingTextForSummary)
                            .font(.body)
                            .foregroundStyle(HVTheme.botText.opacity(0.95))
                            .lineSpacing(4)
                    } else if isSaving {
                        HStack(spacing: 10) {
                            ProgressView().scaleEffect(0.95)
                            Text("Creating your summary…")
                                .font(.footnote)
                                .foregroundStyle(HVTheme.botText.opacity(0.75))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            Button {
                if isTTSBusy { tts.stop() }
                else { tts.speak("\(summaryIntro)\n\n\(summaryText)", voice: selectedVoice) }
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
        }
    }

    // ======================================================
    // MARK: Final choices (page 8)
    // ======================================================

    private var finalChoices: some View {
        VStack(spacing: 12) {
            Text("Your investor profile is saved.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.9))

            Button {
                if let url = URL(string: "https://www.hushhtech.com/") { openURL(url) }
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

            Button { dismiss() } label: {
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
        }
    }

    // ======================================================
    // MARK: Bottom bar
    // ======================================================

    private var bottomBar: some View {
        HStack(spacing: 12) {

            if page > 0 && page != 8 {
                Button {
                    tts.stop()
                    stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }

                    if page == 6 { page = 5 }
                    else if page == 7 { page = 6 }
                    else { page -= 1 }
                } label: {
                    Text("Back")
                        .font(.headline)
                        .frame(width: 96)
                        .padding(.vertical, 12)
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.surfaceAlt))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
                .foregroundStyle(HVTheme.botText)
                .disabled(isAgentLoading || isSaving)
                .opacity((isAgentLoading || isSaving) ? 0.6 : 1.0)
            }

            if page != 8 {
                Button {
                    Task { await nextTapped() }
                } label: {
                    if isSaving || (page == 6 && isAgentLoading) {
                        ProgressView().tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else {
                        Text(nextButtonTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.accent))
                .foregroundStyle(.white)
                .disabled(nextDisabled)
                .opacity(nextDisabled ? 0.7 : 1.0)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.clear)
                    .frame(height: 46)
            }
        }
    }

    private var nextButtonTitle: String {
        switch page {
        case 0: return "Next"
        case 1: return "Continue"
        case 5: return "Continue"
        case 7: return "Continue"
        default: return "Next"
        }
    }

    private var nextDisabled: Bool {
        if isSaving { return true }
        if page == 6 && isAgentLoading { return true }
        if (2...6).contains(page) && currentAnswerIsEmpty { return true }
        return false
    }

    // ======================================================
    // MARK: Page enter + typing + seeding
    // ======================================================

    private func enterPage(_ newPage: Int, speak: Bool) {
        errorText = nil

        stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }
        tts.stop()

        startTyping(pagePrompt.isEmpty ? " " : pagePrompt)

        if speak && newPage != 1 {
            // Don’t auto-speak on voice picker page
            playTTS(text: pagePrompt, bypassCooldown: true)
        }

        if newPage == 6 && !didSeedAgent {
            didSeedAgent = true
            Task { await seedAgent() }
        }

        if newPage == 7 {
            if !summaryText.isEmpty { startSummaryTyping(summaryText) }
        } else {
            summaryTypingTask?.cancel()
            typingTextForSummary = ""
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

    private func startSummaryTyping(_ text: String) {
        summaryTypingTask?.cancel()
        typingTextForSummary = ""

        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        summaryTypingTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            var buffer = ""
            for ch in t {
                if Task.isCancelled { return }
                buffer.append(ch)
                await MainActor.run { typingTextForSummary = buffer }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    private func markHeardIfNeeded() {
        guard hasHeardPage.indices.contains(page) else { return }
        if !hasHeardPage[page] { hasHeardPage[page] = true }
    }

    private func toggleSpeakPrompt() {
        if isTTSBusy { tts.stop(); return }
        playTTS(text: pagePrompt, bypassCooldown: false)
    }

    private func playTTS(text: String, bypassCooldown: Bool) {
        let now = Date()
        if !bypassCooldown && now < ttsCooldownUntil { return }
        if !bypassCooldown { ttsCooldownUntil = now.addingTimeInterval(1.0) }

        stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }
        tts.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.tts.speak(text, voice: self.selectedVoice)
        }
    }

    // ======================================================
    // MARK: Mic / STT
    // ======================================================

    private func micTapped() async {
        errorText = nil

        if stt.isRecording {
            stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }
            return
        }

        await stopTTSAndWait()

        if !didRequestPermsOnce {
            await requestPermissions()
            didRequestPermsOnce = true
        }

        guard !permissionDenied else {
            errorText = "Microphone & Speech permissions are required."
            return
        }

        do { try await stt.start() }
        catch { errorText = "Could not start recording." }
    }

    private func requestPermissions() async {
        permissionDenied = false

        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else { permissionDenied = true; return }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus =
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        if speechStatus != .authorized { permissionDenied = true }
    }

    private func stopTTSAndWait() async {
        await MainActor.run { tts.stop() }

        for _ in 0..<30 {
            if !(tts.isPlaying || tts.isLoading) { break }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func appendTranscriptToAnswer(_ heard: String) {
        let finalText = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return }

        var current = currentAnswerBinding.wrappedValue
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current = finalText
        } else {
            let needsSpace = !(current.hasSuffix(" ") || current.hasSuffix("\n"))
            current = current + (needsSpace ? " " : "") + finalText
        }
        currentAnswerBinding.wrappedValue = current
    }

    // ======================================================
    // MARK: Flow: Next
    // ======================================================

    private func nextTapped() async {
        errorText = nil
        stt.stop(commit: true) { finalText in appendTranscriptToAnswer(finalText) }

        // Intro -> Voice
        if page == 0 {
            page = 1
            return
        }

        // Voice -> Q1 (lock voice choice)
        if page == 1 {
            hasChosenVoice = true
            page = 2
            return
        }

        // Standard Qs 2..4 -> next
        if (2...4).contains(page) {
            guard !currentAnswerIsEmpty else { return }
            page += 1
            return
        }

        // After Q4 (page 5) -> Agent follow-ups (page 6)
        if page == 5 {
            guard allStandardAnswersFilled else {
                errorText = "Please answer all questions before continuing."
                return
            }
            // Reset agent state fresh
            agentPrompt = ""
            agentAnswer = ""
            agentQuestionsAsked = 1
            didSeedAgent = false
            persistState()

            page = 6
            return
        }

        // Agent follow-ups (page 6)
        if page == 6 {
            let userText = agentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userText.isEmpty else { return }

            agentAnswer = ""            // clear input immediately
            isAgentLoading = true       // show loader immediately

            do {
                let result = try await callOnboardingAgent(userText: userText)
                agentQuestionsAsked += 1
                persistState()

                if result.nextAction == "redirect" {
                    // IMPORTANT: do NOT show any “enough info” message.
                    // Jump directly to summary and show your custom intro + summary.
                    isSaving = true
                    try await submitAllAnswersOnce()
                    let summary = try await fetchInvestorSummary()
                    summaryText = summary
                    persistState()
                    isSaving = false

                    isAgentLoading = false
                    page = 7
                    return
                }

                // Continue: update prompt to the next question
                agentPrompt = result.assistant
                startTyping(agentPrompt)
                tts.speak(agentPrompt, voice: selectedVoice)

                isAgentLoading = false
                return

            } catch {
                isAgentLoading = false
                errorText = "Agent error: \(error.localizedDescription)"
                return
            }
        }

        // Summary -> Final
        if page == 7 {
            done = true
            persistState()
            page = 8
            return
        }
    }

    // ======================================================
    // MARK: Agent Seed (no filler, direct next question)
    // ======================================================

    private func seedAgent() async {
        // show loader while we fetch the first follow-up question
        isAgentLoading = true
        defer { isAgentLoading = false }

        // Send the 4 standard answers as context
        let context = """
        My net worth: \(answers[0])
        My investment goals/plans: \(answers[1])
        Health help: \(answers[2])
        Wealth help: \(answers[3])
        """

        do {
            let result = try await callOnboardingAgent(userText: context)
            agentQuestionsAsked += 1
            persistState()

            // If backend says redirect immediately (rare), still go to summary
            if result.nextAction == "redirect" {
                isSaving = true
                try await submitAllAnswersOnce()
                let summary = try await fetchInvestorSummary()
                summaryText = summary
                persistState()
                isSaving = false
                page = 7
                return
            }

            agentPrompt = result.assistant
            startTyping(agentPrompt)
            tts.speak(agentPrompt, voice: selectedVoice)

        } catch {
            errorText = "Agent error: \(error.localizedDescription)"
        }
    }

    private func callOnboardingAgent(userText: String) async throws -> (assistant: String, nextAction: String) {
        guard let url = URL(string: "\(HushhAPI.base)/onboarding/agent") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "client_user_id": userID,
            "questions_asked": agentQuestionsAsked,
            "user_text": userText
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "OnboardingAgent", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataObj = json?["data"] as? [String: Any]
        let assistant = (dataObj?["assistant_text"] as? String) ?? "Got it — what should we fill next?"
        let nextAction = (dataObj?["next_action"] as? String) ?? "continue"
        return (assistant, nextAction)
    }

    // ======================================================
    // MARK: Submit standard answers to Supabase
    // ======================================================

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
            throw NSError(domain: "Onboarding", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }
    }

    // ======================================================
    // MARK: Summary generation (uses /siri/ask)
    // ======================================================

    private func fetchInvestorSummary() async throws -> String {
        let token = await google.ensureValidAccessToken()

        let mergedContext = """
        Net worth: \(answers[0])
        Investment goals/plans: \(answers[1])
        Health help: \(answers[2])
        Wealth help: \(answers[3])
        """

        let prompt = """
        You are Agent Kai (HushhVoice).
        Write a short, clear, positive summary of what you understood about the user from the information below.

        Rules:
        - Output 5–6 lines MAX (use short lines; line breaks allowed).
        - Sound natural and helpful like a voice assistant.
        - Do NOT mention missing info, uncertainty, or what they didn’t say.
        - Do NOT add facts that were not stated.
        - Keep it warm, confident, and simple.
        - No headings, no bullets, no numbering, no emojis.

        User info:
        \(mergedContext)
        """

        let data = try await HushhAPI.ask(prompt: prompt, googleToken: token)

        let text =
        (data.display?.removingPercentEncoding ?? data.display)
        ?? (data.speech?.removingPercentEncoding ?? data.speech)
        ?? ""

        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if lines.count > 6 {
            cleaned = lines.prefix(6).joined(separator: "\n")
        }

        if cleaned.isEmpty {
            cleaned = """
            Your net worth gives your current baseline.
            Your goals show what you want to achieve next.
            You shared the kind of health support you’re looking for.
            You shared the wealth support you want right now.
            I’ll personalize your next steps based on this.
            """
        }

        return cleaned
    }
}

// ======================================================
// MARK: - OnboardingTTSManager (voice param)
// ======================================================

@MainActor
final class OnboardingTTSManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {

    @Published var isLoading: Bool = false
    @Published var isPlaying: Bool = false

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()

    private var speakTask: Task<Void, Never>?
    private var activeToken: UUID = UUID()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, voice: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()

        let token = UUID()
        activeToken = token

        isLoading = true
        isPlaying = false

        speakTask = Task { [weak self] in
            guard let self else { return }

            self.configureAudioSessionForTTS()

            do {
                let audioData = try await HushhAPI.tts(text: trimmed, voice: voice)
                if Task.isCancelled { return }
                guard self.activeToken == token else { return }

                let p = try AVAudioPlayer(data: audioData)
                p.delegate = self
                p.prepareToPlay()

                self.player = p
                self.isLoading = false
                self.isPlaying = true
                p.play()
                return
            } catch {
                // fallback to system voice
            }

            if Task.isCancelled { return }
            guard self.activeToken == token else { return }

            self.isLoading = false
            self.isPlaying = true

            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
            self.synth.speak(utterance)
        }
    }

    func stop() {
        activeToken = UUID()
        speakTask?.cancel()
        speakTask = nil

        if let player, player.isPlaying { player.stop() }
        player = nil

        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }

        isLoading = false
        isPlaying = false

        deactivateAudioSession()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stop() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { stop() }

    private func configureAudioSessionForTTS() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch { }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// ======================================================
// MARK: - STTController (fix “Cannot find in scope”)
// ======================================================

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
        stop(commit: false) { _ in }

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
                    self.stop(commit: true) { _ in }
                }
            }
        }
    }

    func stop(commit: Bool, onFinal: (String) -> Void) {
        guard isRecording || audioEngine != nil || task != nil || request != nil else { return }

        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        if let engine = audioEngine, engine.isRunning { engine.stop() }
        audioEngine?.inputNode.removeTap(onBus: 0)

        request?.endAudio()
        task?.cancel()

        audioEngine = nil
        request = nil
        task = nil

        isRecording = false

        if commit, !final.isEmpty { onFinal(final) }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
