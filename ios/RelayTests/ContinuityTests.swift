import XCTest
import SwiftUI
import UIKit
@testable import Relay

final class ContinuityTests: XCTestCase {
    private func frame(_ t: Double, speech: Bool = false, output: Bool = false) -> MediaSample {
        MediaSample(captureTime:t,inputEnergy:speech ? t*0.01 : 0,sent:50*t,receiveTime:t,outputEnergy:output ? t*0.01 : 0,playoutTime:t)
    }
    func testSilenceAndOrdinaryPausesAreHealthy() {
        var h = StreamHealth(at:0)
        for i in 0...150 {
            let t = Double(i)
            var s = frame(t)
            s.outputEnergy = (i > 3 ? 0.05 : 0) + (i > 43 ? 0.05 : 0)
            h.sample(s,at:t)
            if i == 3 || i == 43 { h.input(at:t); h.caption(at:t) }
            XCTAssertNil(h.fault(at:t,allowAmbiguous:true))
        }
        XCTAssertTrue(h.captureConfirmed)
    }
    func testFrozenMicrophoneAndFrozenStatisticsEvenThoughPeerIsConnected() {
        var h = StreamHealth(at:0)
        for i in 0...13 {
            var s = frame(Double(i)); s.captureTime = min(1,Double(i))
            h.sample(s,at:Double(i))
        }
        XCTAssertEqual(h.fault(at:13,allowAmbiguous:true),.capture)
        XCTAssertEqual(h.fault(at:25,allowAmbiguous:true),.statistics)
    }
    func testSpeechWithoutUplinkAndSpeechWithoutTranslation() {
        for uplink in [true,false] {
            var h = StreamHealth(at:0)
            for i in 0...15 {
                let t = Double(i); var s = frame(t,speech:true); if !uplink { s.sent = 0 }
                h.sample(s,at:t)
            }
            XCTAssertTrue(h.awaiting(15))
            XCTAssertEqual(h.fault(at:15,allowAmbiguous:true),uplink ? .untranslated : .uplink)
            if uplink { XCTAssertNil(h.fault(at:15,allowAmbiguous:false)) }
        }
    }
    func testCaptionsCannotHideSilentAudioAndReceivedAudioCannotHideFrozenPlayout() {
        for decoded in [false,true] {
            var h = StreamHealth(at:0)
            for i in 0...14 {
                let t = Double(i); var s = frame(t,output:decoded); s.playoutTime = 0
                h.sample(s,at:t); if i == 1 { h.caption(at:t) }
            }
            XCTAssertEqual(h.fault(at:14,allowAmbiguous:true),.playback)
        }
    }
    func testFreshSpeechAfterACompletedSentenceCanTriggerOneRecovery() {
        var h = StreamHealth(at:0), b = RetryBudget()
        for i in 0...22 {
            let t = Double(i); var s = frame(t)
            s.outputEnergy = i >= 2 ? 0.05 : 0
            h.sample(s,at:t)
            if i == 5 || i == 6 { h.input(at:t) }
        }
        XCTAssertEqual(h.fault(at:22,allowAmbiguous:b.ambiguousAllowed),.untranslated)
        XCTAssertNotNil(b.next(ambiguous:true))
        XCTAssertNil(h.fault(at:22,allowAmbiguous:b.ambiguousAllowed))
        b.translated(); XCTAssertTrue(b.ambiguousAllowed)
    }

    @MainActor private final class FakeTransport: RelayTransport {
        let emit: (AudioCall.Event) -> Void
        var closed = false, polls = 0
        var failure: Error?
        init(_ cb: @escaping (AudioCall.Event) -> Void) { emit = cb }
        func open(_ device: Device,target: String) async throws { if let failure { throw failure } }
        func close() { closed = true }
        func poll() { polls += 1 }
    }
    @MainActor private final class Rig {
        var time = 100.0, peers: [FakeTransport] = []
        var failure: Error?
        lazy var model: Interpreter = Interpreter(device:Device(origin:URL(string:"https://example.invalid")!,cookie:""),
            factory:{ [unowned self] cb in let p = FakeTransport(cb); p.failure = failure; peers.append(p); return p },
            permission:{ true },now:{ [unowned self] in time },systemEvents:false)
        func flush() async {
            for _ in 0..<4 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
        }
        func begin() async { model.start(); await flush() }
        func move(_ delta: Double) async { time += delta; model.tick(); await flush() }
        func media() async {
            let p = peers.last!; p.emit(.connected); p.emit(.channelOpen)
            p.emit(.sample(MediaSample(captureTime:1,sent:50))); await flush()
            time += 1; p.emit(.sample(MediaSample(captureTime:2,sent:100))); await flush()
        }
    }

    @MainActor func testKeepsOneTranscriptAcrossRecoveryIgnoresReplacedPeerAndStopWins() async {
        let r = Rig(); await r.begin(); let first = r.peers[0]
        first.emit(.connected); await r.flush(); XCTAssertNotEqual(r.model.phase,.listening)
        await r.media(); XCTAssertEqual(r.model.phase,.listening)
        first.emit(.caption("First sentence.")); await r.flush(); let started = r.model.startDate
        first.emit(.ended("Peer failed")); first.emit(.ended("Duplicate callback")); await r.flush()
        XCTAssertTrue(first.closed); XCTAssertEqual(r.model.recoveries,1); XCTAssertEqual(r.model.phase,.recovering)
        await r.move(6); XCTAssertEqual(r.peers.count,2); await r.media()
        first.emit(.caption("stale")); first.emit(.ended("late failure"))
        r.peers[1].emit(.caption("Second sentence.")); await r.flush()
        XCTAssertEqual(r.model.words,"First sentence.\n\nSecond sentence."); XCTAssertEqual(r.model.startDate,started)
        r.peers[1].emit(.ended("Another interruption")); await r.flush(); r.model.stop()
        await r.move(40); XCTAssertEqual(r.peers.count,2); XCTAssertFalse(r.model.running)
        XCTAssertEqual(r.model.pending?.text,"First sentence.\n\nSecond sentence.")
    }
    @MainActor func testTransientHandoverDoesNotReplaceHealthyConnectionAndOfflineDoesNotSpendRetries() async {
        let r = Rig(); await r.begin(); await r.media(); let p = r.peers[0]
        p.emit(.reconnecting); await r.flush(); r.model.network(false); await r.move(2)
        r.model.network(true); p.emit(.connected); await r.flush()
        XCTAssertEqual(r.peers.count,1); XCTAssertEqual(r.model.phase,.listening)
        r.model.network(false); await r.move(5); await r.move(90)
        XCTAssertEqual(r.peers.count,1); XCTAssertEqual(r.model.phase,.offline)
        r.model.network(true); await r.flush(); XCTAssertEqual(r.peers.count,2)
        r.model.stop()
    }
    @MainActor func testSystemAudioPauseCanRecoverInPlaceOrTriggerNewAudioEvenWithCaptions() async {
        let r = Rig(); await r.begin(); await r.media(); let p = r.peers[0]
        p.emit(.audioDevice(false)); await r.flush(); XCTAssertEqual(r.model.phase,.recovering)
        p.emit(.audioDevice(true)); await r.flush(); XCTAssertEqual(r.model.phase,.listening)
        p.emit(.audioDevice(false)); p.emit(.caption("Still connected.")); await r.flush()
        await r.move(5); XCTAssertTrue(p.closed); XCTAssertEqual(r.model.recoveries,1)
        await r.move(2); XCTAssertEqual(r.peers.count,2); r.model.stop()
    }
    @MainActor func testPermanentRateLimitAndBackoffBound() async {
        let r = Rig(); r.failure = RelayError("This device has reached its 20 session starts for today (UTC).",status:429)
        await r.begin(); await r.move(100); XCTAssertFalse(r.model.running); XCTAssertEqual(r.peers.count,1)
        let b = Rig(); b.failure = RelayError("Temporary network error",status:502); await b.begin()
        for _ in 0..<8 { await b.move(30) }
        XCTAssertFalse(b.model.running); XCTAssertEqual(b.peers.count,5)
        var budget = RetryBudget()
        for _ in 0..<8 { XCTAssertNotNil(budget.next()); budget.translated() }
        XCTAssertNil(budget.next())
    }
    @MainActor func testNativeSessionAppearance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let r = Rig()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene:scene)
        let host = UIHostingController(rootView:InterpreterView(model:r.model))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { r.model.stop(); window.isHidden = true; previous?.makeKeyAndVisible() }
        for mode in ["Ready","Conversation"] {
            if mode == "Conversation" {
                window.overrideUserInterfaceStyle = .dark
                await r.begin(); await r.media()
                r.peers[0].emit(.caption("The next train leaves for Berlin at eight. My blue backpack is on the table."))
                await r.flush()
            } else { window.overrideUserInterfaceStyle = .light }
            try await Task.sleep(for:.milliseconds(350))
            window.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds:window.bounds)
            let image = renderer.image { _ in
                XCTAssertTrue(window.drawHierarchy(in:window.bounds,afterScreenUpdates:true))
            }
            let file = XCTAttachment(image:image); file.name = "Relay " + mode; file.lifetime = .keepAlways; add(file)
        }
    }
    @MainActor func testStopDuringPermissionAndDeadlineDuringOutageNeverReopenMic() async {
        var p: CheckedContinuation<Bool,Never>?, opens = 0
        let m = Interpreter(device:Device(origin:URL(string:"https://example.invalid")!,cookie:""),
            factory:{ cb in opens += 1; return FakeTransport(cb) },permission:{ await withCheckedContinuation { p = $0 } },
            systemEvents:false)
        m.start(); let r = Rig(); await r.flush(); m.stop(); p?.resume(returning:true); await r.flush(); XCTAssertEqual(opens,0)
        await r.begin(); await r.media(); r.model.network(false); await r.move(1201); r.model.network(true)
        XCTAssertFalse(r.model.running); XCTAssertEqual(r.peers.count,1)
    }
}
