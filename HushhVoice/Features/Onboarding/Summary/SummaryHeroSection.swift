import SwiftUI

struct SummaryHeroSection: View {
    var name: String
    var netWorth: String
    var investorIdentity: String
    var capitalIntent: String
    var onJump: (SummarySectionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kai's understanding of you")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(HVTheme.botText)
            Text("Here's how Kai understands you so far.")
                .font(.subheadline)
                .foregroundStyle(HVTheme.botText.opacity(0.6))

            VStack(spacing: 8) {
                SummaryHeroRow(
                    label: "Name",
                    value: name,
                    onJump: { onJump(.profile) }
                )
                SummaryHeroDivider()
                SummaryHeroRow(
                    label: "Net worth range",
                    value: netWorth,
                    onJump: { onJump(.capitalBase) }
                )
                SummaryHeroDivider()
                SummaryHeroRow(
                    label: "Investor identity",
                    value: investorIdentity,
                    onJump: { onJump(.investorStyle) }
                )
                SummaryHeroDivider()
                SummaryHeroRow(
                    label: "Capital intent",
                    value: capitalIntent,
                    onJump: { onJump(.allocation) }
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(HVTheme.surface.opacity(0.92))
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.06))
        )
    }
}

struct SummaryHeroRow: View {
    var label: String
    var value: String
    var onJump: () -> Void

    private var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.55))

            Spacer(minLength: 12)

            Text(displayValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HVTheme.botText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)

            Button(action: onJump) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.55))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(label)")
        }
    }
}

struct SummaryHeroDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}
