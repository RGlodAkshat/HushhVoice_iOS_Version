import Foundation

// WebSocket scaffolding for the canonical streaming protocol.
final class ChatStreamClient: ObservableObject {
    static let shared = ChatStreamClient()

    enum State: String {
        case idle
        case connecting
        case connected
        case disconnected
        case error
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var sessionID: String = UUID().uuidString

    var onEvent: ((StreamEventEnvelope) -> Void)?
    var onConnectionChange: ((State) -> Void)?

    private var webSocket: URLSessionWebSocketTask?
    private var seq: Int = 0
    private var turnSeq: Int = 0
    private let debugLogging = true

    private init() {}

    func connect(url: URL, headers: [String: String] = [:]) {
        guard state != .connected && state != .connecting else { return }
        DispatchQueue.main.async {
            self.state = .connecting
            self.onConnectionChange?(self.state)
        }

        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let task = URLSession.shared.webSocketTask(with: request)
        webSocket = task
        task.resume()
        DispatchQueue.main.async {
            self.state = .connected
            self.onConnectionChange?(self.state)
        }
        debugLog("connected \(url.absoluteString)")
        listen()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        DispatchQueue.main.async {
            self.state = .disconnected
            self.onConnectionChange?(self.state)
        }
        debugLog("disconnected")
    }

    func send(eventType: String, payload: [String: JSONValue], turnID: String? = nil, messageID: String? = nil, role: String? = nil) {
        guard let webSocket else { return }
        seq += 1
        if let turnID, !turnID.isEmpty {
            turnSeq += 1
        } else {
            turnSeq = 0
        }
        let env = StreamEventEnvelope.make(
            eventType: eventType,
            sessionID: sessionID,
            seq: seq,
            turnSeq: turnSeq,
            turnID: turnID,
            messageID: messageID,
            role: role,
            payload: payload
        )
        do {
            let data = try StreamEventCodec.encode(env)
            webSocket.send(.data(data)) { [weak self] error in
                if let error {
                    self?.handleError(error.localizedDescription)
                } else {
                    self?.debugLog("sent \(eventType)")
                }
            }
        } catch {
            handleError(error.localizedDescription)
        }
    }

    func sendPing() {
        send(eventType: "session.ping", payload: ["client_ts": .string(ISO8601DateFormatter().string(from: Date()))])
    }

    private func listen() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                self.handleMessage(msg)
                self.listen()
            case .failure(let error):
                self.handleError(error.localizedDescription)
                self.disconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleData(data)
        case .string(let text):
            if let data = text.data(using: .utf8) {
                handleData(data)
            }
        @unknown default:
            break
        }
    }

    private func handleData(_ data: Data) {
        do {
            let event = try StreamEventCodec.decode(data)
            debugLog("recv \(event.event_type)")
            onEvent?(event)
        } catch {
            handleError(error.localizedDescription)
        }
    }

    private func handleError(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
            self.state = .error
            self.onConnectionChange?(self.state)
        }
        debugLog("error \(message)")
    }

    private func debugLog(_ msg: String) {
        guard debugLogging else { return }
        print("🛰️ [ChatStream] \(msg)")
    }
}
