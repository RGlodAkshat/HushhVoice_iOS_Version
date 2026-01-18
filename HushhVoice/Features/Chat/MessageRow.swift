import SwiftUI

// Renders a single chat message (user vs assistant styles).
struct MessageRow: View {
    let message: Message
    let isLastAssistant: Bool
    let hideControls: Bool
    let isSpeaking: Bool
    let isLoadingTTS: Bool
    var isSubdued: Bool = false
    var isDraft: Bool = false
    var isStreaming: Bool = false
    var onOpenURL: ((URL) -> Void)?
    var onCopy: (() -> Void)?
    var onSpeakToggle: (() -> Void)?
    var onReload: (() -> Void)?

    private var isUser: Bool { message.role == .user }

    var body: some View { isUser ? AnyView(userRow) : AnyView(assistantRow) }

    private var userRow: some View {
        // Right-aligned bubble for the user.
        let text = message.text.isEmpty && isDraft ? "Listening..." : message.text
        return VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)

                Text(text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(HVTheme.userText.opacity(isDraft ? 0.7 : 0.95))
                    .multilineTextAlignment(.trailing)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(HVTheme.userBubble.opacity(isDraft ? 0.2 : 0.35))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(HVTheme.stroke.opacity(0.6)))
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                    .animation(.easeOut(duration: 0.18), value: message.id)
            }
            .padding(.horizontal)

            if !isDraft {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(action: { onCopy?() }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(6)
                            .background(Circle().fill(HVTheme.surfaceAlt))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.accent)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var assistantRow: some View {
        // Left-aligned bubble for the assistant + action buttons.
        let maxWidth = UIScreen.main.bounds.width * 0.88
        let longURLs = MarkdownLinkDetector.longURLs(in: message.text)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                MarkdownTextBlock(
                    text: message.text,
                    isStreaming: isStreaming,
                    baseFont: .body,
                    textColor: HVTheme.botText.opacity(isSubdued ? 0.7 : 1)
                )
                .frame(maxWidth: maxWidth, alignment: .leading)

                if !isStreaming && !longURLs.isEmpty {
                    DisclosureGroup("Details") {
                        ForEach(longURLs, id: \.absoluteString) { url in
                            Text(url.absoluteString)
                                .font(.caption2)
                                .foregroundStyle(HVTheme.botText.opacity(0.6))
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
                }
            }
            .padding(.horizontal, 20)

            if !hideControls {
                HStack(spacing: 14) {
                    Button(action: { onCopy?() }) {
                        Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HVTheme.isDark ? Color.white.opacity(0.85) : HVTheme.accent)

                    Button(action: { onSpeakToggle?() }) {
                        if isLoadingTTS {
                            ProgressView().scaleEffect(0.9)
                        } else if isSpeaking {
                            Image(systemName: "stop.fill").font(.system(size: 14, weight: .semibold))
                        } else {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        isSpeaking ? HVTheme.accent :
                            (HVTheme.isDark ? Color.white.opacity(0.85) : HVTheme.botText)
                    )

                    Button(action: { onReload?() }) {
                        Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLastAssistant ? HVTheme.accent : HVTheme.botText.opacity(0.7))

                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
                .opacity(0.9)
            }

            if message.status == .interrupted {
                Text("Interrupted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
                    .padding(.horizontal, 20)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            onOpenURL?(url)
            return .handled
        })
    }
}
