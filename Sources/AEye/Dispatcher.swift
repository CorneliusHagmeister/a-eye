import AppKit

/// One press of the talk key: where it goes, what was said, and the audio (kept on disk so
/// nothing is lost if an engine fails).
final class Press {
    enum State { case live, done, failed, empty, undeliverable }
    let id = UUID()
    var target: Target?
    let engine: String
    let created = Date()
    var state = State.live
    var text = ""
    var phrases = 0
    /// Paste-on-release: the whole text has been queued for delivery.
    var pastedWhole = false
    /// "…send it" was said: press Return once the whole press has been pasted.
    var submitRequested = false
    var error: String?
    var wav: URL?

    init(target: Target?, engine: String) { self.target = target; self.engine = engine }
}

/// Pastes committed text strictly in order, each piece into its press's target.
final class Delivery {
    enum Job { case text(String, Press), submit(Press), clear(Press), undoLast(Press) }

    /// Target the user is recording for right now — delivery returns there after a hop.
    var currentFocusTarget: () -> Target? = { nil }
    var onDelivered: ((Press, String) -> Void)?
    /// The target's window is gone (closed / other Space); the text was not pasted anywhere.
    var onUndeliverable: ((Press) -> Void)?
    /// Target we last focused and nothing has moved focus since — skip the refocus.
    var focusedTarget: String?
    private(set) var recent: [Press] = []
    private var queue: [Job] = []
    private var running = false
    /// What we pasted last and where — "scratch that" deletes exactly this.
    private var lastPaste: (key: String, count: Int)?
    var onCommandDone: ((Press, String) -> Void)?

    var pending: Int { queue.count }

    func track(_ p: Press) {
        recent.insert(p, at: 0)
        if recent.count > 12 { recent.removeLast() }
    }

    func forget(_ p: Press) { recent.removeAll { $0 === p } }

    func enqueue(_ job: Job) {
        queue.append(job)
        Task { @MainActor in await self.run() }
    }

    @MainActor
    private func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !queue.isEmpty {
            switch queue.removeFirst() {
            case .text(var text, let press):
                guard press.state != .undeliverable else { continue }  // collected, copied at the end
                let key = press.target?.key ?? "front"
                // A second dictation into the same box continues the text.
                if lastPaste?.key == key, !text.hasPrefix(" ") { text = " " + text }
                if await deliver(text, to: press.target, submit: false) {
                    lastPaste = (key, text.count)
                    onDelivered?(press, text)
                } else {
                    press.state = .undeliverable
                    onUndeliverable?(press)
                }
            case .submit(let press):
                if press.state != .undeliverable { _ = await deliver(nil, to: press.target, submit: true) }
                lastPaste = nil
            case .undoLast(let press):
                let key = press.target?.key ?? "front"
                guard let last = lastPaste, last.key == key, last.count <= 4000 else {
                    onCommandDone?(press, "Nothing to scratch here"); continue
                }
                if await deliver(nil, to: press.target, submit: false) {
                    for _ in 0..<last.count { Input.key(51) }  // ⌫ — caret is still at the end of our paste
                    lastPaste = nil
                    onCommandDone?(press, "⌫ Scratched the last dictation")
                }
            case .clear(let press):
                // Only a detected text input — ⌘A in a code editor would select the whole file.
                guard press.target == nil || press.target?.clickFraction != nil else {
                    onCommandDone?(press, "No text input found there — not clearing"); continue
                }
                if await deliver(nil, to: press.target, submit: false) {
                    Input.key(0, flags: .maskCommand)  // ⌘A
                    Input.key(51)                      // ⌫
                    lastPaste = nil
                    onCommandDone?(press, "Cleared the input")
                }
            }
        }
    }

    @MainActor
    private func deliver(_ text: String?, to target: Target?, submit: Bool) async -> Bool {
        guard let target else {  // no targets set up: plain dictation into the focused app
            if let text { await Input.paste(text, submit: false) }
            if submit { Input.key(36) }
            return true
        }
        let returnTo = currentFocusTarget()
        let alreadyThere = focusedTarget == target.key
            && WindowControl.resolve(target)?.pid == WindowControl.frontmostPID()
        if !alreadyThere {
            // Window closed or on another Space: never paste into whatever happens to be in front.
            guard await WindowControl.focus(target, click: true) else { return false }
            focusedTarget = target.key
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if let text { await Input.paste(text, submit: false) }
        if submit { Input.key(36) }
        // You've moved on to another target while this was in flight — hop back.
        if let back = returnTo, back.key != target.key {
            try? await Task.sleep(nanoseconds: 150_000_000)
            await WindowControl.focus(back, click: true)
            focusedTarget = back.key
        }
        return true
    }

    static func appendHistory(_ p: Press) {
        let entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: p.created), "engine": p.engine,
                                    "target": p.target?.name ?? "", "text": p.text,
                                    "wav": p.wav?.lastPathComponent ?? "", "error": p.error ?? ""]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: Paths.history)
        }
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; return f.string(from: Date())
    }
}
