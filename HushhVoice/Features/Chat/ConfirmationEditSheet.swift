import SwiftUI

struct ConfirmationEditSheet: View {
    @Binding var text: String
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit draft")
                    .font(.headline)
                    .foregroundStyle(HVTheme.botText)

                TextEditor(text: $text)
                    .font(.body)
                    .foregroundStyle(HVTheme.botText)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(HVTheme.surfaceAlt)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                    )

                Spacer()
            }
            .padding()
            .background(HVTheme.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                }
            }
        }
    }
}
