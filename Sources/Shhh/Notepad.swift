import AppKit
import SwiftUI

/// A notepad to take notes into: "help me take notes" opens it. While it's open, right ⌘
/// dictation lands in it, and **Listen** transcribes hands-free (a lecture, a meeting, your own
/// thoughts) a few seconds at a time, on the Mac. Then the assistant can work on the notes ("make
/// these into bullet points") and its new version goes straight back in. Saved as you go.
@MainActor
final class Notepad {
    private let model = NotepadModel()
    private var panel: NSPanel?
    private var saveWork: DispatchWorkItem?
    private var listening: Task<Void, Never>?
    private var recording: AudioRecorder.Recording?
    /// Who is speaking, for this listening session: lines start "Speaker 1:", "You:" when it changes.
    private var speakers = SpeakerTracker()
    private var lastSpeaker: String?
    /// The last piece of a recording, still being transcribed after Stop.
    private var finishing: Task<Void, Never>?

    /// The notepad closed (by voice, the menu or its close button), and when it's cleared.
    var onHidden: () -> Void = {}
    var onCleared: () -> Void = {}
    /// The user picked what the notes are from the notepad's menu.
    var onKind: (NoteSaver.Kind) -> Void = { _ in }

    /// Set by the app: the recorder, the speech model and the microphone choice to listen with.
    var listen: (() async -> (recorder: AudioRecorder, transcriber: Transcriber, microphone: String?)?)?

    /// The distributed notification `Joe --notepad` posts to the running app.
    nonisolated static let openRequest = "io.github.tibophlp.shhh.openNotepad"
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shhh/Notepad.md")

    var isVisible: Bool { panel?.isVisible == true }
    var isListening: Bool { model.listening }
    var text: String { model.text }

    init() {
        model.text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        model.onListen = { [weak self] in
            guard let self else { return }
            if self.model.listening { self.stopListening() } else { self.startListening() }
        }
        model.onUndo = { [weak self] in self?.undoAssistant() }
        model.onClear = { [weak self] in
            self?.model.text = ""
            self?.onCleared()
        }
        model.onKind = { [weak self] kind in
            self?.model.kind = kind
            self?.onKind(kind)
        }
        model.onChange = { [weak self] in self?.scheduleSave() }
    }

    // MARK: - Showing

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !panel.isVisible {
            // Along the right of the screen the pointer is on.
            let screen = Notch.screenUnderMouse ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrame(NSRect(x: visible.maxX - 400, y: visible.maxY - 560, width: 380, height: 520), display: true)
            }
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        guard isVisible else { return }
        stopListening()
        panel?.orderOut(nil)
        onHidden()
    }

    /// Runs `work` once the notes are complete: after the last piece of a recording is in.
    func whenDone(_ work: @escaping @MainActor () -> Void) {
        let finishing = finishing
        Task { await finishing?.value; work() }
    }

    /// What the notes are, for the notepad's menu ("Lecture notes").
    func show(kind: NoteSaver.Kind?) {
        model.kind = kind
    }

    /// Empties the notepad for a new sitting (the last one is saved in the vault).
    func clear() {
        model.text = ""
        model.beforeAssistant = nil
        scheduleSave()
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: - Writing into it

    /// A dictated phrase (right ⌘ while the notepad is open): on a new line.
    func appendDictation(_ text: String) {
        append(text, separator: "\n")
    }

    /// The assistant's new version of the notes, replacing them. One step of undo.
    func replace(with text: String) {
        model.beforeAssistant = model.text
        model.text = text
        scheduleSave()
    }

    private func undoAssistant() {
        guard let before = model.beforeAssistant else { return }
        model.text = before
        model.beforeAssistant = nil
        scheduleSave()
    }

    private func append(_ text: String, separator: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let current = model.text
        model.text = current.isEmpty ? text : current + (current.hasSuffix("\n") ? "" : separator) + text
        model.beforeAssistant = nil
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let text = model.text
        let work = DispatchWorkItem {
            try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: Self.url, atomically: true, encoding: .utf8)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Listening

    /// Hands-free: one long recording, read a piece at a time. A piece ends at a pause once it's
    /// four seconds long, or at twenty seconds whatever happens, and is transcribed on the Mac and
    /// added while the recording carries on, so nothing falls between pieces.
    func startListening() {
        guard listening == nil else { return }
        model.listening = true
        speakers = SpeakerTracker()
        lastSpeaker = nil
        listening = Task { [weak self] in
            guard let self, let setup = await self.listen?() else {
                NSSound.beep()
                self?.model.listening = false
                self?.listening = nil
                return
            }
            let (recorder, transcriber, microphone) = setup
            guard let recording = try? await recorder.start(preferredUID: microphone) else {
                NSSound.beep()
                self.model.listening = false
                self.listening = nil
                return
            }
            self.recording = recording
            while !Task.isCancelled, self.model.listening, !recorder.hasFailed(recording) {
                try? await Task.sleep(for: .milliseconds(250))
                let seconds = recorder.pendingSeconds(recording)
                let pause = Self.isQuiet(recorder.tail(recording, seconds: 0.6))
                guard seconds >= 20 || (seconds >= 4 && pause) else { continue }
                await self.transcribe(recorder.take(recording), with: transcriber)
            }
        }
    }

    /// Stops listening; what was heard since the last piece is still transcribed and added.
    func stopListening() {
        guard model.listening || listening != nil else { return }
        model.listening = false
        listening?.cancel()
        listening = nil
        guard let recording, let setupTask = listen else { return }
        self.recording = nil
        finishing = Task {
            guard let (recorder, transcriber, _) = await setupTask() else { return }
            let rest = recorder.take(recording)
            recorder.cancel(recording)
            await transcribe(rest, with: transcriber)
        }
    }

    private func transcribe(_ samples: [Float], with transcriber: Transcriber) async {
        guard samples.count >= 16_000 / 2, !Self.isQuiet(samples) else { return }
        // Split where the voice changes; a new line, with who's speaking, each time it does.
        for turn in await speakers.split(samples) {
            guard turn.samples.count >= 16_000 / 2, !Self.isQuiet(turn.samples),
                  let text = try? await transcriber.transcribe(await NoiseFilter.shared.clean(turn.samples)), !text.isEmpty else { continue }
            if !turn.label.isEmpty, turn.label != lastSpeaker {
                lastSpeaker = turn.label
                append("\(turn.label): " + Vocabulary.apply(text), separator: "\n\n")
            } else {
                append(Vocabulary.apply(text), separator: " ")
            }
        }
    }

    /// Below speaking volume (RMS), for finding pauses and skipping silent pieces.
    private static func isQuiet(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        let power = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return power.squareRoot() < 0.012
    }

    // MARK: - Window

    private func makePanel() -> NSPanel {
        let panel = NotepadWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                                  styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
        panel.title = "Notes"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotepadView(model: model))
        panel.onClose = { [weak self] in
            self?.stopListening()
            self?.onHidden()
        }
        return panel
    }
}

/// Takes typing without pulling focus from the app the user was in.
private final class NotepadWindow: NSPanel {
    var onClose: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func close() {
        onClose()
        orderOut(nil) // keep the window (and the notes) for next time
    }
}

final class NotepadModel: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { onChange() } } }
    @Published var listening = false
    /// The notes before the assistant's last change, for Undo.
    @Published var beforeAssistant: String?
    @Published var kind: NoteSaver.Kind?
    var onListen: () -> Void = {}
    var onUndo: () -> Void = {}
    var onClear: () -> Void = {}
    var onKind: (NoteSaver.Kind) -> Void = { _ in }
    var onChange: () -> Void = {}
}

private struct NotepadView: View {
    @ObservedObject var model: NotepadModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: model.onListen) {
                    Label(model.listening ? "Stop" : "Listen", systemImage: model.listening ? "stop.fill" : "waveform")
                }
                .tint(model.listening ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
                if model.listening {
                    ListeningDot()
                    Text("Listening…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu(model.kind?.label ?? "Notes") {
                    ForEach(NoteSaver.Kind.allCases, id: \.self) { kind in
                        Button(kind.label) { model.onKind(kind) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("What these notes are: they're saved to Obsidian as that when the notepad closes")
                if model.beforeAssistant != nil {
                    Button("Undo") { model.onUndo() }.help("Undo the assistant's change")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                    copied = true
                } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .help("Copy the notes")
                Button { model.onClear() } label: { Image(systemName: "trash") }
                    .help("Clear the notes")
                    .disabled(model.text.isEmpty)
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            TextEditor(text: $model.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Hold right ⌘ to dictate here, or press Listen for a lecture or meeting.\nThen hold right ⌥ and say \"make these into bullet points\".")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
        }
        .onChange(of: model.text) { copied = false }
    }
}

private struct ListeningDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.3)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true } }
    }
}
