import SwiftUI

// Settings screen: theme, integrations, account, help.
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var isDarkMode: Bool
    @ObservedObject var google: GoogleSignInManager
    @ObservedObject var store: ChatStore
    @Binding var isGuest: Bool

    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @State private var showHelpSheet: Bool = false

    var onSignOutAll: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Toggle(isOn: $isDarkMode) { Text("Dark Mode") }
                }

                Section("Integrations") {
                    HStack {
                        Text("Google")
                        Spacer()
                        Text(google.hasConnectedGoogle ? "Connected" : "Not Connected")
                            .foregroundStyle(google.hasConnectedGoogle ? .green : .secondary)
                            .font(.footnote)
                    }

                    if google.hasConnectedGoogle {
                        Button { google.signIn() } label: {
                            HStack {
                                Image(systemName: "envelope.circle.fill")
                                Text("Reconnect Google")
                            }
                        }

                        Button(role: .destructive) {
                            Task {
                                await google.disconnect()
                                if appleUserID.isEmpty {
                                    isGuest = true
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                Text("Disconnect Google")
                            }
                        }
                    } else {
                        Button { google.signIn() } label: {
                            HStack {
                                Image(systemName: "envelope.circle.fill")
                                Text("Sign in with Google")
                            }
                        }
                    }
                }

                if isGuest {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sign in to unlock integrations and sync")
                                .font(.headline)
                            Text("Connect Google or Apple to sync data and enable Gmail/Calendar features.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Accounts") {
                    HStack {
                        Text(appleUserID.isEmpty ? "Not Linked" : "Linked")
                            .foregroundColor(appleUserID.isEmpty ? .secondary : .green)
                            .font(.footnote)

                    }

                    // ✅ IMPORTANT: Do NOT wrap this in any SwiftUI Button.
                    if appleUserID.isEmpty {
                        SupabaseSignInWithAppleButton()
                    } else {
                        Button(role: .destructive) {
                            AppleSupabaseAuth.shared.signOut()
                            appleUserID = ""
                            if !google.hasConnectedGoogle {
                                isGuest = true
                            }
                        } label: {
                            Text("Unlink Apple ID")
                        }
                    }

                    if google.hasConnectedGoogle || !appleUserID.isEmpty {
                        Button(role: .destructive) {
                            onSignOutAll()
                            dismiss()
                        } label: {
                            Text("Sign out of HushhVoice")
                        }
                    }

                    NavigationLink {
                        DeleteAccountView(store: store, google: google, onDeleted: {
                            isGuest = true
                            dismiss()
                        })
                    } label: {
                        Text("Delete Account")
                    }
                }
                Section("Help") {
                    Button { showHelpSheet = true } label: {
                        HStack {
                            Image(systemName: "questionmark.circle")
                            Text("How to use HushhVoice")
                        }
                    }
                }

                Section("Coming Soon / Planned Features") {
                    Label("iCloud sync for chats", systemImage: "icloud")
                    Label("Offline voice mode", systemImage: "waveform")
                    Label("Expanded integrations (Drive, Slack)", systemImage: "bolt.horizontal")
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hushh.ai").font(.headline)
                        Text("A private, consent-first AI copilot for your data, email, and calendar.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showHelpSheet) { OnboardingView() }
        }
    }
}
