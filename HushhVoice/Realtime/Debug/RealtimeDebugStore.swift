import Foundation

enum DebugLevel: String, Equatable {
    case debug
    case info
    case warn
    case error
}

enum DebugVerbosity: String, CaseIterable, Equatable {
    case off = "Off"
    case basic = "Basic"
    case verbose = "Verbose"
}

struct DebugEvent: Identifiable, Equatable {
    let id: UUID
    let ts: Date
    let level: DebugLevel
    let category: String
    let message: String
    let responseId: String?
    let turnId: String?

    init(
        id: UUID = UUID(),
        ts: Date = Date(),
        level: DebugLevel,
        category: String,
        message: String,
        responseId: String? = nil,
        turnId: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.level = level
        self.category = category
        self.message = message
        self.responseId = responseId
        self.turnId = turnId
    }
}

struct DebugSnapshot: Equatable {
    var renderedAt: Date = Date()
    var verbosity: DebugVerbosity = .off

    var sessionStatus: String = "idle"
    var dataChannel: String = "unknown"
    var micEnabled: Bool = false
    var activeResponseId: String? = nil
    var turnStatus: String = "none"
    var lastError: String? = nil

    // Published summary events (max 30). UI can request more from the ring buffer if needed.
    var lastEvents: [DebugEvent] = []
}

@MainActor
final class RealtimeDebugStore: ObservableObject {
    private let maxBuffer = 200
    private let publishedEventsLimit = 30
    private let publishHz: Double = 4.0

    private var buffer: [DebugEvent] = []
    private var pendingPublishTask: Task<Void, Never>?
    private var lastPublishAt: Date = .distantPast

    @Published private(set) var snapshot: DebugSnapshot

    var verbosity: DebugVerbosity {
        get { snapshot.verbosity }
        set {
            snapshot.verbosity = newValue
            snapshot.renderedAt = Date()
            requestPublish(force: true)
        }
    }

    init() {
        // Default: quiet. If the developer explicitly set HV_REALTIME_DEBUG=1, start in Basic.
        let env = ProcessInfo.processInfo.environment["HV_REALTIME_DEBUG"] == "1"
        self.snapshot = DebugSnapshot(verbosity: env ? .basic : .off)
    }

    func snapshotValue() -> DebugSnapshot {
        snapshot
    }

    func log(
        level: DebugLevel,
        category: String,
        message: String,
        responseId: String? = nil,
        turnId: String? = nil
    ) {
        // Keep ring buffer always, but only publish UI snapshot when verbosity != off.
        append(DebugEvent(level: level, category: category, message: message, responseId: responseId, turnId: turnId))

        guard snapshot.verbosity != .off else { return }
        requestPublish(force: false)
    }

    func clear() {
        buffer.removeAll()
        snapshot.lastEvents = []
        snapshot.renderedAt = Date()
        requestPublish(force: true)
    }

    func eventsForUI(limit: Int) -> [DebugEvent] {
        let n = max(0, min(limit, buffer.count))
        return Array(buffer.suffix(n))
    }

    func updateFromState(_ state: RealtimeState) {
        snapshot.sessionStatus = state.session.status.rawValue
        snapshot.lastError = state.session.lastError

        let turn = state.activeTurnId.flatMap { state.turns[$0] }
        snapshot.turnStatus = turn?.status.rawValue ?? "none"
        snapshot.activeResponseId = turn?.activeResponseId ?? state.streaming.activeResponseId

        guard snapshot.verbosity != .off else { return }
        requestPublish(force: false)
    }

    func setDataChannel(_ value: String) {
        snapshot.dataChannel = value
        guard snapshot.verbosity != .off else { return }
        requestPublish(force: false)
    }

    func setMicEnabled(_ enabled: Bool) {
        snapshot.micEnabled = enabled
        guard snapshot.verbosity != .off else { return }
        requestPublish(force: false)
    }

    func snapshotText(eventsLimit: Int = 15) -> String {
        let s = snapshot
        let events = eventsForUI(limit: eventsLimit)

        var lines: [String] = []
        lines.append("Realtime Debug Summary")
        lines.append("rendered_at=\(iso8601(s.renderedAt)) verbosity=\(s.verbosity.rawValue)")
        lines.append("session=\(s.sessionStatus) data_channel=\(s.dataChannel) mic=\(s.micEnabled)")
        lines.append("turn=\(s.turnStatus) response=\(s.activeResponseId ?? "nil")")
        if let err = s.lastError, !err.isEmpty {
            lines.append("last_error=\(err)")
        }
        lines.append("")
        lines.append("Events (last \(events.count)):")
        for e in events {
            lines.append("[\(timeOnly(e.ts))] \(e.level.rawValue.uppercased()) \(e.category): \(e.message)")
        }
        return lines.joined(separator: "\n")
    }

    private func append(_ event: DebugEvent) {
        buffer.append(event)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
    }

    private func requestPublish(force: Bool) {
        let now = Date()
        let minInterval = 1.0 / publishHz
        let elapsed = now.timeIntervalSince(lastPublishAt)

        if force || elapsed >= minInterval {
            publishNow()
            return
        }

        // Coalesce to <= 4Hz.
        if pendingPublishTask != nil { return }
        let delay = max(0.0, minInterval - elapsed)
        pendingPublishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self.pendingPublishTask = nil
                self.publishNow()
            }
        }
    }

    private func publishNow() {
        lastPublishAt = Date()
        snapshot.renderedAt = lastPublishAt
        snapshot.lastEvents = Array(buffer.suffix(publishedEventsLimit))
        // Trigger @Published update by re-assigning snapshot.
        snapshot = snapshot
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func timeOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
