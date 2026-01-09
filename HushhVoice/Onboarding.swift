//
//  Onboarding.swift
//  HushhVoice
//
//  Minimal “Orb + Mute” Kai Voice Mode (Realtime WebRTC)
//
//  ✅ metasidd/Orb animated orb
//  ✅ hushh_quiet_logo mute button (small + low)
//  ✅ Waveform under orb (mic level)
//  ✅ Real speech-to-speech via OpenAI Realtime over WebRTC
//  ✅ Echo cancellation via AVAudioSession voiceChat
//
//  Dependencies:
//  - LiveKit WebRTC XCFramework: https://github.com/livekit/webrtc-xcframework (module: LiveKitWebRTC)
//  - Orb package: https://github.com/metasidd/Orb.git (module: Orb)
//
//  Backend endpoints expected:
//  - GET {backendBase}/onboarding/agent/config
//  - POST {backendBase}/onboarding/agent/token
//
//  Backend JSON envelope expected (your jok()):
//  { "ok": true, "data": { "instructions": "...", "tools": [...], "realtime": { "turn_detection": {...} }, "kickoff": { "response": {...} } } }
//
//  Notes:
//  - This file avoids Decodable generics; uses JSONSerialization.
//  - Remote audio plays automatically via WebRTC.
//  - Data channel is used for session.update + debugging states.
//  - Mic mute disables local track + mic meter.
//

import SwiftUI
import Foundation
import AVFoundation
import LiveKitWebRTC
import Orb

// ======================================================
// MARK: - Mic Level Monitor (for waveform)
// ======================================================

final class MicLevelMonitor: ObservableObject {
    @Published var level: CGFloat

    private static let idleLevel: CGFloat = 0.06
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var smoothedLevel: CGFloat

    init() {
        self.level = Self.idleLevel
        self.smoothedLevel = Self.idleLevel
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            var sum: Float = 0
            for i in 0..<frames { sum += channelData[i] * channelData[i] }
            let rms = sqrt(sum / Float(frames))

            // Normalize -> 0...1 (tune if needed)
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true, options: [])
            engine.prepare()
            try engine.start()
        } catch {
            print("MicLevelMonitor start error:", error)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async {
            self.level = Self.idleLevel
        }
    }

    func setMuted(_ muted: Bool) {
        if muted { stop() } else { start() }
    }
}

// ======================================================
// MARK: - UI State
// ======================================================

enum OrbState {
    case connecting
    case listening
    case speaking
    case muted
    case error
}

// ======================================================
// MARK: - Onboarding Screen
// ======================================================

struct Onboarding: View {

    @Environment(\.dismiss) private var dismiss
    @AppStorage("hushh_apple_user_id") private var appleUserID: String = ""
    @AppStorage("hushh_kai_user_id") private var kaiUserID: String = ""

    @StateObject private var vm = KaiVoiceViewModel()
    @StateObject private var micMonitor = MicLevelMonitor()
    @State private var resolvedUserID: String = ""

    private func resolveUserID() -> String {
        if !appleUserID.isEmpty { return appleUserID }
        if !kaiUserID.isEmpty { return kaiUserID }
        let newID = UUID().uuidString
        kaiUserID = newID
        return newID
    }

    var body: some View {
        ZStack {
            HVTheme.bg.ignoresSafeArea()

            // Subtle premium radial accent
            RadialGradient(
                colors: [HVTheme.accent.opacity(0.18), Color.clear],
                center: .center,
                startRadius: 30,
                endRadius: 520
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 14) {

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kai")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(HVTheme.botText.opacity(0.95))

                        Text(vm.subtitle)
                            .font(.footnote)
                            .foregroundStyle(HVTheme.botText.opacity(0.6))
                    }

                    Spacer()

                    Button {
                        vm.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(10)
                            .background(Circle().fill(HVTheme.surfaceAlt))
                            .overlay(Circle().stroke(HVTheme.stroke))
                    }
                    .foregroundStyle(HVTheme.botText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                // Orb (metasidd/Orb) — replaces any old blob
                KaiOrb(configuration: vm.orbConfiguration, size: 270)
                    .padding(.bottom, 6)

                // Waveform (mic amplitude) — matches screenshot vibe
                WaveformView(level: micMonitor.level, isMuted: vm.isMuted, accent: HVTheme.accent)
                    .padding(.horizontal, 24)
                    .opacity(vm.state == .connecting ? 0.6 : 1.0)

                // Quiet button smaller + lower (like the reference)
                QuietMicButtonSmall(isMuted: $vm.isMuted) {
                    vm.setMuted(vm.isMuted)
                }
                .disabled(vm.state == .connecting)

                if let err = vm.errorText {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                Spacer()

                Text(vm.footerText)
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.55))
                    .padding(.bottom, 14)
            }
        }
        .onAppear {
            micMonitor.start()
            micMonitor.setMuted(vm.isMuted)
            let id = resolveUserID()
            resolvedUserID = id
            vm.start(userId: id)
        }
        .onDisappear {
            micMonitor.stop()
            vm.stop()
        }
        .onChange(of: vm.isMuted) { muted in
            micMonitor.setMuted(muted)
        }
    }
}

// ======================================================
// MARK: - Orb (metasidd/Orb wrapper)
// ======================================================

private struct KaiOrb: View {
    let configuration: OrbConfiguration
    let size: CGFloat

    var body: some View {
        OrbView(configuration: configuration)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 14)
    }
}

// ======================================================
// MARK: - Waveform View (Canvas)
// ======================================================

private struct WaveformView: View {
    var level: CGFloat
    var isMuted: Bool
    var accent: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let idle = 0.07 + 0.03 * sin(t * 1.3)
            let amp = max(0.04, isMuted ? idle : level)
            let speed = isMuted ? 1.25 : 2.4

            Canvas { context, size in
                let midY = size.height / 2
                let width = size.width
                let base = midY * amp

                let phases: [CGFloat] = [0.0, 0.85, 1.7]
                let weights: [CGFloat] = [1.0, 0.62, 0.38]

                for idx in 0..<phases.count {
                    let phase = CGFloat(t) * speed + phases[idx]
                    let amplitude = base * weights[idx]
                    let path = wavePath(width: width, midY: midY, amplitude: amplitude, phase: phase)

                    let opacity = isMuted ? 0.20 + (weights[idx] * 0.18) : 0.46 + (weights[idx] * 0.46)
                    let color = accent.opacity(opacity)

                    // soft glow layer
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 6))
                        layer.opacity = isMuted ? 0.25 : 0.50
                        layer.stroke(path, with: .color(color), lineWidth: 5)
                    }
                    // crisp stroke
                    context.stroke(path, with: .color(color), lineWidth: 2.6)
                }
            }
            .frame(height: 90)
        }
        .allowsHitTesting(false)
    }

    private func wavePath(width: CGFloat, midY: CGFloat, amplitude: CGFloat, phase: CGFloat) -> Path {
        var path = Path()
        let points = 70
        for i in 0...points {
            let x = CGFloat(i) / CGFloat(points) * width
            let relative = CGFloat(i) / CGFloat(points)
            let sine = sin(relative * .pi * 2 + phase)
            let envelope = sin(relative * .pi)
            let y = midY + sine * amplitude * envelope
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// ======================================================
// MARK: - Quiet Mic Button (small + low)
// ======================================================

private struct QuietMicButtonSmall: View {
    @Binding var isMuted: Bool
    var onToggle: () -> Void

    @State private var pulse = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                isMuted.toggle()
                onToggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(HVTheme.surfaceAlt.opacity(isMuted ? 0.80 : 1.0))
                    .overlay(Circle().stroke(HVTheme.stroke.opacity(isMuted ? 0.9 : 0.55), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)

                Circle()
                    .stroke(HVTheme.accent.opacity(isMuted ? 0.16 : 0.40), lineWidth: isMuted ? 1 : 2)
                    .scaleEffect(isMuted ? 1.02 : (pulse ? 1.16 : 1.05))
                    .opacity(isMuted ? 0.30 : (pulse ? 0.80 : 0.45))
                    .blur(radius: isMuted ? 0.6 : 2.0)
                    .animation(isMuted ? .none : .easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: pulse)

                Image("hushh_quiet_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .opacity(isMuted ? 0.85 : 1.0)

                if isMuted {
                    Circle()
                        .fill(Color.red.opacity(0.92))
                        .frame(width: 9, height: 9)
                        .offset(x: 18, y: -18)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                }
            }
            .frame(width: 62, height: 62) // smaller like reference
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
    }
}

// ======================================================
// MARK: - ViewModel (Realtime WebRTC)
// ======================================================

final class KaiVoiceViewModel: NSObject, ObservableObject {

    @Published var state: OrbState = .connecting
    @Published var isMuted: Bool = false
    @Published var errorText: String? = nil

    // Orb “mood” configuration
    @Published var orbConfiguration: OrbConfiguration = KaiVoiceViewModel.makeOrbConfig(state: .connecting, energy: 0.5)

    // Use your shared app base URL
    private let backendBase: URL = HushhAPI.base
    // If you want hardcoded:
    // private let backendBase: URL = URL(string: "https://YOUR_BACKEND")!
    private var userId: String = ""

    // WebRTC
    private var factory: LKRTCPeerConnectionFactory?
    private var peer: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var localAudioTrack: LKRTCAudioTrack?

    // Config from backend
    private var instructions: String = ""
    private var tools: [[String: Any]] = []
    private var turnDetection: [String: Any] = [:]
    private var kickoffResponse: [String: Any] = [:]
    private var hasSentSessionUpdate = false

    // Small speaking detection
    private var speakingHoldTask: Task<Void, Never>?

    var subtitle: String {
        switch state {
        case .connecting: return "Connecting…"
        case .listening: return isMuted ? "Muted" : "Listening"
        case .speaking: return "Kai is speaking"
        case .muted: return "Muted"
        case .error: return "Connection error"
        }
    }

    var footerText: String {
        switch state {
        case .connecting:
            return "Bringing Kai online…"
        case .error:
            return "Couldn’t connect. Try again."
        default:
            return isMuted ? "Mic muted." : "Kai is live. Speak anytime."
        }
    }

    func start(userId: String) {
        stop()
        self.userId = userId

        DispatchQueue.main.async {
            self.state = .connecting
            self.errorText = nil
            self.orbConfiguration = Self.makeOrbConfig(state: .connecting, energy: 0.5)
        }

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try self.configureAudioSession()

                try await self.fetchConfig()
                let clientSecret = try await self.fetchClientSecret()

                try await self.connectWebRTC(clientSecret: clientSecret)

                await MainActor.run {
                    self.state = self.isMuted ? .muted : .listening
                    self.orbConfiguration = Self.makeOrbConfig(state: self.state, energy: 0.55)
                }
            } catch {
                await MainActor.run {
                    self.state = .error
                    self.errorText = error.localizedDescription
                    self.orbConfiguration = Self.makeOrbConfig(state: .error, energy: 0.3)
                }
            }
        }
    }

    func stop() {
        speakingHoldTask?.cancel()
        speakingHoldTask = nil

        hasSentSessionUpdate = false

        dataChannel?.close()
        dataChannel = nil

        peer?.close()
        peer = nil

        localAudioTrack = nil
        factory = nil
    }

    func setMuted(_ muted: Bool) {
        if isMuted != muted { isMuted = muted }

        localAudioTrack?.isEnabled = !muted

        if state != .error && state != .connecting {
            state = muted ? .muted : .listening
            orbConfiguration = Self.makeOrbConfig(state: state, energy: muted ? 0.35 : 0.55)
        }
    }

    // ------------------------------------------------------
    // Backend: /onboarding/agent/config
    // ------------------------------------------------------

    private func fetchConfig() async throws {
        var url = backendBase.appendingPathComponent("/onboarding/agent/config")
        if !userId.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "user_id", value: userId)]
            if let updated = components.url { url = updated }
        }
        let (data, resp) = try await URLSession.shared.data(from: url)

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "KaiConfig", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Config error"
            ])
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any]
        else {
            throw NSError(domain: "KaiConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad config JSON"])
        }

        self.instructions = (dataObj["instructions"] as? String) ?? ""

        if let rawTools = dataObj["tools"] as? [[String: Any]] {
            self.tools = rawTools
        } else if let rawAny = dataObj["tools"] as? [Any] {
            self.tools = rawAny.compactMap { $0 as? [String: Any] }
        } else {
            self.tools = []
        }

        if let realtime = dataObj["realtime"] as? [String: Any],
           let td = realtime["turn_detection"] as? [String: Any] {
            self.turnDetection = td
        } else {
            self.turnDetection = [:]
        }

        if let kickoff = dataObj["kickoff"] as? [String: Any],
           let respObj = kickoff["response"] as? [String: Any] {
            self.kickoffResponse = respObj
        } else {
            self.kickoffResponse = [:]
        }
    }

    // ------------------------------------------------------
    // Backend: /onboarding/agent/token
    // ------------------------------------------------------

    private func fetchClientSecret() async throws -> String {
        let url = backendBase.appendingPathComponent("/onboarding/agent/token")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": "gpt-4o-realtime-preview"]
        if !userId.isEmpty {
            body["user_id"] = userId
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "KaiToken", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Token error"
            ])
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let dataObj = root["data"] as? [String: Any],
            let secret = dataObj["client_secret"] as? String,
            !secret.isEmpty
        else {
            throw NSError(domain: "KaiToken", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad token JSON"])
        }

        return secret
    }

    // ------------------------------------------------------
    // WebRTC: connect to OpenAI Realtime
    // ------------------------------------------------------

    private func connectWebRTC(clientSecret: String) async throws {
        factory = LKRTCPeerConnectionFactory()

        let rtcConfig = LKRTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan

        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let peer = factory?.peerConnection(with: rtcConfig, constraints: constraints, delegate: self) else {
            throw NSError(domain: "WebRTC", code: 10, userInfo: [NSLocalizedDescriptionKey: "PeerConnection failed"])
        }
        self.peer = peer

        // Local audio track
        let audioSource = factory!.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory!.audioTrack(with: audioSource, trackId: "audio0")
        self.localAudioTrack = audioTrack
        audioTrack.isEnabled = !isMuted
        _ = peer.add(audioTrack, streamIds: ["stream0"])

        // Data channel
        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = peer.dataChannel(forLabel: "oai-events", configuration: dcConfig) else {
            throw NSError(domain: "WebRTC", code: 11, userInfo: [NSLocalizedDescriptionKey: "DataChannel failed"])
        }
        self.dataChannel = dc
        dc.delegate = self

        // Create offer
        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LKRTCSessionDescription, Error>) in
            peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let sdp = sdp else {
                    cont.resume(throwing: NSError(domain: "WebRTC", code: 12, userInfo: [NSLocalizedDescriptionKey: "Offer SDP nil"]))
                    return
                }
                cont.resume(returning: sdp)
            }
        }

        // Set local
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: ())
            }
        }

        // Exchange SDP with OpenAI
        let answerSdp = try await postOfferToOpenAI(clientSecret: clientSecret, offerSdp: offer.sdp)

        let answer = LKRTCSessionDescription(type: .answer, sdp: answerSdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(answer) { err in
                if let err = err { cont.resume(throwing: err); return }
                cont.resume(returning: ())
            }
        }
    }

    private func postOfferToOpenAI(clientSecret: String, offerSdp: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/realtime/calls") else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        req.httpBody = offerSdp.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "OpenAIRealtime", code: 20, userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "SDP exchange error"
            ])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    // ------------------------------------------------------
    // AEC: Audio session
    // ------------------------------------------------------

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try session.setActive(true, options: [])
    }

    // ------------------------------------------------------
    // DataChannel helpers
    // ------------------------------------------------------

    private func sendEvent(_ obj: [String: Any]) {
        guard let dc = dataChannel, dc.readyState == .open else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        dc.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    private func sendSessionUpdateOnce() {
        guard !hasSentSessionUpdate else { return }
        guard !instructions.isEmpty else { return }

        hasSentSessionUpdate = true

        var session: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": instructions,
            "tools": tools
        ]
        if let td = sanitizedTurnDetection() {
            session["turn_detection"] = td
        }

        sendEvent([
            "type": "session.update",
            "session": session
        ])

        sendEvent([
            "type": "response.create",
            "response": kickoffResponse.isEmpty
            ? [
                "modalities": ["audio", "text"],
                "instructions": "Hi, I’m Kai. Let’s begin. Before we talk about investing, what does your net worth look like and how is it split across assets?"
              ]
            : kickoffResponse
        ])
    }

    private func sanitizedTurnDetection() -> [String: Any]? {
        guard !turnDetection.isEmpty else { return nil }
        var td = turnDetection

        if let raw = td["threshold"] {
            let doubleValue: Double?
            switch raw {
            case let num as NSNumber:
                doubleValue = num.doubleValue
            case let str as String:
                doubleValue = Double(str)
            default:
                doubleValue = nil
            }

            if let value = doubleValue {
                let rounded = (value * 1e16).rounded() / 1e16
                td["threshold"] = rounded
            } else {
                td.removeValue(forKey: "threshold")
            }
        }

        return td.isEmpty ? nil : td
    }

    private func handleToolCallEvent(_ obj: [String: Any]) {
        guard !userId.isEmpty else { return }

        let callId = (obj["call_id"] as? String)
            ?? (obj["id"] as? String)
            ?? (obj["call"] as? [String: Any])?["id"] as? String
        let toolName = (obj["name"] as? String)
            ?? (obj["tool_name"] as? String)
            ?? (obj["call"] as? [String: Any])?["name"] as? String

        guard let callId, let toolName else { return }

        let arguments: Any
        if let argsDict = obj["arguments"] as? [String: Any] {
            arguments = argsDict
        } else if let argsArray = obj["arguments"] as? [Any] {
            arguments = argsArray
        } else if let argsString = obj["arguments"] as? String,
                  let data = argsString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) {
            arguments = json
        } else if let argsString = obj["arguments"] as? String {
            arguments = ["raw": argsString]
        } else {
            arguments = [:]
        }

        Task.detached { [weak self] in
            await self?.forwardToolCall(callId: callId, toolName: toolName, arguments: arguments)
        }
    }

    private func forwardToolCall(callId: String, toolName: String, arguments: Any) async {
        guard !userId.isEmpty else { return }
        let url = backendBase.appendingPathComponent("/onboarding/agent/tool")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "user_id": userId,
            "tool_name": toolName,
            "arguments": arguments
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Tool error"
                sendEvent([
                    "type": "response.function_call_output",
                    "call_id": callId,
                    "output": ["error": msg]
                ])
                return
            }

            let output: Any
            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let dict = json as? [String: Any], let inner = dict["output"] {
                    output = inner
                } else {
                    output = json
                }
            } else {
                output = String(data: data, encoding: .utf8) ?? ""
            }

            sendEvent([
                "type": "response.function_call_output",
                "call_id": callId,
                "output": output
            ])
        } catch {
            sendEvent([
                "type": "response.function_call_output",
                "call_id": callId,
                "output": ["error": error.localizedDescription]
            ])
        }
    }

    private func markSpeakingPulse() {
        guard !isMuted else { return }

        if state != .speaking {
            state = .speaking
            orbConfiguration = Self.makeOrbConfig(state: .speaking, energy: 0.85)
        }

        speakingHoldTask?.cancel()
        speakingHoldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s hold
            if self.state == .speaking {
                self.state = self.isMuted ? .muted : .listening
                self.orbConfiguration = Self.makeOrbConfig(state: self.state, energy: self.isMuted ? 0.35 : 0.55)
            }
        }
    }

    // Orb config mapping
    static func makeOrbConfig(state: OrbState, energy: Double) -> OrbConfiguration {
        // Blue/purple like reference
        let bg: [Color] = [.purple, .blue, .indigo]
        let glow = Color.white

        let speed: Double
        let core: Double

        switch state {
        case .connecting:
            speed = 22
            core = 0.8
        case .listening:
            speed = 45
            core = 1.0
        case .speaking:
            speed = 90
            core = 1.6
        case .muted:
            speed = 18
            core = 0.6
        case .error:
            speed = 10
            core = 0.4
        }

        return OrbConfiguration(
            backgroundColors: bg,
            glowColor: glow,
            coreGlowIntensity: core * energy,
            showBackground: true,
            showWavyBlobs: true,
            showParticles: true,
            showGlowEffects: true,
            showShadow: true,
            speed: speed
        )
    }
}

// ======================================================
// MARK: - LKRTCPeerConnectionDelegate
// ======================================================

extension KaiVoiceViewModel: LKRTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        self.dataChannel = dataChannel
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        // Remote audio plays automatically through WebRTC once connected.
    }
}

// ======================================================
// MARK: - LKRTCDataChannelDelegate
// ======================================================

extension KaiVoiceViewModel: LKRTCDataChannelDelegate {

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.readyState == .open {
            DispatchQueue.main.async {
                self.state = self.isMuted ? .muted : .listening
                self.orbConfiguration = Self.makeOrbConfig(state: self.state, energy: self.isMuted ? 0.35 : 0.55)
            }
            sendSessionUpdateOnce()
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary else { return }
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }

        let type = (obj["type"] as? String) ?? ""

        // Mark speaking based on response activity (best-effort)
        if type.hasPrefix("response.") && type.contains("delta") {
            DispatchQueue.main.async { self.markSpeakingPulse() }
        }

        if type.contains("function_call_arguments.done") || type.contains("tool_call_arguments.done") {
            handleToolCallEvent(obj)
        }

        if type == "error" {
            let errMsg = (obj["error"] as? [String: Any])?["message"] as? String
            if let errMsg, errMsg.contains("turn_detection.threshold") || errMsg.contains("max decimal places") {
                return
            }
            DispatchQueue.main.async {
                self.state = .error
                self.errorText = errMsg ?? "Realtime error"
                self.orbConfiguration = Self.makeOrbConfig(state: .error, energy: 0.35)
            }
        }
    }
}
