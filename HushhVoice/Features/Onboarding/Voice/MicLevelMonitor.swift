import AVFoundation
import SwiftUI

// MARK: - Mic Level Monitor (for waveform)
// ======================================================

final class MicLevelMonitor: ObservableObject {
    @Published var level: CGFloat

    private static let idleLevel: CGFloat = 0.06
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var smoothedLevel: CGFloat
    private var isMuted = false
    private let bufferSize: AVAudioFrameCount = 1024

    init() {
        self.level = Self.idleLevel
        self.smoothedLevel = Self.idleLevel
    }

    func start() {
        if isRunning && engine.isRunning { return }
        isRunning = true

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.start() }
                }
            }
            return
        case .denied:
            isRunning = false
            DispatchQueue.main.async { self.level = Self.idleLevel }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        guard AudioSessionCoordinator.shared.configureIfNeeded() else {
            print("MicLevelMonitor audio session error: configure failed")
            isRunning = false
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        if format.sampleRate == 0 || format.channelCount == 0 {
            print("MicLevelMonitor: input format invalid; mic not available")
            isRunning = false
            return
        }
        print("MicLevelMonitor: start format rate=\(format.sampleRate) channels=\(format.channelCount)")

        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if self.isMuted {
                DispatchQueue.main.async {
                    self.level = Self.idleLevel
                }
                return
            }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var sum: Float = 0
            for i in 0..<frames { sum += channelData[i] * channelData[i] }
            let rms = sqrt(sum / Float(frames))
            let normalized = max(0, min((rms - 0.003) / 0.05, 1))
            let boosted = pow(normalized, 0.5)

            let target = Self.idleLevel + (1 - Self.idleLevel) * CGFloat(boosted)

            // Smooth
            let smoothing: CGFloat = 0.18
            smoothedLevel = smoothedLevel + (target - smoothedLevel) * smoothing

            DispatchQueue.main.async {
                self.level = self.smoothedLevel
            }
        }

        do {
            engine.prepare()
            try engine.start()
            print("MicLevelMonitor: engine started")
        } catch {
            print("MicLevelMonitor start error:", error)
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("MicLevelMonitor: engine stopped")
        DispatchQueue.main.async {
            self.level = Self.idleLevel
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            DispatchQueue.main.async {
                self.level = Self.idleLevel
            }
        } else {
            start()
        }
    }
}
