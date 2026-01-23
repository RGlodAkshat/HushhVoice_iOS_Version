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
    private var autoRestartAfterFinal = false
    private var isStarting = false
    private var lastPartialLogAt: Date?

    private init() {}

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            dbg("AudioCapture", "muted")
            stopCapture()
        } else {
            dbg("AudioCapture", "unmuted")
            startCapture()
        }
    }

    func startCapture() {
        guard !isCapturing, !isStarting else { return }
        isStarting = true
        dbg("AudioCapture", "start_request")
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
                self.dbg("AudioCapture", "mic_permission_denied")
                self.isStarting = false
                return
            }

            guard AudioSessionCoordinator.shared.configureIfNeeded() else {
                self.lastError = "Audio session not available."
                self.debugLog("startCapture failed: audio session")
                self.isMuted = true
                self.dbg("AudioCapture", "audio_session_failed")
                self.isStarting = false
                return
            }

            self.requestSpeechPermission { [weak self] authorized in
                guard let self else { return }
                guard authorized else {
                    self.lastError = "Speech recognition permission denied."
                    self.debugLog("speech permission denied")
                    self.isMuted = true
                    self.dbg("AudioCapture", "speech_permission_denied")
                    self.isStarting = false
                    return
                }

                self.beginRecognition()
            }
        }
    }

    func stopCapture() {
        isStarting = false
        guard isCapturing else { return }
        debugLog("stopCapture")
        dbg("AudioCapture", "stop")
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
        pausedForPlayback = true
        debugLog("pauseCaptureForPlayback")
        dbg("AudioCapture", "pause_for_playback")
        guard isCapturing else { return }
        isCapturing = false
        isStarting = false
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
        dbg("AudioCapture", "resume_after_playback")
        startCapture()
    }

    func setAutoRestartAfterFinal(_ enabled: Bool) {
        autoRestartAfterFinal = enabled
    }

    private func beginRecognition() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            lastError = "Speech recognizer unavailable."
            debugLog("speech recognizer unavailable")
            dbg("AudioCapture", "speech_unavailable")
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
            isStarting = false
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
                    self.dbg("AudioCapture", "speech_started")
                }
                self.onPartialTranscript?(text)
                self.logPartialIfNeeded(text)
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
                    self.dbg("AudioCapture", "speech_cancelled", fields: ["code": nsError.code, "domain": nsError.domain])
                    self.stopCapture()
                    return
                }
                self.debugLog("speech error: \(nsError.localizedDescription)")
                self.dbg("AudioCapture", "speech_error", message: nsError.localizedDescription, fields: ["code": nsError.code, "domain": nsError.domain])
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
            isStarting = false
            debugLog("audioEngine started")
            dbg("AudioCapture", "engine_started", fields: audioSessionFields())
        } catch {
            lastError = error.localizedDescription
            debugLog("audioEngine start failed: \(error.localizedDescription)")
            dbg("AudioCapture", "engine_failed", message: error.localizedDescription)
            isStarting = false
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
        dbg("AudioCapture", "speech_final", fields: ["len": text.count])
        onFinalTranscript?(text)
        stopCapture()
        if autoRestartAfterFinal && !isMuted && !pausedForPlayback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startCapture()
            }
        }
    }

    private func logPartialIfNeeded(_ text: String) {
        let now = Date()
        if let last = lastPartialLogAt, now.timeIntervalSince(last) < 0.3 {
            return
        }
        lastPartialLogAt = now
        dbg("AudioCapture", "speech_partial", fields: ["len": text.count])
    }

    private func audioSessionFields() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)(\($0.portName))" }.joined(separator: ",")
        return [
            "sample_rate": session.sampleRate,
            "in_ch": session.inputNumberOfChannels,
            "out_ch": session.outputNumberOfChannels,
            "inputs": inputs,
            "outputs": outputs,
            "mode": session.mode.rawValue,
        ]
    }

    private func dbg(_ component: String, _ event: String, message: String? = nil, fields: [String: Any] = [:]) {
        DebugLogger.shared.log(
            component: component,
            event: event,
            message: message,
            fields: fields,
            sessionId: nil,
            turnId: nil,
            messageId: nil
        )
    }
}
