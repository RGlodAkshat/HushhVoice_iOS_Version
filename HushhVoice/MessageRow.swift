import SwiftUI

struct MessageRow: View {
    let message: Message
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 0) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                Text(isUser ? "You" : "HushhVoice")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))

                Text(message.text)
                    .textSelection(.enabled)
                    .font(.body)
                    .foregroundStyle(isUser ? HVTheme.userText : HVTheme.botText)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(
                        isUser
                        ? AnyView(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.userBubble))
                        : AnyView(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
                    )
                    .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
                    .contextMenu {
                        Button(action: { UIPasteboard.general.string = message.text }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }

            if !isUser { Spacer(minLength: 0) }
        }
        .padding(.horizontal)
    }
}
