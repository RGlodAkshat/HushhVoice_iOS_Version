import SwiftUI

struct AutoGrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    var minHeight: CGFloat = 26
    var maxHeight: CGFloat = 140
    var onReturn: (() -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.font = .systemFont(ofSize: 17)
        v.textColor = .white
        v.textContainerInset = .init(top: 8, left: 6, bottom: 8, right: 6)
        v.delegate = context.coordinator
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.keyboardDismissMode = .interactive
        v.returnKeyType = .send
        return v
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        DispatchQueue.main.async {
            let size = uiView.sizeThatFits(CGSize(width: uiView.bounds.width, height: .greatestFiniteMagnitude))
            calculatedHeight = min(max(size.height, minHeight), maxHeight)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AutoGrowingTextView
        init(_ parent: AutoGrowingTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude))
            parent.calculatedHeight = min(max(size.height, parent.minHeight), parent.maxHeight)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText: String) -> Bool {
            if replacementText == "\n" { // Send on return
                parent.onReturn?()
                return false
            }
            return true
        }
    }
}
