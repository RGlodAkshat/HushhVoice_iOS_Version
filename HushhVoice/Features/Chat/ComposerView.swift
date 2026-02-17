import SwiftUI
import UIKit

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

    // Keeps the composer compact by default while still being tappable and comfortable.
    private let inputMinHeight: CGFloat = 44
    private let inputMaxHeight: CGFloat = 100
    private let buttonSize: CGFloat = 36
    private let iconSize: CGFloat = 18

    @State private var inputHeight: CGFloat = 44

    var body: some View {
        // Premium minimal dark: slightly gray-black (RGB 28,28,30).
        let composerBG = Color(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0)
        let border = Color.white.opacity(0.08)
        let cornerRadius: CGFloat = 16
        let extraBottom = min(10.0, safeAreaBottomInset())
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(spacing: 8) {
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
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Circle().fill(composerBG))
                        .overlay(Circle().stroke(border, lineWidth: 1))
                }
                .tint(HVTheme.accent)

                HStack(alignment: .bottom, spacing: 8) {
                    GrowingTextEditor(
                        text: $text,
                        currentHeight: $inputHeight,
                        placeholder: "Ask HushhVoice…",
                        minHeight: inputMinHeight,
                        maxHeight: inputMaxHeight,
                        textColor: .white,
                        placeholderColor: Color.white.opacity(0.4),
                        contentInsets: EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15)
                    )
                    .frame(maxWidth: .infinity)

                    // Keep the trailing affordance space stable (no layout jump) by always reserving it.
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
                    .disabled(isSendDisabled || !hasText)
                    .opacity(hasText ? 1 : 0)
                    .allowsHitTesting(hasText && !isSendDisabled)
                    .accessibilityHidden(!hasText)
                }
                // Keep layout stable during expansion: the pill grows only with the text editor height.
                .frame(minHeight: max(inputMinHeight, inputHeight))
                .frame(maxWidth: .infinity)
                .padding(.trailing, 8)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(composerBG)
                        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(border, lineWidth: 1))
                )

                Button(action: onMicToggle) {
                    Image(systemName: isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: buttonSize, height: buttonSize)
                        .background(Circle().fill(composerBG))
                        .overlay(Circle().stroke(border, lineWidth: 1))
                }
                .tint(isMicMuted ? Color.white.opacity(0.6) : HVTheme.accent)
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10 + extraBottom)
        .tint(HVTheme.accent)
    }

    private func safeAreaBottomInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let inset = scene.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom {
                return inset
            }
        }
        return 0
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
