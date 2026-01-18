import SwiftUI

// Input bar with attachments, expanding text input, and mic toggle.
struct ComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var isSendDisabled: Bool
    var isMicMuted: Bool
    var attachments: [ChatAttachment]
    var onSend: () -> Void
    var onAttach: () -> Void
    var onMicToggle: () -> Void
    var onRemoveAttachment: ((ChatAttachment) -> Void)?

    private let minHeight: CGFloat = 34
    private let maxHeight: CGFloat = 96
    private let iconSize: CGFloat = 18

    @State private var inputHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 6) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { item in
                            AttachmentChip(attachment: item, onRemove: { onRemoveAttachment?(item) })
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 30)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onAttach) {
                    Image(systemName: "plus")
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: minHeight, height: minHeight)
                        .background(Circle().fill(HVTheme.surfaceAlt))
                        .overlay(Circle().stroke(HVTheme.stroke))
                }
                .tint(HVTheme.accent)

                HStack(alignment: .bottom, spacing: 6) {
                    GrowingTextEditor(
                        text: $text,
                        currentHeight: $inputHeight,
                        placeholder: "Ask HushhVoice…",
                        minHeight: minHeight,
                        maxHeight: maxHeight
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)

                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: onSend) {
                            if isSending {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                            }
                        }
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white))
                        .foregroundStyle(Color.black)
                        .disabled(isSendDisabled)
                    }
                }
                .frame(minHeight: inputHeight + 8)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(HVTheme.surfaceAlt)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
                        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
                )

                Button(action: onMicToggle) {
                    Image(systemName: isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: minHeight, height: minHeight)
                        .background(Circle().fill(isMicMuted ? HVTheme.surfaceAlt : HVTheme.accent.opacity(0.2)))
                        .overlay(Circle().stroke(HVTheme.stroke))
                }
                .tint(isMicMuted ? HVTheme.botText : HVTheme.accent)
            }
            .padding(.vertical, 2)
        }
        .tint(HVTheme.accent)
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .semibold))
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(HVTheme.surfaceAlt)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(HVTheme.stroke))
        )
        .foregroundStyle(HVTheme.botText)
    }
}
