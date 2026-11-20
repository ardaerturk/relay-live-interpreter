import AVFoundation
import Network
import SwiftUI
import UIKit

enum ListeningPhase: String {
    case idle = "Ready", permission = "Microphone access", connecting = "Connecting"
    case listening = "Listening", hearing = "Hearing speech", translating = "Translating"
    case quiet = "Waiting for speech", waiting = "Waiting for translation", recovering = "Reconnecting", offline = "Waiting for internet"
    var symbol: String {
        switch self {
        case .idle: return "headphones"
        case .permission: return "mic"
        case .connecting, .recovering: return "arrow.triangle.2.circlepath"
        case .offline: return "wifi.slash"
        case .waiting: return "ellipsis.bubble"
        case .quiet: return "ear"
        case .listening, .hearing: return "waveform"
        case .translating: return "waveform.and.mic"
        }
    }
}

@MainActor final class Interpreter: ObservableObject {
    typealias Factory = (@escaping (AudioCall.Event) -> Void) -> RelayTransport
    @Published var device: Device?
    @Published var target = UserDefaults.standard.string(forKey:"target") == "de" ? "de" : "en" {
        didSet { UserDefaults.standard.set(target,forKey:"target") }
    }
    @Published private(set) var phase: ListeningPhase = .idle
    @Published var words = ""
    @Published var notice = ""
    @Published var busy = false
    @Published private(set) var pending: Transcript?
    @Published private(set) var startDate: Date?
    @Published private(set) var lastSpeech: Date?
    @Published private(set) var lastAudio: Date?
    @Published private(set) var lastCaption: Date?
    @Published private(set) var recoveries = 0
    @Published private(set) var reason = ""
    @Published private(set) var mic = "—"
    @Published private(set) var headphones = "—"
    @Published private(set) var volume = 0
    var canReconnect: Bool { call != nil && permitted && online }
    var running: Bool { session != nil }

    private let factory: Factory, permission: () async -> Bool, now: () -> Double
    private var monitor: NWPathMonitor?, observers: [NSObjectProtocol] = []
    private var session: UUID?, attempt: UUID?, call: RelayTransport?
    private var operation: Task<Void,Never>?, timer: Task<Void,Never>?
    private var budget = RetryBudget(), health = StreamHealth(at:0)
    private var permitted = false, online = true, connected = false, channelOpen = false, pollPending = false
    private var requestedAt = 0.0, opening = 0.0, lastOpen = -100.0
    private var due: Double?, lostAt: Double?, offlineAt: Double?, deviceStoppedAt: Double?
    private var paragraph = false, repaired = false, manualClock: Bool
    private var graceTask: UIBackgroundTaskIdentifier = .invalid

    init(device: Device? = KeyStore.load(), factory: @escaping Factory = { AudioCall(event:$0) },
         permission: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, systemEvents: Bool = true) {
        self.device = device; self.factory = factory; self.permission = permission; self.now = now
        manualClock = !systemEvents
        guard systemEvents else { return }
        let nw = NWPathMonitor(); monitor = nw
        nw.pathUpdateHandler = { [weak self] path in
            let available = path.status != .unsatisfied
            Task { @MainActor in self?.network(available) }
        }
        nw.start(queue:DispatchQueue(label:"Relay.network"))
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName:AVAudioSession.interruptionNotification, object:nil, queue:.main) { [weak self] n in
            guard (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stop("Another app took over audio. Tap Start when you’re ready.") }
        })
        observers.append(nc.addObserver(forName:AVAudioSession.routeChangeNotification, object:nil, queue:.main) { [weak self] n in
            let old = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let removed = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            let privatePorts: [AVAudioSession.Port] = [.headphones,.bluetoothHFP,.bluetoothA2DP,.bluetoothLE,.usbAudio]
            let lostPrivate = removed && old?.outputs.contains(where: { privatePorts.contains($0.portType) }) == true
            Task { @MainActor in
                self?.updateRoute()
                if lostPrivate { self?.stop("Headphones disconnected. Reconnect them and tap Start.") }
            }
        })
        observers.append(nc.addObserver(forName:AVAudioSession.mediaServicesWereResetNotification, object:nil, queue:.main) { [weak self] _ in
            Task { @MainActor in self?.retry("iOS restarted its audio service.") }
        })
    }
    deinit { monitor?.cancel(); for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func updateRoute() {
        let audio = AVAudioSession.sharedInstance()
        volume = Int((audio.outputVolume * 100).rounded())
        let r = audio.currentRoute
        mic = r.inputs.first?.portName ?? "No active input"; headphones = r.outputs.first?.portName ?? "No active output"
    }
    func unlock(_ link: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { let d = try await RelayAPI.redeem(link); try KeyStore.save(d); device = d; notice = "" }
        catch { notice = error.localizedDescription }
    }
    func handle(_ error: Error) {
        notice = error.localizedDescription
        if (error as? RelayError)?.status == 401 { stop(error.localizedDescription); KeyStore.forget(); device = nil }
    }
    func start() {
        guard !running, !busy, device != nil else { return }
        let id = UUID(); session = id; permitted = false; requestedAt = now(); lastOpen = -100
        budget = RetryBudget(); words = ""; notice = ""; pending = nil; startDate = nil
        lastSpeech = nil; lastAudio = nil; lastCaption = nil; recoveries = 0; reason = ""; paragraph = false; repaired = false
        phase = .permission
        if !manualClock {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for:.seconds(1))
                    guard !Task.isCancelled, let self, self.session == id else { return }
                    self.tick()
                }
            }
        }
        operation = Task { [weak self] in
            guard let self, !Task.isCancelled, self.session == id else { return }
            let ok = await self.permission()
            guard self.session == id else { return }
            guard ok else { self.stop("Allow microphone access in iPhone Settings to start listening."); return }
            self.permitted = true
            if self.online { self.open() } else { self.phase = .offline; self.due = self.now() }
        }
    }
    private func open() {
        guard let session, let device, permitted, online, call == nil else { return }
        let id = UUID(); attempt = id; opening = now(); lastOpen = opening; due = nil
        health = StreamHealth(at:opening); connected = false; channelOpen = false; pollPending = false; lostAt = nil; deviceStoppedAt = nil
        phase = recoveries == 0 ? .connecting : .recovering
        let audio = factory { [weak self] e in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == session, self.attempt == id else { return }
                self.received(e)
            }
        }
        call = audio; let lang = target
        operation = Task { [weak self] in
            guard !Task.isCancelled, self?.attempt == id else { return }
            do { try await audio.open(device,target:lang) }
            catch {
                guard let self, self.session == session, self.attempt == id else { return }
                let e = error as? RelayError
                if let e, (400..<500).contains(e.status) && ![408,409,425,429].contains(e.status) ||
                   e.message.contains("starts for today") || e.message.contains("not been configured") {
                    self.stop(e.message); self.handle(e)
                } else {
                    self.retry(error.localizedDescription, minimum:e?.status == 429 ? 8 : 0)
                }
            }
        }
    }
    private func received(_ e: AudioCall.Event) {
        let t = now()
        switch e {
        case .connected:
            let first = !connected && lostAt == nil
            if first { health = StreamHealth(at:t) }
            connected = true; lostAt = nil; updateRoute()
        case .audioDevice(let active):
            if active { deviceStoppedAt = nil }
            else { deviceStoppedAt = deviceStoppedAt ?? t; if connected { phase = .recovering } }
        case .channelOpen: channelOpen = true
        case .reconnecting: if lostAt == nil { lostAt = t }; phase = online ? .recovering : .offline
        case .input: health.input(at:t); lastSpeech = Date()
        case .caption(let delta):
            guard !delta.isEmpty else { return }
            if paragraph { if !words.isEmpty { words += "\n\n" }; paragraph = false }
            words += delta; lastCaption = Date()
            if delta.rangeOfCharacter(from:.alphanumerics) != nil { health.caption(at:t) }
        case .sample(let sample):
            pollPending = false
            if health.sample(sample,at:t) { lastAudio = Date(); budget.translated() }
            if health.inputAt == t { lastSpeech = Date() }
        case .ended(let why): retry(why); return
        case .rejected(let why): stop(why); return
        }
        status(at:t)
    }
    private func status(at t: Double) {
        guard connected, channelOpen, health.captureConfirmed, lostAt == nil, deviceStoppedAt == nil, online else { return }
        if startDate == nil { startDate = Date() }
        endGrace()
        if repaired { repaired = false; notice = "Audio reconnected. Speech during the gap may be missing." }
        if let out = health.outputAt, t - out < 3 { phase = .translating }
        else if health.awaiting(t) { phase = .waiting }
        else if let speech = health.inputAt, t - speech < 3 { phase = .hearing }
        else if t - (health.inputAt ?? health.outputAt ?? health.began) >= 15 { phase = .quiet }
        else { phase = .listening }
    }
    func network(_ available: Bool) {
        let wasOnline = online; online = available
        guard running, permitted, wasOnline != available else { return }
        if !available { offlineAt = now(); phase = .offline }
        else {
            offlineAt = nil
            if call == nil { due = max(due ?? now(),lastOpen + 7) }
            else if lostAt != nil { phase = .recovering }
            else { phase = .connecting; status(at:now()) }
            tick()
        }
    }
    // Also called immediately after the phone unlocks: suspended timers do not replay missed ticks.
    func tick() {
        guard running else { return }
        let t = now()
        if t - requestedAt >= 1200 || (startDate.map { Date().timeIntervalSince($0) >= 1200 } ?? false) {
            stop("20 minutes reached. Start again to continue."); return
        }
        guard permitted else { return }
        if !online {
            phase = .offline
            if call != nil, t - (offlineAt ?? t) >= 4 { retry("The internet connection dropped.") }
            return
        }
        if let due, t >= due { open(); return }
        guard let call else { return }
        if let lostAt, t - lostAt >= 4 { retry("The network stopped carrying audio."); return }
        if let stopped = deviceStoppedAt, t - stopped >= 4 { retry("iOS stopped the microphone or audio playback."); return }
        if !connected || !channelOpen {
            if t - opening >= 32 { retry("The interpreter did not finish connecting.") }
            return
        }
        if let fault = health.fault(at:t, allowAmbiguous:budget.ambiguousAllowed) {
            retry(fault.rawValue, ambiguous:fault == .untranslated); return
        }
        if !health.captureConfirmed, t - opening >= 16 { retry("The microphone did not start."); return }
        if !pollPending { pollPending = true; call.poll() }
        status(at:t)
    }
    func reconnect() { guard canReconnect else { return }; retry("You requested a fresh audio connection.") }
    private func retry(_ why: String, ambiguous: Bool = false, minimum: Double = 0) {
        guard running, permitted, call != nil else { return }
        beginGrace()
        detach()
        guard let delay = budget.next(ambiguous:ambiguous) else {
            stop("Audio could not be restored. Your transcript is still here. Tap Start to try again."); return
        }
        recoveries = budget.total; reason = why; paragraph = true; repaired = true; notice = ""
        due = max(now() + max(delay, minimum),lastOpen + 7)
        phase = online ? .recovering : .offline
    }
    private func beginGrace() {
        guard !manualClock, graceTask == .invalid else { return }
        graceTask = UIApplication.shared.beginBackgroundTask(withName:"Restore live translation") { [weak self] in
            Task { @MainActor in self?.endGrace() }
        }
    }
    private func endGrace() {
        if graceTask != .invalid { UIApplication.shared.endBackgroundTask(graceTask); graceTask = .invalid }
    }
    private func detach() {
        attempt = nil; operation?.cancel(); operation = nil
        call?.close(); call = nil; lostAt = nil; pollPending = false
    }
    func stop(_ message: String = "") {
        guard session != nil else { return }
        session = nil; timer?.cancel(); timer = nil; due = nil; offlineAt = nil; permitted = false
        detach(); endGrace()
        if let date = startDate ?? (words.isEmpty ? nil : Date()), !words.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let ms = Int64(date.timeIntervalSince1970*1000)
            pending = Transcript(id:"\(ms).\(UUID().uuidString.lowercased())",startedAt:ms,
                seconds:min(1200,max(0,Int(Date().timeIntervalSince(date).rounded()))),target:target,text:words)
        }
        phase = .idle; startDate = nil; notice = message
    }
    func save() async {
        guard let item = pending, let device, !busy else { return }
        busy = true; defer { busy = false }
        do { try await RelayAPI.save(device,item); pending = nil; notice = "Saved to History." }
        catch { handle(error) }
    }
}
