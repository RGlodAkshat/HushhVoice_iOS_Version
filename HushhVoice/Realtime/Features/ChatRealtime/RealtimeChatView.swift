import SwiftUI

struct RealtimeChatView: View {
    @StateObject private var viewModel = RealtimeChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if let error = viewModel.state.session.lastError, !error.isEmpty {
                errorBanner(error)
            }
            debugPanel
            Divider()
            messageList
            composer
        }
        .navigationTitle("Realtime Chat")
        .onAppear {
            viewModel.onAppear(autoConnect: false)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button(viewModel.isConnected ? "Disconnect" : "Connect") {
                if viewModel.isConnected {
                    viewModel.disconnect()
                } else {
                    viewModel.connect()
                }
            }
            .buttonStyle(.borderedProminent)

            Button(viewModel.isMicEnabled ? "Mic On" : "Mic Placeholder") {
                viewModel.toggleMic()
            }
            .buttonStyle(.bordered)

            Button("Cancel") {
                viewModel.cancel()
            }
            .buttonStyle(.bordered)

            Spacer()

            Text(viewModel.state.session.status.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.85))
    }

    private var debugPanel: some View {
        let turnId = viewModel.state.activeTurnId
        let turn = turnId.flatMap { viewModel.state.turns[$0] }
        let activeResponseId = turn?.activeResponseId ?? viewModel.state.streaming.activeResponseId
        let turnStatus = turn?.status.rawValue ?? "none"
        let transcript = turn?.userTranscriptBuffer ?? ""

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Turn: \(turnStatus)")
                Text("Response: \(activeResponseId ?? "nil")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !transcript.isEmpty {
                Text("Transcript: \(transcript)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.state.messages) { message in
                        MessageBubbleView(
                            text: message.text,
                            role: message.role,
                            isStreaming: message.role == .assistant && !message.isFinal
                        )
                        .id(message.id)
                    }

                    if shouldShowStandaloneStreamingBubble {
                        MessageBubbleView(
                            text: viewModel.state.streaming.activeAssistantText,
                            role: .assistant,
                            isStreaming: true
                        )
                        .id("streaming-bubble")
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.state.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.state.streaming.activeAssistantText) {
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Type a message", text: $viewModel.draftText)
                .textFieldStyle(.roundedBorder)

            Button("Send") {
                viewModel.sendText()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private var shouldShowStandaloneStreamingBubble: Bool {
        guard let activeResponseId = viewModel.state.streaming.activeResponseId else {
            return false
        }
        guard !viewModel.state.streaming.activeAssistantText.isEmpty else {
            return false
        }
        let hasMappedMessage = viewModel.state.messages.contains {
            $0.role == .assistant && $0.responseId == activeResponseId
        }
        return !hasMappedMessage
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessageId = viewModel.state.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessageId, anchor: .bottom)
            }
        } else if shouldShowStandaloneStreamingBubble {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("streaming-bubble", anchor: .bottom)
            }
        }
    }
}

private struct MessageBubbleView: View {
    let text: String
    let role: ChatMessage.Role
    let isStreaming: Bool

    var body: some View {
        HStack {
            if role == .assistant || role == .system {
                bubble(background: Color.gray.opacity(0.18), textColor: .primary)
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 24)
                bubble(background: Color.blue.opacity(0.2), textColor: .primary)
            }
        }
    }

    private func bubble(background: Color, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isStreaming {
                Text("Streaming...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
