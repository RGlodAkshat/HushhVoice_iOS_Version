import SwiftUI

struct ChatView: View {
    @StateObject private var chat = ChatStore()
    @ObservedObject var auth = GoogleSignInManager.shared

    @State private var input: String = ""
    @State private var sending = false
    @State private var showTyping = false

    var body: some View {
        NavigationStack {
            ZStack {
                HVTheme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    HeaderBar()

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(chat.messages) { msg in
                                    MessageRow(message: msg)
                                        .id(msg.id)
                                }
                                if showTyping {
                                    TypingIndicatorView().id("typing")
                                }
                            }
                            .padding(.vertical, 12)
                        }
                        .onChange(of: chat.messages.last?.id) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                        }
                        .onChange(of: showTyping) { _, typing in
                            if typing { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                        }
                    }

                    Divider().background(HVTheme.stroke)

                    HStack {
                        ComposerView(
                            text: $input,
                            isSending: sending,
                            onSend: { Task { await send() } },
                            disabled: sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { chat.clear() }) {
                        Label("New Chat", systemImage: "plus.bubble.fill")
                    }
                    .tint(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if auth.isSignedIn {
                        Menu {
                            Button("Sign Out", role: .destructive) { auth.signOut() }
                        } label: {
                            Label("Signed In", systemImage: "person.crop.circle.fill.badge.checkmark")
                        }
                        .tint(.white)
                    } else {
                        Button(action: { auth.signIn() }) {
                            Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                        }.tint(.white)
                    }
                }
            }
            .preferredColorScheme(.dark) // Force Apple-dark vibe
            .task { auth.loadFromDisk() }
        }
    }

    private func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        sending = true
        input = ""
        showTyping = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        await chat.send(q, googleToken: auth.accessToken)
        showTyping = false
        sending = false
    }
}

#Preview {
    ChatView()
}
