import SwiftUI

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// TextEditor that grows until maxHeight, then scrolls internally.
struct GrowingTextEditor: View {
    @Binding var text: String
    @Binding var currentHeight: CGFloat
    let placeholder: String
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(HVTheme.botText.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }

            editor
        }
        .frame(height: clampedHeight)
    }

    private var clampedHeight: CGFloat {
        let base = max(minHeight, measuredHeight)
        return min(base, maxHeight)
    }

    private var measureView: some View {
        Text(text.isEmpty ? " " : text + " ")
            .font(.body)
            .lineSpacing(2)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: TextHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(TextHeightKey.self) { newHeight in
                let clamped = min(maxHeight, max(minHeight, newHeight))
                if abs(clamped - currentHeight) > 0.5 {
                    currentHeight = clamped
                }
                measuredHeight = newHeight
            }
    }

    @ViewBuilder
    private var editor: some View {
        let base = TextEditor(text: $text)
            .font(.body)
            .foregroundStyle(HVTheme.botText)
            .frame(height: clampedHeight)
            .background(measureView.hidden())

        if #available(iOS 16.0, *) {
            base.scrollContentBackground(.hidden)
        } else {
            base
        }
    }
}
