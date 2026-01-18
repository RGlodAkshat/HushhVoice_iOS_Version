import Foundation
import AVFoundation
import SwiftUI

// Plays backend TTS audio and falls back to system speech.
final class SpeechManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()

    @Published var currentMessageID: UUID?
    @Published var isLoading: Bool = false
    @Published var isPlaying: Bool = false

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var streamingMode = false
    private var streamingSegmentCount = 0
    private var audioEngine: AVAudioEngine?
    private var audioNode: AVAudioPlayerNode?
    private var audioStreamFormat: AVAudioFormat?

    override init() {
        super.init()
        // Listen for synth completion callbacks.
        synth.delegate = self
    }

    func speak(_ text: String, messageID: UUID?) {
        // Public entry point: trims input then speaks.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await speakAsync(trimmed, messageID: messageID) }
    }

    func startStreamingSpeech(messageID: UUID?) {
        Task { await MainActor.run { self.startStreamingSpeechInternal(messageID: messageID) } }
    }

    func enqueueStreamingSegment(_ text: String) {
        Task { await MainActor.run { self.enqueueStreamingSegmentInternal(text) } }
    }

    func finishStreamingSpeech() {
        Task { await MainActor.run { self.finishStreamingSpeechInternal() } }
    }

    func startAudioStream(sampleRate: Double, channels: Int, messageID: UUID?) {
        Task { await MainActor.run { self.startAudioStreamInternal(sampleRate: sampleRate, channels: channels, messageID: messageID) } }
    }

    func appendAudioChunk(_ data: Data) {
        Task { await MainActor.run { self.appendAudioChunkInternal(data) } }
    }

    func finishAudioStream() {
        Task { await MainActor.run { self.finishAudioStreamInternal() } }
    }

    func stop() { Task { await MainActor.run { self.stopAllInternal() } } }

    private func speakAsync(_ text: String, messageID: UUID?) async {
        // Reset state and configure audio session.
        await MainActor.run {
            self.stopAllInternal()
            self.currentMessageID = messageID
            self.isLoading = true
            self.isPlaying = false
            self.configureAudioSession()
        }

        do {
            // Prefer backend TTS audio (better voice).
            let audioData = try await HushhAPI.tts(text: text, voice: "alloy")
            try await MainActor.run {
                self.player = try AVAudioPlayer(data: audioData)
                self.player?.delegate = self
                self.player?.prepareToPlay()
                self.isLoading = false
                self.isPlaying = true
                self.player?.play()
            }
            return
        } catch {
            // If backend fails, fall back to system voice.
            print("🔴 Backend TTS failed, falling back to system voice: \(error)")
        }

        await MainActor.run {
            self.isLoading = false
            self.isPlaying = true
            self.streamingMode = false
            let utterance = AVSpeechUtterance(string: text)
            if let betterVoice = AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = betterVoice
            }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
            self.synth.speak(utterance)
        }
    }

    private func configureAudioSession() {
        // Configure audio for spoken audio with speaker + Bluetooth.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    private func stopAllInternal() {
        // Stop any active audio and reset state flags.
        if let player, player.isPlaying { player.stop() }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if let node = audioNode {
            node.stop()
        }
        if let engine = audioEngine {
            engine.stop()
        }

        player = nil
        audioNode = nil
        audioEngine = nil
        audioStreamFormat = nil
        streamingMode = false
        streamingSegmentCount = 0
        isLoading = false
        isPlaying = false
        currentMessageID = nil

        if !AudioCaptureManager.shared.isCapturing {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [])
            } catch {
                print("AudioSession deactivation error: \(error)")
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Clean up when playback ends.
        Task { await MainActor.run { self.stopAllInternal() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Handle streaming vs normal speech completion.
        Task {
            await MainActor.run {
                if self.streamingMode {
                    self.streamingSegmentCount = max(0, self.streamingSegmentCount - 1)
                    if self.streamingSegmentCount == 0 && !self.synth.isSpeaking {
                        self.isPlaying = false
                        if !self.streamingMode {
                            self.stopAllInternal()
                        }
                    }
                } else {
                    self.stopAllInternal()
                }
            }
        }
    }

    private func startStreamingSpeechInternal(messageID: UUID?) {
        stopAllInternal()
        streamingMode = true
        streamingSegmentCount = 0
        currentMessageID = messageID
        isLoading = false
        isPlaying = false
        configureAudioSession()
    }

    private func enqueueStreamingSegmentInternal(_ text: String) {
        guard streamingMode else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        if let betterVoice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = betterVoice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        streamingSegmentCount += 1
        isPlaying = true
        synth.speak(utterance)
    }

    private func finishStreamingSpeechInternal() {
        streamingMode = false
        if !synth.isSpeaking && streamingSegmentCount == 0 {
            stopAllInternal()
        }
    }

    private func startAudioStreamInternal(sampleRate: Double, channels: Int, messageID: UUID?) {
        stopAllInternal()
        currentMessageID = messageID
        isLoading = false
        isPlaying = true
        configureAudioSession()

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)

        let channelCount = AVAudioChannelCount(max(1, channels))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            stopAllInternal()
            return
        }

        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            node.play()
            audioEngine = engine
            audioNode = node
            audioStreamFormat = format
        } catch {
            print("AudioStream start error: \(error)")
            stopAllInternal()
        }
    }

    private func appendAudioChunkInternal(_ data: Data) {
        guard let node = audioNode, let format = audioStreamFormat else { return }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let audioBuffer = buffer.int16ChannelData?[0]
            audioBuffer?.assign(from: baseAddress.assumingMemoryBound(to: Int16.self), count: frameCount)
        }

        node.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func finishAudioStreamInternal() {
        if let node = audioNode {
            node.stop()
        }
        if let engine = audioEngine {
            engine.stop()
        }
        audioNode = nil
        audioEngine = nil
        audioStreamFormat = nil
        isPlaying = false
    }
}
