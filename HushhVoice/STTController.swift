////
////  STTController.swift
////  HushhVoice
////
////  Created by Akshat Kumar on 18/12/25.
////
//
//import Foundation
//import Speech
//import AVFoundation
//
//@MainActor
//final class STTController: ObservableObject {
//    @Published var transcript: String = ""
//    @Published var isRecording: Bool = false
//
//    private let recognizer: SFSpeechRecognizer?
//    private var audioEngine: AVAudioEngine?
//    private var request: SFSpeechAudioBufferRecognitionRequest?
//    private var task: SFSpeechRecognitionTask?
//
//    init(localeID: String) {
//        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
//    }
//
//    func start() async throws {
//        stop(commit: false) { _ in }
//
//        let session = AVAudioSession.sharedInstance()
//        try session.setCategory(
//            .playAndRecord,
//            mode: .measurement,
//            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
//        )
//        try session.setActive(true, options: [])
//
//        transcript = ""
//        isRecording = true
//
//        let engine = AVAudioEngine()
//        audioEngine = engine
//
//        let req = SFSpeechAudioBufferRecognitionRequest()
//        req.shouldReportPartialResults = true
//        request = req
//
//        let inputNode = engine.inputNode
//        let format = inputNode.outputFormat(forBus: 0)
//
//        inputNode.removeTap(onBus: 0)
//        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
//            self?.request?.append(buffer)
//        }
//
//        engine.prepare()
//        try engine.start()
//
//        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
//            guard let self else { return }
//
//            if let result {
//                Task { @MainActor in
//                    self.transcript = result.bestTranscription.formattedString
//                }
//            }
//
//            if error != nil {
//                Task { @MainActor in
//                    self.stop(commit: true) { _ in }
//                }
//            }
//        }
//    }
//
//    func stop(commit: Bool, onFinal: (String) -> Void) {
//        guard isRecording || audioEngine != nil || task != nil || request != nil else { return }
//
//        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
//
//        if let engine = audioEngine, engine.isRunning {
//            engine.stop()
//        }
//        audioEngine?.inputNode.removeTap(onBus: 0)
//
//        request?.endAudio()
//        task?.cancel()
//
//        audioEngine = nil
//        request = nil
//        task = nil
//
//        isRecording = false
//
//        if commit, !final.isEmpty {
//            onFinal(final)
//        }
//
//        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
//    }
//}
