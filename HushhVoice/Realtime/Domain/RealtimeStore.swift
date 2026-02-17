import Foundation

@MainActor
final class RealtimeStore {
    private let reducer: RealtimeReducer
    private(set) var state: RealtimeState {
        didSet {
            onStateChange?(state)
        }
    }

    var onStateChange: ((RealtimeState) -> Void)?

    init(
        initialState: RealtimeState = RealtimeState(),
        reducer: RealtimeReducer = RealtimeReducer()
    ) {
        self.state = initialState
        self.reducer = reducer
    }

    func send(_ action: RealtimeAction) {
        var queue: [RealtimeAction] = [action]

        while !queue.isEmpty {
            let next = queue.removeFirst()
            let followUps = reducer.reduce(state: &state, action: next)
            if !followUps.isEmpty {
                queue.append(contentsOf: followUps)
            }
        }
    }

    func snapshot() -> RealtimeState {
        state
    }
}
