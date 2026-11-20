import SwiftUI
import WebRTC

@main struct RelayApp: App {
    @StateObject private var model = Interpreter()
    @Environment(\.scenePhase) private var scene
    init() { RTCInitializeSSL() }
    var body: some Scene {
        WindowGroup { InterpreterView(model:model).onChange(of:scene) { _, next in
            if next == .active { model.updateRoute(); model.tick() }
        } }
    }
}

struct InterpreterView: View {
    @ObservedObject var model: Interpreter
    @State private var invite = ""
    @State private var history = false
    @State private var details = false
    @State private var discardPrompt = false
    @ScaledMetric(relativeTo:.largeTitle) private var symbolSize = 48
    var body: some View {
        NavigationStack {
            Group {
                if model.device == nil {
                    Form {
                        Section {
                            SecureField("Invite link",text:$invite).keyboardType(.URL).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().privacySensitive()
                            Button("Unlock this device") { Task { await model.unlock(invite); if model.device != nil { invite = "" } } }
                                .disabled(model.busy || invite.isEmpty)
                        } header: { Label("Device invite",systemImage:"envelope") }
                        footer: { Text("Paste the private invitation for this iPhone.") }
                        if !model.notice.isEmpty { Text(model.notice).foregroundStyle(.secondary) }
                    }
                } else {
                    ScrollView {
                        VStack(alignment:.leading,spacing:26) {
                            VStack(alignment:.leading,spacing:10) {
                                HStack {
                                    Label(model.phase.rawValue,systemImage:model.phase.symbol)
                                        .font(.headline).foregroundStyle(statusColor)
                                    Spacer()
                                    if let date = model.startDate {
                                        Text(date,style:.timer).font(.subheadline.monospacedDigit())
                                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                    }
                                }
                                Text(statusDetail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            }
                            Divider()
                            if model.words.isEmpty {
                                VStack(spacing:12) {
                                    Image(systemName:"quote.opening").font(.system(size:symbolSize,weight:.regular))
                                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                                    Text("Live transcript").font(.title2.weight(.semibold))
                                    Text("Translated words appear here as people speak.")
                                        .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                }.frame(maxWidth:.infinity).padding(.vertical,36)
                            } else {
                                VStack(alignment:.leading,spacing:12) {
                                    HStack {
                                        Text("Live transcript").font(.headline); Spacer()
                                        if model.pending != nil {
                                            Button("Save",systemImage:"square.and.arrow.down") { Task { await model.save() } }.disabled(model.busy)
                                        }
                                    }
                                    Text(model.words).font(.title3).lineSpacing(5).textSelection(.enabled).privacySensitive()
                                }
                            }
                            if !model.notice.isEmpty {
                                Label(model.notice,systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal,24).padding(.vertical,12).frame(maxWidth:620)
                        .frame(maxWidth:.infinity)
                    }
                    .safeAreaInset(edge:.bottom,spacing:0) { controls }
                }
            }
            .navigationTitle("Interpreter")
            .toolbar {
                if model.device != nil {
                    ToolbarItem(placement:.topBarTrailing) { Button("History",systemImage:"clock.arrow.circlepath") { history = true } }
                    ToolbarItem(placement:.topBarTrailing) {
                        Menu("Session options",systemImage:"ellipsis") {
                            Button("Audio details",systemImage:"waveform") { model.updateRoute(); details = true }
                            if model.running { Button("Reconnect audio",systemImage:"arrow.clockwise") { model.reconnect() }.disabled(!model.canReconnect) }
                        }
                    }
                }
            }
            .sheet(isPresented:$history) { if let d = model.device {
                HistoryView(device:d,onUnauthorized:{ history = false; model.handle($0) })
            } }
            .sheet(isPresented:$details) { AudioDetails(model:model).presentationDetents([.medium,.large]) }
            .confirmationDialog("Start without saving this transcript?",isPresented:$discardPrompt,titleVisibility:.visible) {
                Button("Start new session",role:.destructive) { model.start() }
                Button("Cancel",role:.cancel) {}
            }
        }
    }
    private var statusColor: Color {
        switch model.phase {
        case .recovering,.offline,.waiting: return .orange
        case .listening,.hearing,.translating: return .accentColor
        default: return .primary
        }
    }
    private var statusDetail: String {
        switch model.phase {
        case .idle: return "Choose what you want to hear."
        case .permission: return "Checking microphone access on this iPhone."
        case .connecting: return "Opening the microphone and audio connection."
        case .offline: return "Translation is paused. Relay will reconnect when internet returns."
        case .recovering: return "Restoring audio. Speech during the gap may be missed."
        case .waiting: return "Sound is coming in without a translation. Speech already in the selected language may be skipped."
        case .quiet: return "No recent speech detected on \(model.mic). Move the microphone closer to the speaker."
        case .listening: return "The microphone is open. You can lock your iPhone."
        case .hearing: return "The microphone is picking up sound."
        case .translating: return "Receiving translated audio."
        }
    }
    private var controls: some View {
        VStack(spacing:14) {
            HStack {
                Text("Listen in").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Picker("Listen in",selection:$model.target) { Text("English").tag("en"); Text("German").tag("de") }
                    .pickerStyle(.segmented).frame(maxWidth:230).disabled(model.running || model.busy)
            }
            if #available(iOS 26, *) {
                action.buttonStyle(.glassProminent)
            } else {
                action.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal,24).padding(.vertical,12).frame(maxWidth:620).frame(maxWidth:.infinity)
        .background(.background)
    }
    private var action: some View {
        Button {
            if model.running { model.stop() } else if model.pending != nil { discardPrompt = true } else { model.start() }
        } label: {
            Label(model.running ? "Stop listening" : "Start listening",systemImage:model.running ? "stop.fill" : "mic.fill")
                .font(.headline).frame(maxWidth:.infinity).padding(.vertical,3)
        }.controlSize(.large).tint(model.running ? .red : .accentColor).disabled(model.busy && !model.running)
    }
}

private struct AudioDetails: View {
    @ObservedObject var model: Interpreter
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Audio route") {
                    LabeledContent("Microphone",value:model.mic)
                    LabeledContent("Output",value:model.headphones)
                    LabeledContent("Volume",value:"\(model.volume)%")
                }
                Section("This session") {
                    LabeledContent("Speech detected",value:time(model.lastSpeech))
                    LabeledContent("Translated audio received",value:time(model.lastAudio))
                    LabeledContent("Transcript updated",value:time(model.lastCaption))
                    LabeledContent("Reconnect attempts",value:String(model.recoveries))
                    if !model.reason.isEmpty { Text(model.reason).foregroundStyle(.secondary) }
                }
                Section {
                    LabeledContent("Relay version",value:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")
                }
            }.navigationTitle("Audio details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func time(_ d: Date?) -> String { d?.formatted(date:.omitted,time:.standard) ?? "—" }
}

struct HistoryView: View {
    let device: Device
    let onUnauthorized: (Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Transcript] = []
    @State private var next: String?
    @State private var selected: Transcript?
    @State private var message = ""
    @State private var busy = false
    @State private var deletePrompt = false
    var body: some View {
        NavigationStack {
            Group {
                if let t = selected {
                    ScrollView { VStack(alignment:.leading,spacing:14) {
                        Text(t.date.formatted()).font(.subheadline).foregroundStyle(.secondary)
                        Text(t.text ?? "").textSelection(.enabled).privacySensitive()
                        Button("Delete transcript",role:.destructive) { deletePrompt = true }.disabled(busy)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding() }
                } else {
                    List {
                        ForEach(items) { item in
                            Button { Task { await open(item) } } label: {
                                VStack(alignment:.leading,spacing:4) { Text(item.language + " translation")
                                    Text(item.date.formatted()).font(.caption).foregroundStyle(.secondary) }
                            }.disabled(busy)
                        }
                        if next != nil { Button("Show more") { Task { await load(more:true) } }.disabled(busy) }
                        if !busy && items.isEmpty && message.isEmpty { Text("No saved transcripts. After listening, tap Save.").foregroundStyle(.secondary) }
                    }
                }
            }
            .safeAreaInset(edge:.bottom) { if busy { ProgressView().padding() } else if !message.isEmpty { Text(message).font(.callout).padding() } }
            .navigationTitle(selected?.language ?? "History").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selected != nil { ToolbarItem(placement:.topBarLeading) { Button("All transcripts") { selected = nil; message = "" }.disabled(busy) } }
                ToolbarItem(placement:.topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await load(more:false) }
            .confirmationDialog("Delete this transcript from your account?",isPresented:$deletePrompt,titleVisibility:.visible) {
                Button("Delete permanently",role:.destructive) { Task { await remove() } }
                Button("Cancel",role:.cancel) {}
            }
        }
    }
    private func failed(_ e: Error) { message = e.localizedDescription; if (e as? RelayError)?.status == 401 { onUnauthorized(e) } }
    @MainActor private func load(more: Bool) async {
        guard !busy else { return }; busy = true; message = ""; defer { busy = false }
        do { let p = try await RelayAPI.history(device,after:more ? next : nil); items = more ? items+p.items : p.items; next = p.next }
        catch { failed(error) }
    }
    @MainActor private func open(_ item: Transcript) async {
        guard !busy else { return }; busy = true; message = ""; defer { busy = false }
        do { selected = try await RelayAPI.read(device,item.id) } catch { failed(error) }
    }
    @MainActor private func remove() async {
        guard !busy, let item = selected else { return }; busy = true; message = ""; defer { busy = false }
        do { try await RelayAPI.delete(device,item.id); selected = nil; items.removeAll { $0.id == item.id } } catch { failed(error) }
    }
}
