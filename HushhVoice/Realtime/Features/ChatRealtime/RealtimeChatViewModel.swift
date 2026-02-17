import Foundation
import SwiftUI

@MainActor
final class RealtimeChatViewModel: ObservableObject {
    @Published private(set) var state: RealtimeState
    @Published var draftText: String = ""
    @Published var isMicEnabled: Bool = false

    let store: RealtimeStore
    let coordinator: RealtimeCoordinator
    private var debugEnabled: Bool { RealtimeDebug.enabled }

    init(
        store: RealtimeStore,
        coordinator: RealtimeCoordinator? = nil
    ) {
        self.store = store
        self.coordinator = coordinator ?? RealtimeCoordinator(store: store)
        self.state = store.snapshot()

        self.store.onStateChange = { [weak self] newState in
            self?.state = newState
        }

        if debugEnabled {
            print(
                "[RealtimeChatVM] init store=\(ObjectIdentifier(store)) coordinator=\(ObjectIdentifier(self.coordinator))"
            )
        }
    }

    convenience init() {
        let store = RealtimeStore()
        self.init(store: store, coordinator: nil)
    }

    func onAppear(autoConnect: Bool = false) {
        if autoConnect {
            connect()
        }
    }

    func connect() {
        let clientSecret = ProcessInfo.processInfo.environment["OPENAI_REALTIME_CLIENT_SECRET"] ?? ""
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedSecret.isEmpty else {
            store.send(.transport(.error("OPENAI_REALTIME_CLIENT_SECRET is missing")))
            return
        }

        coordinator.start(clientSecret: trimmedSecret)
        if debugEnabled { print("[RealtimeChatVM] connect()") }
    }

    func disconnect() {
        coordinator.stop()
    }

    func toggleMic() {
        isMicEnabled.toggle()
        store.send(.userIntent(.toggleMic(isOn: isMicEnabled)))
        coordinator.setMicEnabled(isMicEnabled)
    }

    func sendText(_ text: String? = nil) {
        let message = (text ?? draftText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        if debugEnabled { print("[RealtimeChatVM] sendText chars=\(message.count)") }
        draftText = ""
        store.send(.userIntent(.sendText(message)))

        Task {
            await coordinator.sendUserText(message)
        }
    }

    func cancel() {
        Task {
            await coordinator.cancelActiveResponse()
        }
    }

    var isConnected: Bool {
        state.session.status == .connected
    }
}
