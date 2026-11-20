import Foundation

// Numeric counters only. Input transcript text and microphone audio are never retained here.
struct MediaSample {
    var captureTime: Double?, inputEnergy: Double?, sent: Double?
    var receiveTime: Double?, outputEnergy: Double?, playoutTime: Double?
}

struct StreamHealth {
    enum Fault: String {
        case statistics = "The audio connection stopped reporting."
        case capture = "The microphone stopped delivering audio."
        case uplink = "Microphone audio stopped uploading."
        case playback = "Translated audio stopped playing."
        case untranslated = "Speech is coming in without a translation."
    }
    private(set) var captureConfirmed = false
    private(set) var inputAt: Double?, outputAt: Double?, captionAt: Double?
    private var previous: MediaSample?, sampledAt: Double?, captureAt: Double?, sentAt: Double?, playoutAt: Double?
    private var pendingInput: [Double] = [], pendingCaptions: [Double] = []
    private var sawReceiveEnergy = false, sawPlayout = false
    let began: Double
    init(at time: Double) { began = time }

    mutating func caption(at t: Double) {
        captionAt = t
        // Count separated intervals, not individual tokens.
        if t - (pendingCaptions.last ?? -100) >= 1 { pendingCaptions.append(t) }
        if pendingCaptions.count > 60 { pendingCaptions.removeFirst() }
        pendingInput.removeAll()
    }
    mutating func input(at t: Double) {
        inputAt = t
        if t - (pendingInput.last ?? -100) >= 0.8 { pendingInput.append(t) }
        if pendingInput.count > 60 { pendingInput.removeFirst() }
    }
    // Compute RMS across the whole polling interval; one instantaneous audioLevel can miss a sentence.
    private func voiced(_ a: Double?, _ b: Double?, _ elapsed: Double?, floor: Double) -> Bool {
        guard let a, let b, let elapsed, elapsed > 0 else { return false }
        return a - b > floor * floor * elapsed
    }
    @discardableResult mutating func sample(_ s: MediaSample, at t: Double) -> Bool {
        let delta = max(0.01, t - (sampledAt ?? t))
        defer { previous = s; sampledAt = t }
        sawReceiveEnergy = sawReceiveEnergy || s.outputEnergy != nil
        sawPlayout = sawPlayout || s.playoutTime != nil
        guard let p = previous else { return false }
        func advance(_ a: Double?, _ b: Double?) -> Bool { a != nil && b != nil && a! > b! }
        let sending = advance(s.sent,p.sent)
        if sending { sentAt = t }
        if advance(s.captureTime,p.captureTime) || (s.captureTime == nil && sending) {
            captureAt = t; captureConfirmed = true
        }
        if advance(s.playoutTime,p.playoutTime) { playoutAt = t }
        if voiced(s.inputEnergy,p.inputEnergy,s.captureTime.flatMap { v in p.captureTime.map { v - $0 } } ?? delta, floor:0.006) { input(at:t) }
        let sound = voiced(s.outputEnergy,p.outputEnergy,s.receiveTime.flatMap { v in p.receiveTime.map { v - $0 } } ?? delta, floor:0.003)
        if sound { outputAt = t; pendingInput.removeAll(); pendingCaptions.removeAll() }
        return sound
    }
    func awaiting(_ t: Double) -> Bool {
        let active = pendingInput.filter { t - $0 < 32 }
        return active.count >= 2 && t - active[0] >= 7
    }
    func fault(at t: Double, allowAmbiguous: Bool) -> Fault? {
        if t - (sampledAt ?? began) > 10 { return .statistics }
        if t - (captureAt ?? began) > 10, previous?.captureTime != nil || previous?.sent != nil { return .capture }
        let speech = pendingInput.filter { t - $0 < 32 }
        if previous?.sent != nil, t - (sentAt ?? began) > 9, speech.count >= 3 { return .uplink }
        // Transcripts without received sound, or decoded sound with a frozen device playout counter.
        if sawPlayout, let out = outputAt, t - out < 3, t - (playoutAt ?? began) > 10 { return .playback }
        let caps = pendingCaptions.filter { t - $0 < 26 }
        if caps.count >= 2, t - caps[0] > 10, t - caps.last! < 18,
           sawReceiveEnergy || outputAt == nil { return .playback }
        // The model may legitimately ignore its target language. Allow just one speculative
        // recovery until there is actual translated output; quiet by itself never triggers one.
        if allowAmbiguous, speech.count >= 2, t - speech[0] >= 13 { return .untranslated }
        return nil
    }
}

struct RetryBudget {
    private(set) var consecutive = 0, total = 0
    private(set) var ambiguousAllowed = true
    mutating func translated() { consecutive = 0; ambiguousAllowed = true }
    mutating func next(ambiguous: Bool = false) -> Double? {
        guard consecutive < 4, total < 8, !ambiguous || ambiguousAllowed else { return nil }
        if ambiguous { ambiguousAllowed = false }
        let delay: Double = [1, 3, 8, 16][consecutive]
        consecutive += 1; total += 1
        return delay
    }
}
