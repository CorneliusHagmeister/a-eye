import AppKit

/// One press of the talk key. Audio is on disk before transcription starts, so nothing is
/// lost if transcription is slow, fails, or the app quits.
final class Utterance {
    enum State { case transcribing, ready, delivered, failed, empty, undeliverable }
    let id = UUID()
    let target: Target?
    let wav: URL
    /// A later phrase of the same key press — pasted with a leading space.
    var continuation = false
    /// The phrase closed by releasing the key (the last one of the press).
    var isFinal = true
    let created = Date()
    var state: State = .transcribing
    var text = ""
    var error: String?

    init(target: Target?, wav: URL, continuation: Bool) {
        self.target = target; self.wav = wav; self.continuation = continuation
    }
}

/// Transcribes utterances one at a time and delivers them strictly in the order they were
/// spoken, each to the target that was latched when its key went down.
final class Dispatcher {
    var transcriber: Transcriber
    var hints: () -> [String] = { [] }
    /// Target the user is currently recording for / looking at — delivery returns there.
    var currentFocusTarget: () -> Target? = { nil }
    var onUpdate: ((Utterance) -> Void)?

    private(set) var recent: [Utterance] = []
    private var pending: [Utterance] = []
    private var transcribeChain: Task<Void, Never>?
    private var delivering = false
    /// Target we last focused and nothing has moved focus since — skip the refocus click.
    var focusedTarget: UUID?

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    var inFlight: Int { pending.count }
    /// Last transcript, fed to Whisper as context so phrase n+1 continues phrase n.
    private var lastText = ""

    func submit(samples: [Float], target: Target?, continuation: Bool = false, isFinal: Bool = true) {
        let url = Paths.recordings.appendingPathComponent(Self.stamp() + ".wav")
        do { try WAV.write(samples, to: url) } catch { Log.info("wav write failed: \(error)"); return }
        let u = Utterance(target: target, wav: url, continuation: continuation)
        u.isFinal = isFinal
        pending.append(u)
        recent.insert(u, at: 0); if recent.count > 10 { recent.removeLast() }
        onUpdate?(u)
        enqueueTranscription(u)
    }

    func retry(_ u: Utterance) {
        guard u.state == .failed else { return }
        u.state = .transcribing; u.error = nil
        pending.append(u)
        onUpdate?(u)
        enqueueTranscription(u)
    }

    private func enqueueTranscription(_ u: Utterance) {
        let prev = transcribeChain
        let transcriber = transcriber
        let hints = hints()
        transcribeChain = Task { @MainActor in
            await prev?.value
            let t0 = Date()
            do {
                let context = u.continuation ? [String(self.lastText.suffix(200))] : []
                let text = try await transcriber.transcribe(wav: u.wav, hints: hints + context)
                u.text = Self.dropHallucination(text.trimmingCharacters(in: .whitespacesAndNewlines))
                u.state = u.text.isEmpty ? .empty : .ready
                if !u.text.isEmpty { self.lastText = u.text }
                Log.info(String(format: "transcribed in %.2fs → %@: %@", Date().timeIntervalSince(t0),
                                u.target?.name ?? "front app", u.text))
            } catch {
                u.state = .failed; u.error = error.localizedDescription
                Log.info("transcription failed: \(error)")
            }
            self.onUpdate?(u)
            await self.deliverReady()
        }
    }

    @MainActor
    private func deliverReady() async {
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        while let u = pending.first, u.state != .transcribing {
            pending.removeFirst()
            guard u.state == .ready else { continue }
            u.state = await deliver(u) ? .delivered : .undeliverable
            appendHistory(u)
            onUpdate?(u)
        }
    }

    /// Whisper's stock phrases for near-silence.
    private static func dropHallucination(_ s: String) -> String {
        let junk: Set<String> = ["thank you.", "thank you", "thanks for watching!", "thanks for watching.",
                                 "you", "bye.", "vielen dank.", "untertitel der amara.org-community"]
        return junk.contains(s.lowercased()) ? "" : s
    }

    @MainActor
    private func deliver(_ u: Utterance) async -> Bool {
        let text = u.continuation ? " " + u.text : u.text
        // Send only on the last phrase — the key-up one — never mid-sentence.
        let submit = Settings.autoSubmit && u.isFinal
        guard let target = u.target else {
            await Input.paste(text, submit: submit)  // no targets: plain dictation
            return true
        }
        let returnTo = currentFocusTarget()
        let alreadyThere = focusedTarget == target.id
            && WindowControl.resolve(target)?.pid == WindowControl.frontmostPID()
        if !alreadyThere {
            guard await WindowControl.focus(target, click: true) else {
                // Window closed or on another Space: don't paste into whatever is in front.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.text, forType: .string)
                return false
            }
            focusedTarget = target.id
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        await Input.paste(text, submit: submit)
        // You've moved on to another target while this was transcribing — hop back.
        if let back = returnTo, back.id != target.id {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await WindowControl.focus(back, click: true)
            focusedTarget = back.id
        }
        return true
    }

    private func appendHistory(_ u: Utterance) {
        let entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: u.created),
                                    "target": u.target?.name ?? "", "text": u.text, "wav": u.wav.lastPathComponent]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: Paths.history)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; return f.string(from: Date())
    }
}
