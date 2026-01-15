import AVFoundation

final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private let lock = NSLock()
    private var configured = false
    private let debugEnabled = true

    private func routeSummary(_ session: AVAudioSession) -> String {
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        return "inputs=[\(inputs)] outputs=[\(outputs)]"
    }

    private func permissionSummary(_ session: AVAudioSession) -> String {
        switch session.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    func configureIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if configured { return true }

        let session = AVAudioSession.sharedInstance()
        do {
            if debugEnabled {
                print("[AudioSession] pre-config permission=\(permissionSummary(session)) route=\(routeSummary(session))")
            }
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
            )
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.02)
            try? session.setPreferredInputNumberOfChannels(1)
            try? session.setPreferredOutputNumberOfChannels(1)
            try session.setActive(true, options: [])
            configured = true
            print("[AudioSession] ready sampleRate=\(session.sampleRate) inCh=\(session.inputNumberOfChannels) outCh=\(session.outputNumberOfChannels) route=\(routeSummary(session))")
            return true
        } catch {
            print("AudioSession configure error:", error)
            return false
        }
    }
}
