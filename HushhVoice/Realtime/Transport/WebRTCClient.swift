import Foundation
import AVFoundation
import LiveKitWebRTC

actor WebRTCClient {
    typealias TransportStream = AsyncThrowingStream<TransportEvent, Error>

    private var factory: LKRTCPeerConnectionFactory?
    private var peer: LKRTCPeerConnection?
    private var dataChannel: LKRTCDataChannel?
    private var localAudioTrack: LKRTCAudioTrack?
    private var delegateProxy: DelegateProxy?
    private var continuation: TransportStream.Continuation?

    func connect(clientSecret: String) -> TransportStream {
        TransportStream { continuation in
            Task {
                await self.startConnection(clientSecret: clientSecret, continuation: continuation)
            }
        }
    }

    func send(json: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(json) else {
            throw TransportError.invalidJSONObject
        }
        guard let dataChannel else {
            throw TransportError.dataChannelUnavailable
        }
        guard dataChannel.readyState == .open else {
            throw TransportError.dataChannelNotOpen
        }

        let data = try JSONSerialization.data(withJSONObject: json)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        dataChannel.sendData(LKRTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func close() async {
        closeConnection(emitDisconnected: true, finishStream: true)
    }

    func setMicEnabled(_ enabled: Bool) async {
        localAudioTrack?.isEnabled = enabled
    }

    private func startConnection(clientSecret: String, continuation: TransportStream.Continuation) {
        closeConnection(emitDisconnected: false, finishStream: true)
        self.continuation = continuation

        do {
            try configureAudioSession()
            try connectWebRTC(clientSecret: clientSecret)
            emit(.stateChanged(.connected))
        } catch {
            emit(.error(error))
            continuation.finish(throwing: error)
            self.continuation = nil
            closeConnection(emitDisconnected: true, finishStream: false)
        }
    }

    private func connectWebRTC(clientSecret: String) throws {
        let proxy = DelegateProxy { event in
            Task { await self.handleDelegateEvent(event) }
        }
        delegateProxy = proxy

        factory = LKRTCPeerConnectionFactory()
        let rtcConfig = LKRTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let peer = factory?.peerConnection(with: rtcConfig, constraints: constraints, delegate: proxy) else {
            throw NSError(domain: "WebRTCClient", code: 10, userInfo: [NSLocalizedDescriptionKey: "PeerConnection failed"])
        }
        self.peer = peer

        let audioSource = factory?.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        guard let audioSource else {
            throw NSError(domain: "WebRTCClient", code: 11, userInfo: [NSLocalizedDescriptionKey: "Audio source failed"])
        }
        let track = factory?.audioTrack(with: audioSource, trackId: "audio0")
        guard let track else {
            throw NSError(domain: "WebRTCClient", code: 12, userInfo: [NSLocalizedDescriptionKey: "Audio track failed"])
        }
        // Align with UI default: mic is OFF until explicitly enabled.
        // This also reduces false server-VAD triggers from ambient/echo at connect time.
        track.isEnabled = false
        localAudioTrack = track
        _ = peer.add(track, streamIds: ["stream0"])

        let dcConfig = LKRTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = peer.dataChannel(forLabel: "oai-events", configuration: dcConfig) else {
            throw NSError(domain: "WebRTCClient", code: 13, userInfo: [NSLocalizedDescriptionKey: "DataChannel failed"])
        }
        dataChannel = dc
        dc.delegate = proxy

        let offer = try makeOffer(peer: peer)
        try setLocalDescription(peer: peer, offer: offer)
        let answerSdp = try postSDPToOpenAI(clientSecret: clientSecret, offerSdp: offer.sdp)
        try setRemoteDescription(peer: peer, answerSdp: answerSdp)
    }

    private func makeOffer(peer: LKRTCPeerConnection) throws -> LKRTCSessionDescription {
        var result: Result<LKRTCSessionDescription, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
            if let error {
                result = .failure(error)
            } else if let sdp {
                result = .success(sdp)
            } else {
                result = .failure(NSError(domain: "WebRTCClient", code: 14, userInfo: [NSLocalizedDescriptionKey: "Offer SDP nil"]))
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try result?.get() ?? {
            throw NSError(domain: "WebRTCClient", code: 15, userInfo: [NSLocalizedDescriptionKey: "Offer generation failed"])
        }()
    }

    private func setLocalDescription(peer: LKRTCPeerConnection, offer: LKRTCSessionDescription) throws {
        var result: Result<Void, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        peer.setLocalDescription(offer) { error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(())
            }
            semaphore.signal()
        }

        semaphore.wait()
        try result?.get()
    }

    private func setRemoteDescription(peer: LKRTCPeerConnection, answerSdp: String) throws {
        let answer = LKRTCSessionDescription(type: .answer, sdp: answerSdp)
        var result: Result<Void, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        peer.setRemoteDescription(answer) { error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(())
            }
            semaphore.signal()
        }

        semaphore.wait()
        try result?.get()
    }

    private func postSDPToOpenAI(clientSecret: String, offerSdp: String) throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/realtime/calls") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.httpBody = offerSdp.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<String, Error>?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                output = .failure(error)
                return
            }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let text = String(data: data, encoding: .utf8) else {
                let message = String(data: data ?? Data(), encoding: .utf8) ?? "Bad response"
                output = .failure(NSError(domain: "WebRTCClient", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: message]))
                return
            }

            output = .success(text)
        }.resume()

        semaphore.wait()
        return try output?.get() ?? {
            throw NSError(domain: "WebRTCClient", code: 16, userInfo: [NSLocalizedDescriptionKey: "SDP exchange failed"])
        }()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            // IMPORTANT: Avoid A2DP for realtime voice. It increases latency and can disable echo cancellation.
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func deactivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func closeConnection(emitDisconnected: Bool, finishStream: Bool) {
        dataChannel?.delegate = nil
        dataChannel?.close()
        dataChannel = nil

        peer?.close()
        peer = nil

        localAudioTrack = nil
        factory = nil
        delegateProxy = nil

        deactivateAudioSession()

        if emitDisconnected {
            emit(.dataChannel(.closed))
            emit(.stateChanged(.disconnected))
        }

        if finishStream {
            continuation?.finish()
            continuation = nil
        }
    }

    private func handleDelegateEvent(_ event: TransportEvent) {
        switch event {
        case .dataChannel(.closed):
            emit(.dataChannel(.closed))
            emit(.stateChanged(.reconnecting))
        case .stateChanged(.disconnected):
            emit(.stateChanged(.reconnecting))
        default:
            emit(event)
        }
    }

    private func emit(_ event: TransportEvent) {
        continuation?.yield(event)
    }
}

private final class DelegateProxy: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    private let onEvent: (TransportEvent) -> Void

    init(onEvent: @escaping (TransportEvent) -> Void) {
        self.onEvent = onEvent
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd rtpReceiver: LKRTCRtpReceiver, streams: [LKRTCMediaStream]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove rtpReceiver: LKRTCRtpReceiver) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        if newState == .disconnected || newState == .failed || newState == .closed {
            onEvent(.stateChanged(.disconnected))
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        if newState == .disconnected || newState == .failed || newState == .closed {
            onEvent(.stateChanged(.disconnected))
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        dataChannel.delegate = self
        onEvent(.dataChannel(.open))
        onEvent(.stateChanged(.connected))
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        switch dataChannel.readyState {
        case .open:
            onEvent(.dataChannel(.open))
            onEvent(.stateChanged(.connected))
        case .closing, .closed:
            onEvent(.dataChannel(.closed))
            onEvent(.stateChanged(.disconnected))
        default:
            break
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didChangeBufferedAmount amount: UInt64) {}

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary else { return }

        if let text = String(data: buffer.data, encoding: .utf8) {
            onEvent(.message(text))
        } else {
            let error = NSError(
                domain: "WebRTCClient",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Failed to decode data channel message as UTF-8"]
            )
            onEvent(.error(error))
        }
    }
}
