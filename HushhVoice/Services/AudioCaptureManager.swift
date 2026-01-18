import AVFoundation
import Foundation
import Speech

// Audio capture + on-device speech recognition for chat voice input.
final class AudioCaptureManager: ObservableObject {
    static let shared = AudioCaptureManager()

    @Published private(set) var isCapturing: Bool = false
    @Published var isMuted: Bool = true
    @Published var lastError: String?

    var onAudioChunk: ((Data) -> Void)?
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var didStartSpeech = false
    private var didFinalize = false
    private var lastTranscript: String = ""
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 1.4
    private let debugLogging = true
    private var pausedForPlayback = false

    private init() {}

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            stopCapture()
        } else {
            startCapture()
        }
    }

    func startCapture() {
        guard !isCapturing else { return }
        lastError = nil
        didStartSpeech = false
        didFinalize = false
        lastTranscript = ""
        silenceTimer?.invalidate()
        silenceTimer = nil
        debugLog("startCapture")

        requestMicPermission { [weak self] micGranted in
            guard let self else { return }
            guard micGranted else {
                self.lastError = "Microphone permission denied."
                self.debugLog("mic permission denied")
                self.isMuted = true
                return
            }

            guard AudioSessionCoordinator.shared.configureIfNeeded() else {
                self.lastError = "Audio session not available."
                self.debugLog("startCapture failed: audio session")
                self.isMuted = true
                return
            }

            self.requestSpeechPermission { [weak self] authorized in
                guard let self else { return }
                guard authorized else {
                    self.lastError = "Speech recognition permission denied."
                    self.debugLog("speech permission denied")
                    self.isMuted = true
                    return
                }

                self.beginRecognition()
            }
        }
    }

    func stopCapture() {
        guard isCapturing else { return }
        debugLog("stopCapture")
        isCapturing = false
        onSpeechEnd?()
        silenceTimer?.invalidate()
        silenceTimer = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    func pauseCaptureForPlayback() {
        guard isCapturing else { return }
        pausedForPlayback = true
        debugLog("pauseCaptureForPlayback")
        isCapturing = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    func resumeCaptureAfterPlayback() {
        guard !isMuted else { return }
        guard !isCapturing else { return }
        guard pausedForPlayback else { return }
        pausedForPlayback = false
        debugLog("resumeCaptureAfterPlayback")
        startCapture()
    }

    private func beginRecognition() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            lastError = "Speech recognizer unavailable."
            debugLog("speech recognizer unavailable")
            isMuted = true
            return
        }

        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.requiresOnDeviceRecognition = false

        guard let request = recognitionRequest else {
            lastError = "Speech request unavailable."
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lastTranscript = text
                if !self.didStartSpeech {
                    self.didStartSpeech = true
                    self.onSpeechStart?()
                    self.debugLog("speech started")
                }
                self.onPartialTranscript?(text)
                if result.isFinal {
                    self.handleFinalTranscript(text)
                } else {
                    self.resetSilenceTimer()
                }
            }
            if let error {
                let nsError = error as NSError
                let message = nsError.localizedDescription.lowercased()
                let speechErrorDomain = "SFSpeechRecognizerErrorDomain"
                let isCancelled = (nsError.domain == speechErrorDomain && nsError.code == 216)
                    || message.contains("cancel")
                    || message.contains("no speech")
                if isCancelled {
                    self.debugLog("speech cancelled")
                    self.stopCapture()
                    return
                }
                self.debugLog("speech error: \(nsError.localizedDescription)")
                self.lastError = nsError.localizedDescription
                self.stopCapture()
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            try audioEngine.start()
            isCapturing = true
            debugLog("audioEngine started")
        } catch {
            lastError = error.localizedDescription
            debugLog("audioEngine start failed: \(error.localizedDescription)")
        }
    }

    private func requestMicPermission(completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            completion(true)
        case .undetermined:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    private func requestSpeechPermission(completion: @escaping (Bool) -> Void) {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { auth in
                DispatchQueue.main.async {
                    completion(auth == .authorized)
                }
            }
        default:
            completion(false)
        }
    }

    private func debugLog(_ msg: String) {
        guard debugLogging else { return }
        print("🎙️ [AudioCapture] \(msg)")
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard !self.didFinalize, !self.lastTranscript.isEmpty else { return }
            self.debugLog("silence timeout finalizing")
            self.handleFinalTranscript(self.lastTranscript)
        }
        silenceTimer = timer
    }

    private func handleFinalTranscript(_ text: String) {
        guard !didFinalize else { return }
        didFinalize = true
        debugLog("speech final: \(text)")
        onFinalTranscript?(text)
        stopCapture()
    }
}
