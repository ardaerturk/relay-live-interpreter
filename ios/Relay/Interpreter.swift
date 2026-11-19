import AVFoundation
import SwiftUI

@MainActor final class Interpreter: ObservableObject {
    @Published var device: Device? = KeyStore.load()
    @Published var target = UserDefaults.standard.string(forKey:"target") == "de" ? "de" : "en" {
        didSet { UserDefaults.standard.set(target,forKey:"target") }
    }
    @Published var phase = "Standby"
    @Published var words = ""
    @Published var notice = ""
    @Published var busy = false
    @Published var pending: Transcript?
    @Published var startDate: Date?
    private var call: AudioCall?, operation: Task<Void,Never>?, deadline: Task<Void,Never>?, reconnect: Task<Void,Never>?
    private var generation: UUID?
    private var observers: [NSObjectProtocol] = []
    var running: Bool { generation != nil }
    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName:AVAudioSession.interruptionNotification, object:nil, queue:.main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.stop("Audio was interrupted. Tap Start when you’re ready.") }
        })
        observers.append(nc.addObserver(forName:AVAudioSession.routeChangeNotification, object:nil, queue:.main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                  let old = n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription,
                  old.outputs.contains(where: { [.headphones,.bluetoothHFP,.bluetoothA2DP,.bluetoothLE,.usbAudio].contains($0.portType) })
            else { return }
            Task { @MainActor in self?.stop("Headphones disconnected. Reconnect them and tap Start.") }
        })
        observers.append(nc.addObserver(forName:AVAudioSession.mediaServicesWereResetNotification, object:nil, queue:.main) { [weak self] _ in
            Task { @MainActor in self?.stop("iOS reset audio. Tap Start to reconnect.") }
        })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func unlock(_ link: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { let d = try await RelayAPI.redeem(link); try KeyStore.save(d); device = d; notice = "" }
        catch { notice = error.localizedDescription }
    }
    func handle(_ error: Error) {
        notice = error.localizedDescription
        if (error as? RelayError)?.status == 401 { KeyStore.forget(); device = nil }
    }
    func start() {
        guard !running, !busy, let device else { return }
        let token = UUID(); generation = token; phase = "Connecting"; words = ""; notice = ""; pending = nil; startDate = nil
        let lang = target
        let audio = AudioCall { [weak self] evt in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.received(evt, token:token)
            }
        }
        call = audio
        limit(after:40, token:token, message:"Connection timed out. Check microphone permission and try again.")
        operation = Task {
            do {
                let allowed = await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning:$0) } }
                try Task.checkCancellation()
                guard allowed else { throw RelayError("Allow the microphone in iPhone Settings, then try again.") }
                try await audio.open(device,target:lang)
            } catch {
                if generation == token { stop(); handle(error) }
            }
        }
    }
    private func limit(after seconds: Int, token: UUID, message: String) {
        deadline?.cancel(); deadline = Task {
            do { try await Task.sleep(nanoseconds:UInt64(seconds)*1_000_000_000) } catch { return }
            if generation == token { stop(message) }
        }
    }
    private func received(_ e: AudioCall.Event, token: UUID) {
        switch e {
        case .connected:
            reconnect?.cancel(); phase = "Listening"
            if startDate == nil { startDate = Date(); limit(after:1200,token:token,message:"20 minutes reached. Start again to continue.") }
        case .reconnecting:
            phase = "Reconnecting"; reconnect?.cancel(); reconnect = Task {
                do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }
                if generation == token { stop("Network connection lost. Tap Start to reconnect.") }
            }
        case .caption(let text): words += text
        case .ended(let message): stop(message)
        }
    }
    func checkDuration() { if let startDate, running && Date().timeIntervalSince(startDate) >= 1200 { stop("20 minutes reached. Start again to continue.") } }
    func stop(_ message: String = "") {
        guard generation != nil else { return }
        generation = nil; operation?.cancel(); deadline?.cancel(); reconnect?.cancel(); call?.close()
        operation = nil; deadline = nil; reconnect = nil; call = nil
        if let date = startDate, !words.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let ms = Int64(date.timeIntervalSince1970*1000)
            pending = Transcript(id:"\(ms).\(UUID().uuidString.lowercased())",startedAt:ms,
                seconds:min(86400,max(0,Int(Date().timeIntervalSince(date).rounded()))),target:target,text:words)
        }
        phase = "Standby"; startDate = nil; notice = message
    }
    func save() async {
        guard let item = pending, let device, !busy else { return }
        busy = true; defer { busy = false }
        do { try await RelayAPI.save(device,item); pending = nil; notice = "Saved to History." }
        catch { handle(error) }
    }
}
