import AVFoundation
import WebRTC

// WebRTC owns the audio unit. Keep one real duplex audio session during a call; no silent playback
// or background timers are used to hold the app open. Signaling is the only audio-related HTTP call.
final class AudioCall: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, RTCAudioSessionDelegate, RelayTransport {
    enum Event { case connected, channelOpen, reconnecting, audioDevice(Bool), input, caption(String), sample(MediaSample), ended(String), rejected(String) }
    private let event: (Event) -> Void
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var mic: RTCAudioTrack?
    init(factory makeFactory: () -> RTCPeerConnectionFactory = { RTCPeerConnectionFactory() }, event: @escaping (Event) -> Void) {
        self.event = event
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(config)
        factory = makeFactory()
        super.init()
    }
    @MainActor func open(_ device: Device, target: String) async throws {
        try Task.checkCancellation()
        let cfg = RTCConfiguration(); cfg.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints:nil, optionalConstraints:nil)
        guard let p = factory.peerConnection(with:cfg, constraints:constraints, delegate:self) else {
            throw RelayError("Could not open the audio connection.")
        }
        peer = p
        RTCAudioSession.sharedInstance().add(self)
        let track = factory.audioTrack(with:factory.audioSource(with:constraints), trackId:"microphone")
        mic = track
        guard p.add(track, streamIds:["relay"]) != nil,
              let ch = p.dataChannel(forLabel:"oai-events", configuration:RTCDataChannelConfiguration()) else {
            throw RelayError("Could not open the microphone or captions.")
        }
        channel = ch; ch.delegate = self
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
            p.offer(for:constraints) { sdp,e in
                if let sdp { c.resume(returning:sdp) } else { c.resume(throwing:e ?? RelayError("No audio offer.")) }
            }
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.setLocalDescription(offer) { e in if let e { c.resume(throwing:e) } else { c.resume() } }
        }
        try Task.checkCancellation()
        let answer = try await RelayAPI.connect(device, target:target, sdp:offer.sdp)
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.setRemoteDescription(RTCSessionDescription(type:.answer,sdp:answer)) { e in
                if let e { c.resume(throwing:e) } else { c.resume() }
            }
        }
    }
    @MainActor func close() {
        RTCAudioSession.sharedInstance().remove(self)
        mic?.isEnabled = false; channel?.delegate = nil; peer?.delegate = nil
        channel?.close(); peer?.close(); mic = nil; channel = nil; peer = nil
    }
    @MainActor func poll() {
        let emit = event
        peer?.statistics { report in
            var s = MediaSample()
            for row in report.statistics.values {
                let v = row.values
                if let kind = v["kind"] as? String, kind != "audio" { continue }
                func n(_ key: String) -> Double? { (v[key] as? NSNumber)?.doubleValue }
                switch row.type {
                case "media-source": s.captureTime = n("totalSamplesDuration"); s.inputEnergy = n("totalAudioEnergy")
                case "outbound-rtp": s.sent = n("packetsSent")
                case "inbound-rtp": s.receiveTime = n("totalSamplesDuration"); s.outputEnergy = n("totalAudioEnergy")
                case "media-playout": s.playoutTime = n("totalSamplesDuration")
                default: break
                }
            }
            emit(.sample(s))
        }
    }
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) { event(.audioDevice(true)) }
    func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) { event(.audioDevice(false)) }
    func audioSession(_ session: RTCAudioSession, audioUnitStartFailedWithError error: Error) {
        event(.ended("iOS could not start the microphone or headphones."))
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected: event(.connected)
        case .disconnected: event(.reconnecting)
        case .closed, .failed: event(.ended("The audio connection dropped."))
        default: break
        }
    }
    func dataChannelDidChangeState(_ channel: RTCDataChannel) {
        if channel.readyState == .open { event(.channelOpen) }
        if channel.readyState == .closed { event(.ended("The interpreter disconnected.")) }
    }
    func dataChannel(_ channel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let obj = try? JSONSerialization.jsonObject(with:buffer.data) as? [String:Any] else { return }
        switch obj["type"] as? String {
        case "session.output_transcript.delta": if let s = obj["delta"] as? String { event(.caption(s)) }
        case "session.input_transcript.delta": if let s = obj["delta"] as? String, !s.isEmpty { event(.input) }
        case "error":
            let detail = obj["error"] as? [String:Any]
            let type = detail?["type"] as? String, code = detail?["code"] as? String ?? ""
            if type == "authentication_error" || ["invalid_api_key","permission_denied","insufficient_quota","model_not_found"].contains(code) {
                event(.rejected("The interpreter rejected this session. Start a new session to try again."))
            } else { event(.ended("The translation service interrupted the stream.")) }
        case "session.closed": event(.ended("The translation service closed the stream."))
        default: break
        }
    }
}


protocol RelayTransport: AnyObject {
    @MainActor func open(_ device: Device, target: String) async throws
    @MainActor func close()
    @MainActor func poll()
}
