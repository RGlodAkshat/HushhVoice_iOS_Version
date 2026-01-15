import SwiftUI

// Renders a single chat message (user vs assistant styles).
struct MessageRow: View {
    let message: Message
    let isLastAssistant: Bool
    let hideControls: Bool
    let isSpeaking: Bool
    let isLoadingTTS: Bool
    var onCopy: (() -> Void)?
    var onSpeakToggle: (() -> Void)?
    var onReload: (() -> Void)?

    private var isUser: Bool { message.role == .user }

    var body: some View { isUser ? AnyView(userRow) : AnyView(assistantRow) }

    private var userRow: some View {
        // Right-aligned bubble for the user.
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(HVTheme.userText)
                    .multilineTextAlignment(.trailing)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.userBubble))
                    .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                    .animation(.easeOut(duration: 0.18), value: message.id)

                Button(action: { onCopy?() }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(6)
                        .background(Circle().fill(HVTheme.surfaceAlt))
                }
                .buttonStyle(.plain)
                .foregroundStyle(HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.accent)
            }
            .padding(.horizontal)
        }
    }

    private var assistantRow: some View {
        // Left-aligned bubble for the assistant + action buttons.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    StreamingMarkdownText(fullText: message.text, animate: isLastAssistant, charDelay: 0.01)
                        .font(.body)
                        .foregroundStyle(HVTheme.botText)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .opacity))
                        .animation(.easeOut(duration: 0.18), value: message.id)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal)

            if !hideControls {
                HStack(spacing: 12) {
                    Button(action: { onCopy?() }) {
                        Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.accent)

                    Button(action: { onSpeakToggle?() }) {
                        if isLoadingTTS {
                            ProgressView().scaleEffect(0.9)
                        } else if isSpeaking {
                            Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                        } else {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        isSpeaking ? HVTheme.accent :
                            (HVTheme.isDark ? Color.white.opacity(0.9) : HVTheme.botText)
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
                .padding(.vertical, 4)
                .opacity(0.9)
            }
        }
    }
}
