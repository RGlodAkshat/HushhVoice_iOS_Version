import SwiftUI

// Confirmation flow that clears local data and disconnects accounts.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ChatStore
    @ObservedObject var google: GoogleSignInManager

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @AppStorage("hushh_guest_mode") private var isGuest: Bool = false
    @AppStorage("hushh_kai_user_id") private var kaiUserID: String = ""

    @State private var confirmText: String = ""
    @State private var isDeleting: Bool = false
    @State private var errorText: String?
    @State private var success: Bool = false

    var onDeleted: () -> Void

    private var deleteEnabled: Bool {
        confirmText == "DELETE" && !isDeleting
    }

    var body: some View {
        Form {
            Section {
                Text("Deleting your account removes all personal data, onboarding answers, chat history, and disconnects integrations. This cannot be undone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } header: { Text("Warning") }

            Section {
                TextField("Type DELETE to confirm", text: $confirmText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if success {
                    Text("Your account has been deleted.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                }
            } footer: {
                Text("You must type DELETE to enable the button.")
            }

            Section {
                Button(role: .destructive) {
                    Task { await deleteAccount() }
                } label: {
                    if isDeleting {
                        ProgressView().tint(.red)
                    } else {
                        Text("Delete Account")
                    }
                }
                .disabled(!deleteEnabled)
            }
        }
        .navigationTitle("Delete Account")
    }

    @MainActor
    private func deleteAccount() async {
        // Disconnect integrations and clear local state.
        guard deleteEnabled else { return }
        isDeleting = true
        errorText = nil

        do {
            let token = await google.ensureValidAccessToken()
            try await HushhAPI.deleteAccount(
                googleToken: token,
                appleUserID: appleUserID,
                kaiUserID: kaiUserID
            )
        } catch {
            errorText = error.localizedDescription
            isDeleting = false
            return
        }

        clearLocalUserState()

        if google.hasConnectedGoogle {
            await google.disconnect()
        }
        if !appleUserID.isEmpty {
            AppleSupabaseAuth.shared.signOut()
            appleUserID = ""
        }

        store.clearAllChatsAndReset()
        isGuest = true
        success = true
        onDeleted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }

        isDeleting = false
    }

    @MainActor
    private func clearLocalUserState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hv_profile_completed")
        defaults.removeObject(forKey: "hv_hushhtech_intro_completed")
        defaults.removeObject(forKey: "hv_has_completed_investor_onboarding")
        defaults.removeObject(forKey: "hushh_has_seen_intro")
        defaults.removeObject(forKey: "hushh_kai_last_prompt")

        if !kaiUserID.isEmpty {
            defaults.removeObject(forKey: "hushh_kai_onboarding_state_v1_\(kaiUserID)")
            defaults.removeObject(forKey: "hushh_kai_onboarding_sync_pending_\(kaiUserID)")
        }
        if !appleUserID.isEmpty {
            defaults.removeObject(forKey: "hushh_kai_onboarding_state_v1_\(appleUserID)")
            defaults.removeObject(forKey: "hushh_kai_onboarding_sync_pending_\(appleUserID)")
        }

        kaiUserID = ""
    }
}
