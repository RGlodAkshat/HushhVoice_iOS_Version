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

        player = nil
        isLoading = false
        isPlaying = false
        currentMessageID = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [])
        } catch {
            print("AudioSession deactivation error: \(error)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Clean up when playback ends.
        Task { await MainActor.run { self.stopAllInternal() } }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Clean up when system voice finishes.
        Task { await MainActor.run { self.stopAllInternal() } }
    }
}
