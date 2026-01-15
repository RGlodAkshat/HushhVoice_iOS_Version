import SwiftUI

struct KaiNotesList: View {
    var notes: [KaiNoteEntry]

    @State private var animatedIDs: Set<UUID> = []
    @State private var latestAnimatedId: UUID?
    @State private var hasInitialized = false
    @State private var animatingTask: Task<Void, Never>?
    @State private var autoScrollTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(notes) { note in
                        let latestId = notes.last?.id
                        let shouldAnimate = (note.id == latestId && !animatedIDs.contains(note.id))
                        KaiNoteRow(note: note, animate: shouldAnimate)
                            .id(note.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if !hasInitialized {
                    animatedIDs = Set(notes.map { $0.id })
                    hasInitialized = true
                }
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: notes.count) { _ in
                scrollToBottom(proxy, animated: true)
                if !hasInitialized {
                    animatedIDs = Set(notes.map { $0.id })
                    hasInitialized = true
                    return
                }
                guard let last = notes.last else { return }
                latestAnimatedId = last.id
                if animatedIDs.contains(last.id) { return }
                let duration = Double(last.text.count) * 0.012 + 0.25
                animatingTask?.cancel()
                startAutoScroll(proxy: proxy, targetId: last.id)
                animatingTask = Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    } catch {
                        return
                    }
                    self.animatedIDs.insert(last.id)
                    if self.latestAnimatedId == last.id {
                        self.latestAnimatedId = nil
                    }
                }
            }
            .onChange(of: latestAnimatedId) { _ in
                startAutoScroll(proxy: proxy, targetId: latestAnimatedId)
            }
            .onDisappear {
                animatingTask?.cancel()
                autoScrollTask?.cancel()
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = notes.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func startAutoScroll(proxy: ScrollViewProxy, targetId: UUID?) {
        autoScrollTask?.cancel()
        guard let targetId else { return }
        autoScrollTask = Task { @MainActor in
            while self.latestAnimatedId == targetId {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(targetId, anchor: .bottom)
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }
}
