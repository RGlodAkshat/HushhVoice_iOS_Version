import SwiftUI

struct SummaryAccordionSection: View {
    var title: String
    var summary: String
    var confidence: String
    var whyText: String
    var rows: [SummaryRowData]
    @Binding var isExpanded: Bool
    var onEdit: (SummaryField) -> Void

    @State private var showWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(HVTheme.botText)
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(HVTheme.botText.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    ConfidenceBadge(level: confidence)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HVTheme.botText.opacity(0.6))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        SummaryEditableRow(row: row, onEdit: onEdit)
                    }
                }
                .padding(.top, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showWhy.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("Why Kai thinks this")
                    }
                    .font(.caption)
                    .foregroundStyle(HVTheme.accent)
                }
                .buttonStyle(.plain)

                if showWhy {
                    Text("Based on your last answers, \(whyText)")
                        .font(.caption)
                        .foregroundStyle(HVTheme.botText.opacity(0.55))
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(HVTheme.surface.opacity(0.9))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.06)))
        )
    }
}

struct ConfidenceBadge: View {
    var level: String

    var body: some View {
        Text(level)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(level == "High" ? HVTheme.accent.opacity(0.22) : HVTheme.surfaceAlt.opacity(0.8))
            )
            .foregroundStyle(level == "High" ? HVTheme.accent : HVTheme.botText.opacity(0.7))
            .accessibilityLabel("Confidence \(level)")
    }
}

struct SummaryEditableRow: View {
    var row: SummaryRowData
    var onEdit: (SummaryField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
                Spacer()
                Button {
                    onEdit(row.field)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HVTheme.accent)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
            if row.value.isEmpty {
                Text("Not provided")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(HVTheme.botText.opacity(0.45))
            } else {
                Text(row.value)
                    .font(.subheadline)
                    .foregroundStyle(HVTheme.botText)
                    .lineLimit(2)
            }
        }
    }
}
