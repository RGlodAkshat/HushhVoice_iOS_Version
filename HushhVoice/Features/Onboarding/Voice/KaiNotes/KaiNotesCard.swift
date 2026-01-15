import SwiftUI

struct KaiNotesCard: View {
    var notes: [KaiNoteEntry]
    private let maxHeight: CGFloat = 170
    private let minHeight: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kai Notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
                Spacer()
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HVTheme.accent.opacity(0.8))
            }

            if notes.isEmpty {
                Text("Listening for your next answer…")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                KaiNotesList(notes: notes)
                    .frame(maxHeight: maxHeight)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [HVTheme.surface.opacity(0.95), HVTheme.surfaceAlt.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(HVTheme.stroke))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: notes.count)
    }
}
