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
    var textColor: Color = .white
    var placeholderColor: Color = Color.white.opacity(0.4)
    var contentInsets: EdgeInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)

    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(placeholderColor)
                    .padding(contentInsets)
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
            .padding(contentInsets)
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
            .foregroundStyle(textColor)
            .padding(contentInsets)
            .frame(height: clampedHeight)
            // Ensure the editor itself doesn't draw an opaque background; the parent pill provides it.
            .background(Color.clear)
            .background(measureView.hidden())

        if #available(iOS 16.0, *) {
            base.scrollContentBackground(.hidden)
        } else {
            base
        }
    }
}
