import SwiftUI
import UIKit

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
