import Foundation

struct DebugOverlayState {
    let sessionState: String
    let sttActive: Bool
    let sttMuted: Bool
    let serverVadEnabled: Bool
    let lastSessionUpdateStatus: String?
    let lastSessionUpdateError: String?
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let thread: String
    let component: String
    let event: String
    let message: String?
    let fields: [String: String]
    let sessionId: String?
    let turnId: String?
    let messageId: String?

    var formatted: String {
        let ts = DebugLogger.timestampFormatter.string(from: timestamp)
        let sid = sessionId ?? "-"
        let tid = turnId ?? "-"
        let mid = messageId ?? "-"
        let msg = message ?? ""
        let fieldPairs = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "[VOICE_DBG][\(component)][\(event)] ts=\(ts) thread=\(thread) sid=\(sid) tid=\(tid) mid=\(mid) \(msg) \(fieldPairs)".trimmingCharacters(in: .whitespaces)
    }
}

final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()
    static let timestampFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    @Published private(set) var entries: [DebugLogEntry] = []
    @Published var lastSessionUpdatePayload: String?
    @Published var lastSessionUpdateError: String?
    @Published var lastOpenAIError: String?

    private let maxEntries = 300
    private let sensitiveKeys = ["token", "secret", "key", "authorization", "password", "cookie"]

    private init() {}

    func log(
        component: String,
        event: String,
        message: String? = nil,
        fields: [String: Any] = [:],
        sessionId: String? = nil,
        turnId: String? = nil,
        messageId: String? = nil
    ) {
        let ts = Date()
        let thread = Thread.isMainThread ? "main" : "bg"
        let sanitized = sanitize(fields)
        let entry = DebugLogEntry(
            timestamp: ts,
            thread: thread,
            component: component,
            event: event,
            message: message,
            fields: sanitized,
            sessionId: sessionId,
            turnId: turnId,
            messageId: messageId
        )
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        print(entry.formatted)
    }

    func recentEntries(limit: Int) -> [DebugLogEntry] {
        Array(entries.suffix(limit))
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    func makeReproDump(state: DebugOverlayState?) -> String {
        var lines: [String] = []
        lines.append("VOICE DEBUG DUMP")
        lines.append("generated_at=\(DebugLogger.timestampFormatter.string(from: Date()))")
        if let state {
            lines.append("session_state=\(state.sessionState)")
            lines.append("stt_active=\(state.sttActive) stt_muted=\(state.sttMuted)")
            lines.append("server_vad_enabled=\(state.serverVadEnabled)")
            if let status = state.lastSessionUpdateStatus {
                lines.append("last_session_update_status=\(status)")
            }
            if let err = state.lastSessionUpdateError {
                lines.append("last_session_update_error=\(err)")
            }
        }
        if let payload = lastSessionUpdatePayload {
            lines.append("last_session_update_payload=\(payload)")
        }
        if let err = lastSessionUpdateError {
            lines.append("last_session_update_error=\(err)")
        }
        if let err = lastOpenAIError {
            lines.append("last_openai_error=\(err)")
        }
        lines.append("---- logs ----")
        for entry in recentEntries(limit: 200) {
            lines.append(entry.formatted)
        }
        return lines.joined(separator: "\n")
    }

    private func sanitize(_ fields: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in fields {
            let lower = key.lowercased()
            if sensitiveKeys.contains(where: { lower.contains($0) }) {
                out[key] = "<redacted>"
            } else {
                out[key] = stringify(value)
            }
        }
        return out
    }

    private func stringify(_ value: Any) -> String {
        if let str = value as? String {
            return str
        }
        if let num = value as? NSNumber {
            return num.stringValue
        }
        if let dict = value as? [String: Any] {
            return "{\(dict.keys.sorted().joined(separator: ","))}"
        }
        if let arr = value as? [Any] {
            return "[\(arr.count)]"
        }
        return String(describing: value)
    }
}
