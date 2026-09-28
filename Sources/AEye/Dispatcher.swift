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
    /// In-flight OpenAI clean-ups; Return ("send it") waits for them so it sends the clean text.
    var cleanups: [Task<Void, Never>] = []
    /// Rolling clean-up: what was said (quick-tidied pieces) and the rewrite state.
    var pieces: [String] = []
    var rewriting = false
    var rewriteDirty = false
    var rewrittenUpTo = 0
    var error: String?
    var wav: URL?

    init(target: Target?, engine: String) { self.target = target; self.engine = engine }
}

/// Pastes committed text strictly in order, each piece into its press's target.
///
/// Everything pasted into the current box is remembered as segments, so the rolling clean-up
/// can rewrite a press in place (editing from the first difference) and "scratch that" can
/// remove exactly the last piece. Segments are dropped the moment
/// you click or type yourself — then the caret may have moved and editing blind is unsafe.
final class Delivery {
    enum Job {
        case text(String, Press, segment: UUID?)
        /// Replace everything this press has pasted with a new version (rolling clean-up).
        case rewrite(Press, String)
        case submit(Press), clear(Press), undoLast(Press)
    }

    /// Target the user is recording for right now — delivery returns there after a hop.
    var currentFocusTarget: () -> Target? = { nil }
    var onDelivered: ((Press, String) -> Void)?
    /// The target's window is gone (closed / other Space); the text was not pasted anywhere.
    var onUndeliverable: ((Press) -> Void)?
    var onCommandDone: ((Press, String) -> Void)?
    /// Target we last focused and nothing has moved focus since — skip the refocus.
    var focusedTarget: String? {
        didSet { if focusedTarget == nil { segments = [] } }
    }
    private(set) var recent: [Press] = []
    private var queue: [Job] = []
    private var running = false
    /// What we've pasted, in order, into the box `segmentsKey` since focus last changed.
    private var segments: [(id: UUID, press: UUID, text: String)] = []
    private var segmentsKey: String?

    func track(_ p: Press) {
        recent.insert(p, at: 0)
        if recent.count > 12 { recent.removeLast() }
    }

    func forget(_ p: Press) { recent.removeAll { $0 === p } }

    /// You typed in some app yourself: our picture of the box's contents is no longer reliable.
    func userTyped() { segments = [] }

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
            case .text(var text, let press, let id):
                guard press.state != .undeliverable else { continue }  // collected, copied at the end
                let key = press.target?.key ?? "front"
                if segmentsKey != key { segments = [] }
                // A second dictation into the same box continues the text.
                if !segments.isEmpty, !text.hasPrefix(" ") { text = " " + text }
                if await deliver(text, to: press.target) {
                    if segmentsKey != key { segments = [] }  // deliver() may have refocused
                    segments.append((id ?? UUID(), press.id, text))
                    segmentsKey = key
                    onDelivered?(press, text)
                } else {
                    press.state = .undeliverable
                    onUndeliverable?(press)
                }
            case .rewrite(let press, let newText):
                let key = press.target?.key ?? "front"
                guard segmentsKey == key, focusedTarget == key || press.target == nil,
                      let first = segments.firstIndex(where: { $0.press == press.id }) else { continue }
                let last = segments.lastIndex(where: { $0.press == press.id })!
                let lead = segments[first].text.hasPrefix(" ") ? " " : ""
                let old = segments[first...].map(\.text).joined()
                let new = lead + newText + segments[(last + 1)...].map(\.text).joined()
                guard old != new else { continue }
                // Edit only from the first difference: the part you've already read stays put.
                let common = zip(old, new).prefix { $0 == $1 }.count
                let deletions = old.count - common
                guard deletions <= 4000, await deliver(nil, to: press.target) else { continue }
                guard boxEndsWith(old) else { continue }
                for _ in 0..<deletions { Input.key(51) }
                let insert = String(new.dropFirst(common))
                if !insert.isEmpty { await Input.paste(insert, submit: false) }
                // Awaits above can see segments reset (you typed/clicked): look them up again.
                if let f = segments.firstIndex(where: { $0.press == press.id }),
                   let l = segments.lastIndex(where: { $0.press == press.id }) {
                    segments.replaceSubrange(f...l, with: [(UUID(), press.id, lead + newText)])
                }
            case .submit(let press):
                if press.state != .undeliverable { _ = await deliver(nil, to: press.target, submit: true) }
                segments = []
            case .undoLast(let press):
                let key = press.target?.key ?? "front"
                guard segmentsKey == key, let last = segments.last, last.text.count <= 4000 else {
                    onCommandDone?(press, "Nothing to scratch here"); continue
                }
                if await deliver(nil, to: press.target), boxEndsWith(last.text) {
                    for _ in 0..<last.text.count { Input.key(51) }  // ⌫ — caret is at the end of our paste
                    if segments.last?.id == last.id { segments.removeLast() }
                    onCommandDone?(press, "⌫ Scratched “\(last.text.trimmingCharacters(in: .whitespaces).prefix(40))”")
                }
            case .clear(let press):
                // Only a detected text input — ⌘A in a code editor would select the whole file.
                guard press.target == nil || press.target?.clickFraction != nil else {
                    onCommandDone?(press, "No text input found there — not clearing"); continue
                }
                if await deliver(nil, to: press.target) {
                    Input.key(0, flags: .maskCommand)  // ⌘A
                    Input.key(51)                      // ⌫
                    segments = []
                    onCommandDone?(press, "Cleared the input")
                }
            }
        }
    }

    /// Before editing blind with ⌫: does the input still end with what we think we typed?
    /// (A late paste, a sent message or your own edits make it wrong.) If its text can't be
    /// read, trust our record.
    @MainActor
    private func boxEndsWith(_ expected: String) -> Bool {
        guard let actual = WindowControl.focusedText() else { return true }
        func norm(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let ok = norm(actual).hasSuffix(norm(expected))
        if !ok {
            Log.info("edit skipped: input doesn't end with our text (expected …\(expected.suffix(40)), found …\(actual.suffix(40)))")
            segments = []
        }
        return ok
    }

    @MainActor
    private func deliver(_ text: String?, to target: Target?, submit: Bool = false) async -> Bool {
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
