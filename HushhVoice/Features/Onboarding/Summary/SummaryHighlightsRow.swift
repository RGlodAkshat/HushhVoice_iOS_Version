import SwiftUI

struct SummaryHighlightsRow: View {
    var highlights: [SummaryHighlight]

    var body: some View {
        if highlights.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(highlights) { item in
                        SummaryHighlightPill(label: item.label, value: item.value)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct SummaryHighlightPill: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.6))
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(HVTheme.botText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 6)
    }
}
