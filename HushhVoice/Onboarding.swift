//
//  Onboarding.swift
//  HushhVoice
//  fds
//
//  Minimal “Orb + Mute” Kai Voice Mode (Realtime WebRTC)
//
//  ✅ metasidd/Orb animated orb
//  ✅ hushh_quiet_logo mute button (small + low)
//  ✅ Waveform under orb (mic level)
//  ✅ Real speech-to-speech via OpenAI Realtime over WebRTC
//  ✅ Echo cancellation via AVAudioSession voiceChat
//
//  Dependencies:
//  - LiveKit WebRTC XCFramework: https://github.com/livekit/webrtc-xcframework (module: LiveKitWebRTC)
//  - Orb package: https://github.com/metasidd/Orb.git (module: Orb)
//
//  Backend endpoints expected:
//  - GET {backendBase}/onboarding/agent/config
//  - POST {backendBase}/onboarding/agent/token
//
//  Backend JSON envelope expected (your jok()):
//  { "ok": true, "data": { "instructions": "...", "tools": [...], "realtime": { "turn_detection": {...} }, "kickoff": { "response": {...} } } }
//
//  Notes:
//  - This file avoids Decodable generics; uses JSONSerialization.
//  - Remote audio plays automatically via WebRTC.
//  - Data channel is used for session.update + debugging states.
//  - Mic mute disables local track + mic meter.
//

import SwiftUI
import Foundation
import UIKit
import AVFoundation
import LiveKitWebRTC
import Orb

struct ProfileData: Equatable {
    var fullName: String = ""
    var phone: String = ""
    var email: String = ""

    var isComplete: Bool {
        !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && email.contains("@")
    }
}

struct KaiNoteEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var ts: Date
    var questionId: String
    var text: String

    init(id: UUID = UUID(), ts: Date = Date(), questionId: String, text: String) {
        self.id = id
        self.ts = ts
        self.questionId = questionId
        self.text = text
    }
}

struct KaiLocalState: Codable, Equatable {
    var createdAt: Date
    var discovery: [String: String]
    var notes: [KaiNoteEntry]
    var completedQuestions: Int
    var totalQuestions: Int
    var isComplete: Bool
    var lastQuestionId: String?
}

enum OnboardingStage {
    case loading
    case profile
    case intro1
    case intro2
    case meetKai
    case voice
    case summary
    case actions
}

private final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private let lock = NSLock()
    private var configured = false
    private let debugEnabled = true

    private func routeSummary(_ session: AVAudioSession) -> String {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    private func permissionSummary(_ session: AVAudioSession) -> String {
        switch session.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    func configureIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if configured { return true }

        let session = AVAudioSession.sharedInstance()
        do {
            if debugEnabled {
                print("[AudioSession] pre-config permission=\(permissionSummary(session)) route=\(routeSummary(session))")
            }
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.02)
            try? session.setPreferredInputNumberOfChannels(1)
            try? session.setPreferredOutputNumberOfChannels(1)
            try session.setActive(true, options: [])
            configured = true
            print("[AudioSession] ready sampleRate=\(session.sampleRate) inCh=\(session.inputNumberOfChannels) outCh=\(session.outputNumberOfChannels) route=\(routeSummary(session))")
            return true
        } catch {
            print("AudioSession configure error:", error)
            return false
        }
    }
}

// ======================================================
// MARK: - Mic Level Monitor (for waveform)
// ======================================================

final class MicLevelMonitor: ObservableObject {
    @Published var level: CGFloat

    private static let idleLevel: CGFloat = 0.06
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var smoothedLevel: CGFloat
    private var isMuted = false
    private let bufferSize: AVAudioFrameCount = 1024

    init() {
        self.level = Self.idleLevel
        self.smoothedLevel = Self.idleLevel
    }

    func start() {
        if isRunning && engine.isRunning { return }
        isRunning = true

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.start() }
                }
            }
            return
        case .denied:
            isRunning = false
            DispatchQueue.main.async { self.level = Self.idleLevel }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        guard AudioSessionCoordinator.shared.configureIfNeeded() else {
            print("MicLevelMonitor audio session error: configure failed")
            isRunning = false
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            print("MicLevelMonitor: input format invalid; mic not available")
            isRunning = false
            return
        }
        print("MicLevelMonitor: start format rate=\(format.sampleRate) channels=\(format.channelCount)")

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if self.isMuted {
                DispatchQueue.main.async {
                    self.level = Self.idleLevel
                }
                return
            }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var sum: Float = 0
            for i in 0..<frames { sum += channelData[i] * channelData[i] }
            let rms = sqrt(sum / Float(frames))
            let normalized = max(0, min((rms - 0.003) / 0.05, 1))
            let boosted = pow(normalized, 0.5)

            let target = Self.idleLevel + (1 - Self.idleLevel) * CGFloat(boosted)

            // Smooth
            let smoothing: CGFloat = 0.18
            smoothedLevel = smoothedLevel + (target - smoothedLevel) * smoothing

            DispatchQueue.main.async {
                self.level = self.smoothedLevel
            }
        }

        do {
            engine.prepare()
            try engine.start()
            print("MicLevelMonitor: engine started")
        } catch {
            print("MicLevelMonitor start error:", error)
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("MicLevelMonitor: engine stopped")
        DispatchQueue.main.async {
            self.level = Self.idleLevel
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            DispatchQueue.main.async {
                self.level = Self.idleLevel
            }
        } else {
            start()
        }
    }
}

// ======================================================
// MARK: - UI State
// ======================================================

enum OrbState {
    case connecting
    case listening
    case speaking
    case muted
    case error
}

// ======================================================
// MARK: - Onboarding Screen
// ======================================================

struct Onboarding: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @AppStorage("hushh_kai_user_id") private var kaiUserID: String = ""
    @AppStorage("hv_profile_completed") private var profileDone: Bool = false
    @AppStorage("hv_hushhtech_intro_completed") private var introDone: Bool = false
    @AppStorage("hv_has_completed_investor_onboarding") private var hvDone: Bool = false

    @StateObject private var vm = KaiVoiceViewModel()
    @StateObject private var micMonitor = MicLevelMonitor()
    @State private var stage: OnboardingStage = .loading
    @State private var resolvedUserID: String = ""
    @State private var profile = ProfileData()
    @State private var profileError: String? = nil
    @State private var isSavingProfile = false
    @State private var preserveVoiceState = false

    private func resolveUserID() -> String {
        if !appleUserID.isEmpty { return appleUserID }
        if !kaiUserID.isEmpty { return kaiUserID }
        let newID = UUID().uuidString
        kaiUserID = newID
        return newID
    }

    private var backendBase: URL { HushhAPI.base }

    var body: some View {
        ZStack {
            OnboardingBackground()

            Group {
                switch stage {
                case .loading:
                    OnboardingLoadingView()
                        .transition(.opacity)
                case .profile:
                    ProfileCaptureView(
                        profile: $profile,
                        isSaving: isSavingProfile,
                        errorText: profileError,
                        onContinue: { Task { await saveProfileAndAdvance() } }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .intro1:
                    HushhTechIntroOneView(
                        onContinue: {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                stage = .intro2
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .intro2:
                    HushhTechIntroTwoView(
                        onContinue: {
                            introDone = true
                            withAnimation(.easeInOut(duration: 0.35)) {
                                stage = .meetKai
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .meetKai:
                    MeetKaiView(
                        onStart: {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                stage = .voice
                            }
                        },
                        onNotNow: handleMeetKaiNotNow
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .voice:
                    VoiceOnboardingView(
                        vm: vm,
                        micMonitor: micMonitor,
                        preserveStateOnStart: preserveVoiceState,
                        onClose: handleClose,
                        onFinish: handleFinishVoice
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                case .summary:
                    SummaryView(
                        profile: $profile,
                        discovery: vm.discovery,
                        isSavingProfile: isSavingProfile,
                        onUpdateProfile: { updated in
                            Task { await updateProfile(updated) }
                        },
                        onUpdateDiscovery: { patch in
                            Task { await vm.updateDiscovery(patch: patch) }
                        },
                        onConfirm: handleSummaryConfirm,
                        onOpenHushhTech: openHushhTechWebsite
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .actions:
                    PostSummaryActionsView(
                        onExplore: handleExplore,
                        onGoToHushhTech: handleGoToHushhTech
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            bootstrap()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            micMonitor.stop()
            vm.stop()
        }
        .onChange(of: stage) { newStage in
            if newStage == .summary {
                vm.markSyncPending()
                vm.scheduleSupabaseSyncIfNeeded()
            }
            if newStage != .voice {
                micMonitor.stop()
                if vm.isRunningSession {
                    vm.markRepeatOnNextConnect()
                }
                vm.stop()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: stage)
    }

    private func bootstrap() {
        let id = resolveUserID()
        if resolvedUserID == id { return }
        resolvedUserID = id
        vm.setUserId(id)
        stage = .loading
        Task { await loadProfile(userId: id) }
    }

    private func handleClose() {
        vm.stop()
        dismiss()
    }

    private func handleSummaryConfirm() {
        hvDone = true
        withAnimation(.easeInOut(duration: 0.35)) {
            stage = .actions
        }
    }

    private func handleFinishVoice() {
        vm.stop()
        withAnimation(.easeInOut(duration: 0.35)) {
            stage = .summary
        }
    }

    private func handleExplore() {
        hvDone = true
        dismiss()
    }

    private func handleMeetKaiNotNow() {
        if hvDone {
            withAnimation(.easeInOut(duration: 0.35)) {
                stage = .summary
            }
        } else {
            dismiss()
        }
    }

    private func handleGoToHushhTech() {
        let onboardingComplete = vm.isComplete && vm.missingKeys.isEmpty
        if onboardingComplete {
            if stage != .summary {
                withAnimation(.easeInOut(duration: 0.35)) {
                    stage = .summary
                }
                return
            }
            openHushhTechWebsite()
            return
        }

        if !profile.isComplete {
            withAnimation(.easeInOut(duration: 0.35)) {
                stage = .profile
            }
            return
        }

        if !introDone {
            withAnimation(.easeInOut(duration: 0.35)) {
                preserveVoiceState = true
                stage = .intro1
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.35)) {
            preserveVoiceState = true
            stage = .voice
        }
    }

    private func openHushhTechWebsite() {
        if let url = URL(string: "https://www.hushhtech.com/") {
            openURL(url)
        }
    }

    private func loadProfile(userId: String) async {
        profileError = nil
        var loadedProfile: ProfileData?
        var profileFetchError: Error?
        var didLoadConfig = false

        do {
            loadedProfile = try await fetchProfile(userId: userId)
        } catch {
            profileFetchError = error
        }

        do {
            try await vm.fetchConfig()
            didLoadConfig = true
        } catch {
            didLoadConfig = false
        }

        await MainActor.run {
            if let loadedProfile {
                profile = loadedProfile
            }
            if let profileFetchError {
                profileError = profileFetchError.localizedDescription
            }
        }

        let profileComplete = await MainActor.run { profile.isComplete }
        let onboardingComplete = await MainActor.run {
            didLoadConfig ? (vm.isComplete && vm.missingKeys.isEmpty) : vm.isComplete
        }

        await MainActor.run {
            if profileComplete {
                profileDone = true
                if onboardingComplete {
                    hvDone = true
                    dismiss()
                } else {
                    hvDone = false
                    if introDone {
                        preserveVoiceState = true
                        stage = .voice
                    } else {
                        preserveVoiceState = true
                        stage = .intro1
                    }
                }
            } else {
                hvDone = false
                preserveVoiceState = false
                stage = .profile
            }
        }
    }

    private func saveProfileAndAdvance() async {
        guard !resolvedUserID.isEmpty else { return }
        isSavingProfile = true
        profileError = nil
        do {
            let saved = try await upsertProfile(userId: resolvedUserID, profile: profile)
            await MainActor.run {
                profile = saved
                profileDone = true
                stage = introDone ? .meetKai : .intro1
            }
        } catch {
            await MainActor.run {
                profileError = error.localizedDescription
            }
        }
        isSavingProfile = false
    }

    private func updateProfile(_ updated: ProfileData) async {
        guard !resolvedUserID.isEmpty else { return }
        isSavingProfile = true
        profileError = nil
        do {
            let saved = try await upsertProfile(userId: resolvedUserID, profile: updated)
            await MainActor.run {
                profile = saved
                if profile.isComplete {
                    profileDone = true
                }
            }
        } catch {
            await MainActor.run {
                profileError = error.localizedDescription
            }
        }
        isSavingProfile = false
    }

    private func fetchProfile(userId: String) async throws -> ProfileData? {
        var url = backendBase.appendingPathComponent("/profile")
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
            if let updated = components.url { url = updated }
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Profile", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Profile fetch error"
            ])
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any]
        else {
            throw NSError(domain: "Profile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad profile JSON"])
        }
        let exists = (dataObj["exists"] as? Bool) ?? false
        if !exists { return nil }
        if let profileObj = dataObj["profile"] as? [String: Any] {
            return ProfileData(
                fullName: (profileObj["full_name"] as? String) ?? "",
                phone: (profileObj["phone"] as? String) ?? "",
                email: (profileObj["email"] as? String) ?? ""
            )
        }
        return nil
    }

    private func upsertProfile(userId: String, profile: ProfileData) async throws -> ProfileData {
        let url = backendBase.appendingPathComponent("/profile")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId,
            "full_name": profile.fullName,
            "phone": profile.phone,
            "email": profile.email
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Profile", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Profile save error"
            ])
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any],
            let profileObj = dataObj["profile"] as? [String: Any]
        else {
            throw NSError(domain: "Profile", code: 4, userInfo: [NSLocalizedDescriptionKey: "Bad profile JSON"])
        }
        return ProfileData(
            fullName: (profileObj["full_name"] as? String) ?? profile.fullName,
            phone: (profileObj["phone"] as? String) ?? profile.phone,
            email: (profileObj["email"] as? String) ?? profile.email
        )
    }
}

// ======================================================
// MARK: - Onboarding Shell Views
// ======================================================

private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            HVTheme.bg.ignoresSafeArea()
            AuroraBackground()
                .ignoresSafeArea()
            LinearGradient(
                colors: [HVTheme.accent.opacity(0.18), Color.black.opacity(0.2), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [HVTheme.accent.opacity(0.20), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }
}

private struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Circle()
                .fill(HVTheme.accent.opacity(0.16))
                .frame(width: 380, height: 380)
                .blur(radius: 60)
                .offset(x: drift ? -140 : 120, y: drift ? -220 : -80)
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: drift ? 130 : -160, y: drift ? 180 : 220)
            Circle()
                .fill(HVTheme.accent.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: drift ? 40 : -60, y: drift ? 240 : 140)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

private struct OnboardingContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

private struct ProgressDots: View {
    var total: Int
    var current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { idx in
                Circle()
                    .fill(idx == current ? HVTheme.accent : HVTheme.surfaceAlt)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(HVTheme.stroke.opacity(0.6)))
            }
        }
    }
}

private struct OnboardingChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(HVTheme.surfaceAlt.opacity(0.75)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08)))
            .foregroundStyle(HVTheme.botText.opacity(0.75))
    }
}

private struct ShimmerModifier: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if active {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.02),
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .rotationEffect(.degrees(20))
                        .offset(x: phase * 240)
                        .blendMode(.screen)
                        .onAppear {
                            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                                phase = 0.8
                            }
                        }
                    }
                }
            )
            .clipped()
    }
}

private struct KeyboardDismissModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

private extension View {
    func shimmer(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}

private struct OnboardingLoadingView: View {
    var body: some View {
        OnboardingContainer {
            VStack(spacing: 16) {
                ProgressView()
                    .tint(HVTheme.accent)
                Text("Preparing Kai")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(HVTheme.botText)
                Text("Getting your session ready.")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(HVTheme.surface.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(HVTheme.stroke))
            )
        }
    }
}

private struct ProfileCaptureView: View {
    @Binding var profile: ProfileData
    var isSaving: Bool
    var errorText: String?
    var onContinue: () -> Void

    private enum Field {
        case name
        case phone
        case email
    }

    @FocusState private var focusedField: Field?
    @State private var lastFocused: Field?
    @State private var didEditName = false
    @State private var didEditPhone = false
    @State private var didEditEmail = false
    @State private var animateIn = false

    private var nameValid: Bool { !profile.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var phoneValid: Bool { profile.phone.range(of: "\\d", options: .regularExpression) != nil }
    private var emailValid: Bool { profile.email.contains("@") }
    private var formValid: Bool { nameValid && phoneValid && emailValid }

    var body: some View {
        ScrollView {
            OnboardingContainer {
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        HStack {
                            OnboardingChip(text: "Step 1 of 4")
                            Spacer()
                            OnboardingChip(text: "Welcome to HushhTech")
                        }

                        ProgressDots(total: 4, current: 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 6)
                    .animation(.easeOut(duration: 0.35).delay(0.05), value: animateIn)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick profile")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(HVTheme.botText)
                        Text("So Kai can address you properly.")
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(HVTheme.botText.opacity(0.7))
                        Text("Only basics. Nothing sensitive.")
                            .font(.footnote)
                            .foregroundStyle(HVTheme.botText.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
                    .animation(.easeOut(duration: 0.4).delay(0.12), value: animateIn)

                    VStack(spacing: 16) {
                        ProfileField(
                            title: "Full name",
                            icon: "person.fill",
                            text: $profile.fullName,
                            showValid: didEditName && nameValid,
                            showInvalid: didEditName && !nameValid,
                            keyboard: .default,
                            autocapitalize: true,
                            isFocused: focusedField == .name
                        )
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .phone }

                        ProfileField(
                            title: "Phone",
                            icon: "phone.fill",
                            text: $profile.phone,
                            showValid: didEditPhone && phoneValid,
                            showInvalid: didEditPhone && !phoneValid,
                            keyboard: .phonePad,
                            autocapitalize: false,
                            isFocused: focusedField == .phone
                        )
                        .focused($focusedField, equals: .phone)

                        ProfileField(
                            title: "Email",
                            icon: "envelope.fill",
                            text: $profile.email,
                            showValid: didEditEmail && emailValid,
                            showInvalid: didEditEmail && !emailValid,
                            keyboard: .emailAddress,
                            autocapitalize: false,
                            isFocused: focusedField == .email
                        )
                        .focused($focusedField, equals: .email)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.surface.opacity(0.7),
                                        HVTheme.surfaceAlt.opacity(0.6)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
                    )
                    .opacity(animateIn ? 1 : 0)
                    .scaleEffect(animateIn ? 1.0 : 0.98)
                    .animation(.easeOut(duration: 0.45).delay(0.2), value: animateIn)

                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        onContinue()
                    } label: {
                        HStack {
                            Text(isSaving ? "Saving..." : "Continue")
                                .font(.headline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            HVTheme.accent.opacity(formValid ? 0.95 : 0.3),
                                            HVTheme.accent.opacity(formValid ? 0.75 : 0.2)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: formValid ? HVTheme.accent.opacity(0.35) : .clear, radius: 12, x: 0, y: 6)
                        )
                    }
                    .foregroundColor(formValid ? .black : HVTheme.botText.opacity(0.5))
                    .disabled(!formValid || isSaving)
                    .buttonStyle(PressableButtonStyle())
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
                    .animation(.easeOut(duration: 0.35).delay(0.28), value: animateIn)

                    Text("Kai is your private financial agent.")
                        .font(.footnote)
                        .foregroundStyle(HVTheme.botText.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(animateIn ? 1 : 0)
                        .animation(.easeOut(duration: 0.3).delay(0.32), value: animateIn)
                }
                .padding(.vertical, 24)
            }
        }
        .scrollIndicators(.hidden)
        .modifier(KeyboardDismissModifier())
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                if focusedField == .phone {
                    Button("Next") { focusedField = .email }
                } else if focusedField == .email {
                    Button("Done") { focusedField = nil }
                }
            }
        }
        .onChange(of: focusedField) { newValue in
            if lastFocused == .name && newValue != .name { didEditName = true }
            if lastFocused == .phone && newValue != .phone { didEditPhone = true }
            if lastFocused == .email && newValue != .email { didEditEmail = true }
            lastFocused = newValue
        }
        .onAppear { animateIn = true }
    }
}

private struct ProfileField: View {
    var title: String
    var icon: String
    @Binding var text: String
    var showValid: Bool
    var showInvalid: Bool
    var keyboard: UIKeyboardType
    var autocapitalize: Bool = true
    var isFocused: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(HVTheme.surface.opacity(0.7)))
                .overlay(Circle().stroke(Color.white.opacity(0.08)))

            TextField(title, text: $text, prompt: Text(title).foregroundColor(HVTheme.botText.opacity(0.4)))
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .words : .never)
                .autocorrectionDisabled(true)
                .foregroundStyle(HVTheme.botText)

            if showValid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HVTheme.accent)
                    .transition(.scale.combined(with: .opacity))
            } else if showInvalid {
                Circle()
                    .stroke(HVTheme.accent.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surfaceAlt.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(isFocused ? HVTheme.accent.opacity(0.4) : Color.white.opacity(0.06))
        )
        .shadow(color: isFocused ? HVTheme.accent.opacity(0.18) : .clear, radius: 8, x: 0, y: 4)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: showValid)
    }
}

private struct VoiceOnboardingView: View {
    @ObservedObject var vm: KaiVoiceViewModel
    @ObservedObject var micMonitor: MicLevelMonitor
    var preserveStateOnStart: Bool
    var onClose: () -> Void
    var onFinish: () -> Void
    @State private var showFinishPrompt = false

    var body: some View {
        VStack(spacing: 16) {
            OnboardingContainer {
                VStack(spacing: 16) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kai")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(HVTheme.botText.opacity(0.95))

                            Text(vm.subtitle)
                                .font(.footnote)
                                .foregroundStyle(HVTheme.botText.opacity(0.6))
                        }

                        Spacer()

                        ProgressChip(
                            completed: vm.completedQuestions,
                            total: vm.totalQuestions
                        )

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(HVTheme.surfaceAlt))
                                .overlay(Circle().stroke(HVTheme.stroke))
                        }
                        .foregroundStyle(HVTheme.botText)
                    }

                }
                .padding(.top, 12)
            }

            Spacer()

            KaiOrb(configuration: vm.orbConfiguration, size: 270)
                .padding(.bottom, 6)

            WaveformView(level: micMonitor.level, isMuted: vm.isMuted, accent: HVTheme.accent)
                .padding(.horizontal, 24)
                .opacity(vm.state == .connecting ? 0.55 : 0.7)

            if !showFinishPrompt {
                KaiNotesCard(notes: vm.notes)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if showFinishPrompt {
                FinishKaiCard(onFinish: onFinish)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            QuietMicButtonSmall(isMuted: $vm.isMuted) {
                vm.setMuted(vm.isMuted)
            }
            .disabled(vm.state == .connecting)

            if let err = vm.errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Text(vm.footerText)
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.55))
                .padding(.bottom, 14)
        }
        .onAppear {
            micMonitor.start()
            micMonitor.setMuted(vm.isMuted)
            if !vm.isRunningSession, !vm.userIdValue.isEmpty {
                vm.start(userId: vm.userIdValue, preserveState: preserveStateOnStart)
            } else {
                vm.repeatLastPromptIfNeeded()
            }
        }
        .onDisappear {
            micMonitor.stop()
        }
        .onChange(of: vm.isMuted) { muted in
            micMonitor.setMuted(muted)
        }
        .onChange(of: vm.isComplete) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                showFinishPrompt = vm.isComplete || vm.shouldExitOnboarding
            }
        }
        .onChange(of: vm.shouldExitOnboarding) { _ in
            withAnimation(.easeInOut(duration: 0.35)) {
                showFinishPrompt = vm.isComplete || vm.shouldExitOnboarding
            }
        }
    }
}

private struct FinishKaiCard: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("That’s all 8 questions.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HVTheme.botText)

            Text("Ready to wrap up and review your summary?")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.65))
                .multilineTextAlignment(.center)

            Button(action: onFinish) {
                HStack(spacing: 10) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("End Chat with Kai")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.6)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(HVTheme.accent)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
                )
            }
            .foregroundColor(.black)
            .buttonStyle(PressableButtonStyle())
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surface.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
        )
    }
}

private struct ProgressChip: View {
    var completed: Int
    var total: Int

    var body: some View {
        let shownTotal = max(total, 1)
        let shownCompleted = min(completed + 1, shownTotal)
        Text("Step \(shownCompleted) of \(shownTotal)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(HVTheme.surfaceAlt))
            .overlay(Capsule().stroke(HVTheme.stroke))
            .foregroundStyle(HVTheme.botText.opacity(0.8))
    }
}

private struct KaiNotesCard: View {
    var notes: [KaiNoteEntry]
    private let maxHeight: CGFloat = 170
    private let minHeight: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kai Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HVTheme.accent.opacity(0.8))
            }

            if notes.isEmpty {
                Text("Listening for your next answer…")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                KaiNotesList(notes: notes)
                    .frame(maxHeight: maxHeight)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [HVTheme.surface.opacity(0.95), HVTheme.surfaceAlt.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: notes.count)
    }
}

private struct KaiNotesList: View {
    var notes: [KaiNoteEntry]

    @State private var animatedIDs: Set<UUID> = []
    @State private var latestAnimatedId: UUID?
    @State private var hasInitialized = false
    @State private var animatingTask: Task<Void, Never>?
    @State private var autoScrollTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { note in
                        let latestId = notes.last?.id
                        let shouldAnimate = (note.id == latestId && !animatedIDs.contains(note.id))
                        KaiNoteRow(note: note, animate: shouldAnimate)
                            .id(note.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if !hasInitialized {
                    animatedIDs = Set(notes.map { $0.id })
                    hasInitialized = true
                }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: notes.count) { _ in
                scrollToBottom(proxy, animated: true)
                if !hasInitialized {
                    animatedIDs = Set(notes.map { $0.id })
                    hasInitialized = true
                    return
                }
                guard let last = notes.last else { return }
                latestAnimatedId = last.id
                if animatedIDs.contains(last.id) { return }
                let duration = Double(last.text.count) * 0.012 + 0.25
                animatingTask?.cancel()
                startAutoScroll(proxy: proxy, targetId: last.id)
                animatingTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    } catch {
                        return
                    }
                    self.animatedIDs.insert(last.id)
                    if self.latestAnimatedId == last.id {
                        self.latestAnimatedId = nil
                    }
                }
            }
            .onChange(of: latestAnimatedId) { _ in
                startAutoScroll(proxy: proxy, targetId: latestAnimatedId)
            }
            .onDisappear {
                animatingTask?.cancel()
                autoScrollTask?.cancel()
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = notes.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func startAutoScroll(proxy: ScrollViewProxy, targetId: UUID?) {
        autoScrollTask?.cancel()
        guard let targetId else { return }
        autoScrollTask = Task { @MainActor in
            while self.latestAnimatedId == targetId {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(targetId, anchor: .bottom)
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }
}

private struct KaiNoteRow: View {
    var note: KaiNoteEntry
    var animate: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var timestampText: String {
        Self.timeFormatter.string(from: note.ts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(note.questionId)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HVTheme.accent.opacity(0.9))
                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(HVTheme.botText.opacity(0.45))
            }
            if animate {
                StreamingMarkdownText(
                    fullText: note.text,
                    animate: true,
                    charDelay: 0.012
                )
                .font(.footnote)
                .foregroundStyle(HVTheme.botText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(HVTheme.surfaceAlt.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct SummaryView: View {
    @Binding var profile: ProfileData
    var discovery: [String: String]
    var isSavingProfile: Bool
    var onUpdateProfile: (ProfileData) -> Void
    var onUpdateDiscovery: ([String: String]) -> Void
    var onConfirm: () -> Void
    var onOpenHushhTech: () -> Void

    @State private var editingField: SummaryField?
    @State private var expandedSections: Set<SummarySectionKind> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    SummaryHeroSection(
                        name: profile.fullName,
                        netWorth: discovery["net_worth"] ?? "",
                        investorIdentity: discovery["investor_identity"] ?? "",
                        capitalIntent: discovery["capital_intent"] ?? "",
                        onJump: { kind in
                            withAnimation(.easeInOut(duration: 0.4)) {
                                proxy.scrollTo(kind, anchor: .top)
                            }
                        }
                    )

                    SummaryHighlightsRow(highlights: summaryHighlights())

                    SummaryHushhTechNote()

                    VStack(spacing: 14) {
                        ForEach(SummarySectionKind.allCases, id: \.self) { kind in
                            SummaryAccordionSection(
                                title: kind.title,
                                summary: sectionSummary(for: kind),
                                confidence: sectionConfidence(for: kind),
                                whyText: sectionWhy(for: kind),
                                rows: sectionRows(for: kind),
                                isExpanded: Binding(
                                    get: { expandedSections.contains(kind) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedSections.insert(kind)
                                        } else {
                                            expandedSections.remove(kind)
                                        }
                                    }
                                ),
                                onEdit: { editingField = $0 }
                            )
                            .id(kind)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 140)
            }
            .safeAreaInset(edge: .bottom) {
                SummaryStickyCTA(onConfirm: onConfirm, onOpenHushhTech: onOpenHushhTech)
            }
        }
        .sheet(item: $editingField) { field in
            SummaryFieldEditor(
                field: field,
                currentValue: field.currentValue(profile: profile, discovery: discovery),
                isSavingProfile: isSavingProfile,
                onSave: { newValue in
                    handleFieldSave(field: field, newValue: newValue)
                }
            )
        }
    }

    private func handleFieldSave(field: SummaryField, newValue: String) {
        switch field {
        case .profileName:
            profile.fullName = newValue
            onUpdateProfile(profile)
        case .profilePhone:
            profile.phone = newValue
            onUpdateProfile(profile)
        case .profileEmail:
            profile.email = newValue
            onUpdateProfile(profile)
        default:
            onUpdateDiscovery([field.discoveryKey: newValue])
        }
    }

    private func displayValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : value
    }

    private func sectionRows(for kind: SummarySectionKind) -> [SummaryRowData] {
        switch kind {
        case .profile:
            return [
                SummaryRowData(label: "Full name", value: profile.fullName, field: .profileName),
                SummaryRowData(label: "Phone", value: profile.phone, field: .profilePhone),
                SummaryRowData(label: "Email", value: profile.email, field: .profileEmail),
            ]
        case .capitalBase:
            return [
                SummaryRowData(label: "Net worth", value: discovery["net_worth"] ?? "", field: .netWorth),
                SummaryRowData(label: "Asset breakdown", value: discovery["asset_breakdown"] ?? "", field: .assetBreakdown),
            ]
        case .investorStyle:
            return [
                SummaryRowData(label: "Identity", value: discovery["investor_identity"] ?? "", field: .investorIdentity),
                SummaryRowData(label: "Capital intent", value: discovery["capital_intent"] ?? "", field: .capitalIntent),
            ]
        case .allocation:
            return [
                SummaryRowData(label: "Comfort (12–24m)", value: discovery["allocation_comfort_12_24m"] ?? "", field: .allocationComfort),
                SummaryRowData(label: "Mechanics depth", value: discovery["allocation_mechanics_depth"] ?? "", field: .allocationMechanics),
                SummaryRowData(label: "Fund fit", value: discovery["fund_fit_alignment"] ?? "", field: .fundFitAlignment),
            ]
        case .experience:
            return [
                SummaryRowData(label: "Proud decision", value: discovery["experience_proud"] ?? "", field: .experienceProud),
                SummaryRowData(label: "Regret decision", value: discovery["experience_regret"] ?? "", field: .experienceRegret),
            ]
        case .location:
            return [
                SummaryRowData(label: "Country", value: discovery["contact_country"] ?? "", field: .contactCountry),
            ]
        }
    }

    private func sectionSummary(for kind: SummarySectionKind) -> String {
        switch kind {
        case .profile:
            let name = displayValue(profile.fullName)
            let email = displayValue(profile.email)
            return "\(name) • \(email)"
        case .capitalBase:
            let net = displayValue(discovery["net_worth"] ?? "")
            let mix = displayValue(discovery["asset_breakdown"] ?? "")
            return "\(net) • \(mix)"
        case .investorStyle:
            let identity = displayValue(discovery["investor_identity"] ?? "")
            let intent = displayValue(discovery["capital_intent"] ?? "")
            return "\(identity) • \(intent)"
        case .allocation:
            let comfort = displayValue(discovery["allocation_comfort_12_24m"] ?? "")
            let fit = displayValue(discovery["fund_fit_alignment"] ?? "")
            return "\(comfort) • \(fit)"
        case .experience:
            let proud = displayValue(discovery["experience_proud"] ?? "")
            let regret = displayValue(discovery["experience_regret"] ?? "")
            return "\(proud) • \(regret)"
        case .location:
            return displayValue(discovery["contact_country"] ?? "")
        }
    }

    private func sectionConfidence(for kind: SummarySectionKind) -> String {
        let filled = sectionRows(for: kind)
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let total = sectionRows(for: kind).count
        return filled == total ? "High" : "Medium"
    }

    private func sectionWhy(for kind: SummarySectionKind) -> String {
        sectionSummary(for: kind)
    }

    private func summaryHighlights() -> [SummaryHighlight] {
        let highlights = [
            SummaryHighlight(label: "Capital scale", value: compactHighlightValue(discovery["net_worth"] ?? "")),
            SummaryHighlight(label: "Risk posture", value: compactHighlightValue(discovery["investor_identity"] ?? "")),
            SummaryHighlight(label: "Time horizon", value: compactHighlightValue(discovery["capital_intent"] ?? "")),
            SummaryHighlight(label: "Allocation comfort", value: compactHighlightValue(discovery["allocation_comfort_12_24m"] ?? "")),
            SummaryHighlight(label: "Country", value: compactHighlightValue(discovery["contact_country"] ?? "")),
        ]
        return highlights.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func compactHighlightValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let words = trimmed.split(separator: " ")
        if words.count > 4 {
            return words.prefix(4).joined(separator: " ")
        }
        if trimmed.count > 28 {
            let prefix = trimmed.prefix(28)
            return "\(prefix)..."
        }
        return trimmed
    }
}

private enum SummarySectionKind: CaseIterable {
    case profile
    case capitalBase
    case investorStyle
    case allocation
    case experience
    case location

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .capitalBase: return "Capital Base"
        case .investorStyle: return "Investor Style"
        case .allocation: return "Allocation"
        case .experience: return "Experience"
        case .location: return "Location"
        }
    }
}

private struct SummaryHeroSection: View {
    var name: String
    var netWorth: String
    var investorIdentity: String
    var capitalIntent: String
    var onJump: (SummarySectionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kai's understanding of you")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(HVTheme.botText)
            Text("Here's how Kai understands you so far.")
                .font(.subheadline)
                .foregroundStyle(HVTheme.botText.opacity(0.6))

            VStack(spacing: 8) {
                SummaryHeroRow(
                    label: "Name",
                    value: name,
                    onJump: { onJump(.profile) }
                )
                SummaryHeroDivider()
                SummaryHeroRow(
                    label: "Net worth range",
                    value: netWorth,
                    onJump: { onJump(.capitalBase) }
                )
                SummaryHeroDivider()
                SummaryHeroRow(
                    label: "Investor identity",
                    value: investorIdentity,
                    onJump: { onJump(.investorStyle) }
                )
                SummaryHeroDivider()
                SummaryHeroRow(
                    label: "Capital intent",
                    value: capitalIntent,
                    onJump: { onJump(.allocation) }
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surface.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.06))
        )
    }
}

private struct SummaryHeroRow: View {
    var label: String
    var value: String
    var onJump: () -> Void

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.55))

            Spacer(minLength: 12)

            Text(displayValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HVTheme.botText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            Button(action: onJump) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.55))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(label)")
        }
    }
}

private struct SummaryHeroDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

private struct SummaryHighlight: Identifiable {
    let id = UUID()
    var label: String
    var value: String
}

private struct SummaryHighlightsRow: View {
    var highlights: [SummaryHighlight]

    var body: some View {
        if highlights.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(highlights) { item in
                        SummaryHighlightPill(label: item.label, value: item.value)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct SummaryHighlightPill: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.6))
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HVTheme.botText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 6)
    }
}

private struct SummaryHushhTechNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
                .padding(6)
                .background(Circle().fill(HVTheme.surfaceAlt.opacity(0.8)))
            Text("HushhTech builds personal AI systems that work for you, not advertisers - private, consent-first, and fully under your control.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.65))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(HVTheme.surfaceAlt.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
        )
    }
}

private struct SummaryStickyCTA: View {
    var onConfirm: () -> Void
    var onOpenHushhTech: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onConfirm) {
                HStack {
                    Text("Confirm & continue with Kai")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(HVTheme.accent)
                )
            }
            .foregroundColor(.black)

            Button(action: onOpenHushhTech) {
                Text("Open HushhTech")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.8))
            }
            .buttonStyle(.plain)

            Button(action: onConfirm) {
                Text("I'll refine this later")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
            }
            .buttonStyle(.plain)

            Text("Kai will keep refining this as you talk.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.6))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
        )
    }
}

private struct SummaryAccordionSection: View {
    var title: String
    var summary: String
    var confidence: String
    var whyText: String
    var rows: [SummaryRowData]
    @Binding var isExpanded: Bool
    var onEdit: (SummaryField) -> Void

    @State private var showWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(HVTheme.botText)
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(HVTheme.botText.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    ConfidenceBadge(level: confidence)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HVTheme.botText.opacity(0.6))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        SummaryEditableRow(row: row, onEdit: onEdit)
                    }
                }
                .padding(.top, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showWhy.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Why Kai thinks this")
                    }
                    .font(.caption)
                    .foregroundStyle(HVTheme.accent)
                }
                .buttonStyle(.plain)

                if showWhy {
                    Text("Based on your last answers, \(whyText)")
                        .font(.caption)
                        .foregroundStyle(HVTheme.botText.opacity(0.55))
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(HVTheme.surface.opacity(0.9))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.06)))
        )
    }
}

private struct ConfidenceBadge: View {
    var level: String

    var body: some View {
        Text(level)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(level == "High" ? HVTheme.accent.opacity(0.22) : HVTheme.surfaceAlt.opacity(0.8))
            )
            .foregroundStyle(level == "High" ? HVTheme.accent : HVTheme.botText.opacity(0.7))
            .accessibilityLabel("Confidence \(level)")
    }
}

private struct SummaryRowData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let field: SummaryField
}

private struct SummaryEditableRow: View {
    var row: SummaryRowData
    var onEdit: (SummaryField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
                Spacer()
                Button {
                    onEdit(row.field)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HVTheme.accent)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            if row.value.isEmpty {
                Text("Not provided")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(HVTheme.botText.opacity(0.45))
            } else {
                Text(row.value)
                    .font(.subheadline)
                    .foregroundStyle(HVTheme.botText)
                    .lineLimit(2)
            }
        }
    }
}

private struct SummaryFieldEditor: View {
    let field: SummaryField
    let currentValue: String
    var isSavingProfile: Bool
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(field.title)
                .font(.headline)
                .foregroundStyle(HVTheme.botText)

            TextEditor(text: $draft)
                .frame(height: 140)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                .foregroundStyle(HVTheme.botText)

            Button {
                onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } label: {
                HStack {
                    Text(isSavingProfile ? "Saving..." : "Save")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Image(systemName: "checkmark")
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.accent))
            }
            .foregroundColor(.black)
            .disabled(isSavingProfile)
        }
        .padding(24)
        .background(HVTheme.bg.ignoresSafeArea())
        .onAppear { draft = currentValue }
    }
}

private struct PostSummaryActionsView: View {
    var onExplore: () -> Void
    var onGoToHushhTech: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 8) {
                Text("You're set")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(HVTheme.botText)
                Text("Choose where you want to go next.")
                    .font(.subheadline)
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
            }

            VStack(spacing: 14) {
                Button(action: onExplore) {
                    HStack {
                        Text("Explore HushhVoice")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "sparkles")
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 16).fill(HVTheme.accent))
                }
                .foregroundColor(.black)

                Button(action: onGoToHushhTech) {
                    HStack {
                        Text("Go to HushhTech")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(HVTheme.stroke, lineWidth: 1)
                            .background(RoundedRectangle(cornerRadius: 16).fill(HVTheme.surfaceAlt))
                    )
                }
                .foregroundStyle(HVTheme.botText)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }
}

private struct HushhTechIntroOneView: View {
    var onContinue: () -> Void
    @State private var isPressing = false
    @State private var animateIn = false

    var body: some View {
        OnboardingContainer {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        OnboardingChip(text: "Step 2 of 4")
                        Spacer()
                    }

                    ProgressDots(total: 4, current: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 16) {
                    LogoOrb(size: 220, logoSize: 72, wakePulse: false)
                        .opacity(animateIn ? 1 : 0)
                        .scaleEffect(animateIn ? 1 : 0.98)
                        .animation(.easeOut(duration: 0.5).delay(0.05), value: animateIn)

                    VStack(spacing: 10) {
                        Text("Your data. Your intelligence. Your control.")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(HVTheme.botText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(-1)
                        Text("HushhTech helps you organize and use your personal data - privately, securely, and on your terms.")
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(HVTheme.botText.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
                    .animation(.easeOut(duration: 0.4).delay(0.18), value: animateIn)
                }

                Button(action: onContinue) {
                    HStack {
                        Text("Continue")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .offset(x: isPressing ? 4 : 0)
                            .animation(.easeOut(duration: 0.15), value: isPressing)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.accent.opacity(0.95),
                                        HVTheme.accent.opacity(0.75)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                }
                .foregroundColor(.black)
                .buttonStyle(PressableButtonStyle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressing = true }
                        .onEnded { _ in isPressing = false }
                )
                .opacity(animateIn ? 1 : 0)
                .offset(y: animateIn ? 0 : 10)
                .animation(.easeOut(duration: 0.35).delay(0.28), value: animateIn)

                Spacer()
            }
            .padding(.vertical, 24)
            .onAppear { animateIn = true }
        }
    }
}

private struct LogoOrb: View {
    var size: CGFloat
    var logoSize: CGFloat
    var wakePulse: Bool

    @State private var breathe = false

    var body: some View {
        let scale = wakePulse ? 1.12 : (breathe ? 1.04 : 0.96)
        let opacity = wakePulse ? 1.0 : (breathe ? 0.85 : 0.6)

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [HVTheme.accent.opacity(0.55), Color.clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: size * 0.85
                    )
                )
                .frame(width: size, height: size)
                .blur(radius: 12)
                .scaleEffect(scale)
                .opacity(opacity)

            Circle()
                .fill(HVTheme.surfaceAlt.opacity(0.75))
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Circle().stroke(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)

            Image("hushh_quiet_logo")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

private struct HushhTechIntroTwoView: View {
    var onContinue: () -> Void
    @State private var showRows = false

    var body: some View {
        OnboardingContainer {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        OnboardingChip(text: "Step 3 of 4")
                        Spacer()
                    }
                    ProgressDots(total: 4, current: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 12) {
                    Text("AI that works for you, not on you.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(HVTheme.botText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(-2)
                    VStack(spacing: 0) {
                        FeatureRow(
                            icon: "lock.fill",
                            title: "Privacy-first",
                            description: "Nothing moves without consent",
                            show: showRows,
                            delay: 0
                        )
                        FeatureDivider()
                        FeatureRow(
                            icon: "person.fill",
                            title: "Personal AI",
                            description: "Understands you, not audiences",
                            show: showRows,
                            delay: 0.06
                        )
                        FeatureDivider()
                        FeatureRow(
                            icon: "sparkles",
                            title: "Real value",
                            description: "Better decisions and experiences",
                            show: showRows,
                            delay: 0.12
                        )
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.surface.opacity(0.7),
                                        HVTheme.surfaceAlt.opacity(0.6)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.07)))
                            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
                    )
                    .padding(.top, 6)
                }

                Text("No ads. No tracking. Consent First.")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.5))

                Button(action: onContinue) {
                    HStack {
                        Text("Continue")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.accent.opacity(0.95),
                                        HVTheme.accent.opacity(0.75)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                }
                .foregroundColor(.black)
                .buttonStyle(PressableButtonStyle())

                Spacer()
            }
            .padding(.vertical, 24)
            .onAppear { showRows = true }
        }
    }
}

private struct FeatureDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

private struct FeatureRow: View {
    var icon: String
    var title: String
    var description: String
    var show: Bool
    var delay: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
                .padding(8)
                .background(Circle().fill(HVTheme.surfaceAlt))
                .overlay(Circle().stroke(Color.white.opacity(0.08)))
                .scaleEffect(show ? 1.0 : 0.92)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HVTheme.botText)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(show ? 1 : 0)
        .offset(y: show ? 0 : 6)
        .animation(.easeOut(duration: 0.3).delay(delay), value: show)
    }
}

private struct MeetKaiView: View {
    var onStart: () -> Void
    var onNotNow: () -> Void
    @State private var pulse = false
    @State private var wakePulse = false

    var body: some View {
        OnboardingContainer {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        OnboardingChip(text: "Step 4 of 4")
                        Spacer()
                    }
                    ProgressDots(total: 4, current: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 12) {
                    LogoOrb(size: 240, logoSize: 76, wakePulse: wakePulse)
                        .frame(height: 140)
                    Text("Meet Kai")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(HVTheme.botText)
                    Text("A calm financial AI that helps you think clearly about capital allocation. Takes ~3-4 minutes.")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(HVTheme.botText.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                        .padding(.horizontal, 18)
                }

                HStack(spacing: 8) {
                    TrustChip(text: "Private by default", icon: "lock.fill")
                    TrustChip(text: "Skip anytime", icon: "forward.fill")
                    TrustChip(text: "Stop anytime", icon: "xmark")
                }

                Button(action: onStart) {
                    HStack {
                        Text("Start talking")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.accent.opacity(0.95),
                                        HVTheme.accent.opacity(0.75)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: HVTheme.accent.opacity(0.35), radius: 14, x: 0, y: 8)
                    )
                    .background(
                        Circle()
                            .stroke(HVTheme.accent.opacity(0.35), lineWidth: 2)
                            .frame(width: 160, height: 160)
                            .scaleEffect(pulse ? 1.08 : 0.92)
                            .opacity(pulse ? 0 : 0.35)
                    )
                }
                .foregroundColor(.black)
                .buttonStyle(PressableButtonStyle())
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            wakePulse = true
                        }
                        .onEnded { _ in
                            wakePulse = false
                        }
                )

                Button(action: onNotNow) {
                    Text("Not now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HVTheme.botText.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
                        )
                }
                .buttonStyle(PressableButtonStyle())

                Spacer()
            }
            .padding(.vertical, 24)
        }
    }
}

private struct TrustChip: View {
    var text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 96)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
    }
}

private enum SummaryField: String, Identifiable {
    case profileName
    case profilePhone
    case profileEmail
    case netWorth
    case assetBreakdown
    case investorIdentity
    case capitalIntent
    case allocationComfort
    case allocationMechanics
    case fundFitAlignment
    case experienceProud
    case experienceRegret
    case contactCountry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profileName: return "Full name"
        case .profilePhone: return "Phone"
        case .profileEmail: return "Email"
        case .netWorth: return "Net worth"
        case .assetBreakdown: return "Asset breakdown"
        case .investorIdentity: return "Investor identity"
        case .capitalIntent: return "Capital intent"
        case .allocationComfort: return "Allocation comfort (12-24m)"
        case .allocationMechanics: return "Allocation mechanics depth"
        case .fundFitAlignment: return "Fund fit alignment"
        case .experienceProud: return "Proud decision"
        case .experienceRegret: return "Regret decision"
        case .contactCountry: return "Country"
        }
    }

    var discoveryKey: String {
        switch self {
        case .netWorth: return "net_worth"
        case .assetBreakdown: return "asset_breakdown"
        case .investorIdentity: return "investor_identity"
        case .capitalIntent: return "capital_intent"
        case .allocationComfort: return "allocation_comfort_12_24m"
        case .allocationMechanics: return "allocation_mechanics_depth"
        case .fundFitAlignment: return "fund_fit_alignment"
        case .experienceProud: return "experience_proud"
        case .experienceRegret: return "experience_regret"
        case .contactCountry: return "contact_country"
        case .profileName, .profilePhone, .profileEmail:
            return ""
        }
    }

    func currentValue(profile: ProfileData, discovery: [String: String]) -> String {
        switch self {
        case .profileName: return profile.fullName
        case .profilePhone: return profile.phone
        case .profileEmail: return profile.email
        default: return discovery[discoveryKey] ?? ""
        }
    }
}

// ======================================================
// MARK: - Orb (metasidd/Orb wrapper)
// ======================================================

private struct KaiOrb: View {
    let configuration: OrbConfiguration
    let size: CGFloat

    var body: some View {
        OrbView(configuration: configuration)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 14)
    }
}

// ======================================================
// MARK: - Waveform View (Canvas)
// ======================================================

private struct WaveformView: View {
    var level: CGFloat
    var isMuted: Bool
    var accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let idle = 0.07 + 0.03 * sin(t * 1.3)
            let live = max(0.0, min(level, 1.0))
            let amp = max(0.04, isMuted ? idle : live)
            let speed = isMuted ? 1.25 : 1.85

            Canvas { context, size in
                let midY = size.height / 2
                let width = size.width
                let base = midY * amp

                let phases: [CGFloat] = [0.0, 0.85, 1.7]
                let weights: [CGFloat] = [1.0, 0.62, 0.38]

                for idx in 0..<phases.count {
                    let phase = CGFloat(t) * speed + phases[idx]
                    let amplitude = base * weights[idx]
                    let path = wavePath(width: width, midY: midY, amplitude: amplitude, phase: phase)

                    let opacity = isMuted ? 0.20 + (weights[idx] * 0.16) : 0.42 + (weights[idx] * 0.48)
                    let color = accent.opacity(opacity)

                    // soft glow layer
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 6))
                        layer.opacity = isMuted ? 0.24 : 0.55
                        layer.stroke(path, with: .color(color), lineWidth: 5)
                    }
                    // crisp stroke
                    context.stroke(path, with: .color(color), lineWidth: 2.6)
                }
            }
            .frame(height: 90)
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func wavePath(width: CGFloat, midY: CGFloat, amplitude: CGFloat, phase: CGFloat) -> Path {
        var path = Path()
        let points = 70
        for i in 0...points {
            let x = CGFloat(i) / CGFloat(points) * width
            let relative = CGFloat(i) / CGFloat(points)
            let sine = sin(relative * .pi * 2 + phase)
            let envelope = sin(relative * .pi)
            let y = midY + sine * amplitude * envelope
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// ======================================================
// MARK: - Quiet Mic Button (small + low)
// ======================================================

private struct QuietMicButtonSmall: View {
    @Binding var isMuted: Bool
    var onToggle: () -> Void

    @State private var pulse = false
    @State private var tapPulse = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                isMuted.toggle()
                onToggle()
                tapPulse = false
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                tapPulse = true
            }
        } label: {
            ZStack {
                Circle()
                    .fill(HVTheme.surfaceAlt.opacity(isMuted ? 0.80 : 1.0))
                    .overlay(Circle().stroke(HVTheme.stroke.opacity(isMuted ? 0.9 : 0.55), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)

                Circle()
                    .stroke(HVTheme.accent.opacity(isMuted ? 0.12 : 0.35), lineWidth: 2)
                    .scaleEffect(tapPulse ? 1.35 : 1.05)
                    .opacity(tapPulse ? 0.0 : 0.85)
                    .animation(.easeOut(duration: 0.45), value: tapPulse)

                Circle()
                    .stroke(HVTheme.accent.opacity(isMuted ? 0.16 : 0.40), lineWidth: isMuted ? 1 : 2)
                    .scaleEffect(isMuted ? 1.02 : (pulse ? 1.16 : 1.05))
                    .opacity(isMuted ? 0.30 : (pulse ? 0.80 : 0.45))
                    .blur(radius: isMuted ? 0.6 : 2.0)
                    .animation(isMuted ? .none : .easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isMuted ? Color.red.opacity(0.9) : HVTheme.botText.opacity(0.9))
            }
            .frame(width: 62, height: 62) // smaller like reference
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
    }
}

// ======================================================
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
