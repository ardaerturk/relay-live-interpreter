import SwiftUI
import WebRTC

@main struct RelayApp: App {
    @StateObject private var model = Interpreter()
    @Environment(\.scenePhase) private var scene
    init() { RTCInitializeSSL() }
    var body: some Scene {
        WindowGroup { InterpreterView(model:model).onChange(of:scene) { _, next in if next == .active { model.checkDuration() } } }
    }
}

struct InterpreterView: View {
    @ObservedObject var model: Interpreter
    @State private var invite = ""
    @State private var history = false
    @State private var discardPrompt = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    if model.device == nil {
                        Image(systemName:"headphones").font(.largeTitle).accessibilityHidden(true)
                        Text("Device invite").font(.title2.bold())
                        Text("Paste the private link for this iPhone.").foregroundStyle(.secondary)
                        SecureField("Invite link",text:$invite).keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled().textFieldStyle(.roundedBorder).privacySensitive()
                        Button("Unlock this device") { Task { await model.unlock(invite); if model.device != nil { invite = "" } } }
                            .buttonStyle(.borderedProminent).disabled(model.busy || invite.isEmpty)
                    } else {
                        HStack {
                            Label(model.phase,systemImage:model.running ? "waveform" : "circle").font(.headline)
                            Spacer()
                            if let date = model.startDate { Text(date,style:.timer).monospacedDigit().multilineTextAlignment(.trailing) }
                        }
                        VStack(alignment:.leading, spacing:8) {
                            Text("Listen in").font(.subheadline).foregroundStyle(.secondary)
                            Picker("Listen in",selection:$model.target) { Text("English").tag("en"); Text("German").tag("de") }
                                .pickerStyle(.segmented).disabled(model.running || model.busy)
                        }
                        Button {
                            if model.running { model.stop() } else if model.pending != nil { discardPrompt = true } else { model.start() }
                        } label: {
                            Label(model.phase == "Connecting" ? "Cancel" : model.running ? "Stop listening" : "Start listening",
                                  systemImage:model.running ? "stop.fill" : "headphones")
                                .font(.headline).frame(maxWidth:.infinity).padding(.vertical,7)
                        }.buttonStyle(.borderedProminent).disabled(model.busy)
                        Divider()
                        HStack {
                            Text("Translated transcript").font(.headline)
                            Spacer()
                            if model.pending != nil { Button("Save") { Task { await model.save() } }.disabled(model.busy) }
                        }
                        if model.words.isEmpty { Text("Translations will appear here.").foregroundStyle(.secondary) }
                        else { Text(model.words).textSelection(.enabled).privacySensitive() }
                        if !model.running && model.words.isEmpty {
                            Text("Connect your AirPods and start listening before locking your phone.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !model.notice.isEmpty { Text(model.notice).font(.callout).foregroundStyle(.secondary) }
                }.frame(maxWidth:600,alignment:.leading).padding()
            }
            .navigationTitle("Live interpreter")
            .toolbar { if let d = model.device {
                ToolbarItem(placement:.topBarTrailing) { Button("History") { history = true }
                    .sheet(isPresented:$history) { HistoryView(device:d, onUnauthorized:{ error in history = false; model.handle(error) }) } }
            } }
        }
        .confirmationDialog("Start without saving this transcript?",isPresented:$discardPrompt,titleVisibility:.visible) {
            Button("Start new session",role:.destructive) { model.start() }
            Button("Cancel",role:.cancel) {}
        }
    }
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
