import SwiftUI

struct SummaryFieldEditor: View {
    let field: SummaryField
    let currentValue: String
    var isSavingProfile: Bool
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(field.title)
                .font(.headline)
                .foregroundStyle(HVTheme.botText)

            TextEditor(text: $draft)
                .frame(height: 140)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                .foregroundStyle(HVTheme.botText)

            Button {
                onSave(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } label: {
                HStack {
                    Text(isSavingProfile ? "Saving..." : "Save")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Image(systemName: "checkmark")
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(HVTheme.accent))
            }
            .foregroundColor(.black)
            .disabled(isSavingProfile)
        }
        .padding(24)
        .background(HVTheme.bg.ignoresSafeArea())
        .onAppear { draft = currentValue }
    }
}
