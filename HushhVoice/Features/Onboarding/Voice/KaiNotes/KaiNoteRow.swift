import SwiftUI

struct KaiNoteRow: View {
    var note: KaiNoteEntry
    var animate: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var timestampText: String {
        Self.timeFormatter.string(from: note.ts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(note.questionId)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HVTheme.accent.opacity(0.9))
                Text(timestampText)
                    .font(.caption2)
                    .foregroundStyle(HVTheme.botText.opacity(0.45))
            }
            if animate {
                StreamingMarkdownText(
                    fullText: note.text,
                    animate: true,
                    charDelay: 0.012,
                    baseFont: .footnote,
                    textColor: HVTheme.botText
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(note.text)
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(HVTheme.surfaceAlt.opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
