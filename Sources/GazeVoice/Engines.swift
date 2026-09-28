import Foundation

/// What a speech engine reports during one press of the talk key.
enum SpeechEvent {
    /// Live text for the phrase in progress — may still change, so it's shown, not pasted.
    case partial(String)
    /// A committed phrase — pasted into the target straight away.
    case final(String)
    case failed(String)
    /// The session is over; no more events follow.
    case done
}

struct SessionContext {
    var hints: [String]       // vocabulary: target names, dev terms
    var languages: [String]   // ISO 639-1; empty = auto-detect
}

/// A speech-to-text backend. Plug-in point for local models and cloud services.
protocol SpeechEngine: AnyObject {
    var id: String { get }
    var name: String { get }
    /// Cloud engines need an API key (kept in the Keychain under `id`).
    var needsKey: Bool { get }
    /// Called on talk-key down so slow engines can warm up while you speak.
    func prepare()
    func shutdown()
    /// One session per press. Events arrive on the main queue.
    func startSession(_ ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) -> SpeechSession
}

extension SpeechEngine {
    var needsKey: Bool { false }
    func prepare() {}
    func shutdown() {}
    var hasKey: Bool { !needsKey || Keychain.get(id) != nil }
}

protocol SpeechSession: AnyObject {
    /// 16kHz mono audio, called on the main queue about every 100ms while the key is held.
    func append(_ samples: [Float])
    /// Key released (post-roll included): flush what's left, then emit `.done`.
    func finish()
    func cancel()
}

enum Engines {
    static let catalog: [(id: String, name: String)] = [
        ("whisper", "Whisper (local)"),
        ("parakeet", "Parakeet (local)"),
        ("wispr", "Wispr Flow"),
        ("deepgram", "Deepgram Nova-3"),
        ("openai", "OpenAI live transcribe"),
    ]

    static func make(_ id: String) -> SpeechEngine? {
        switch id {
        case "whisper": return WhisperTranscriber().map { ChunkedEngine(id: id, transcriber: $0) }
        case "apple": return ChunkedEngine(id: id, transcriber: AppleTranscriber())
        case "wispr": return ChunkedEngine(id: id, transcriber: WisprTranscriber())
        case "deepgram": return DeepgramEngine()
        case "openai": return OpenAIEngine()
        default: return nil  // parakeet: needs the Swift 6 toolchain (FluidAudio)
        }
    }

    /// Always-available local transcriber: fallback when a cloud engine fails, and for retries.
    static func localTranscriber() -> Transcriber { WhisperTranscriber() ?? AppleTranscriber() }
}

/// Turns any clip-at-a-time transcriber (local Whisper, Parakeet, Wispr Flow's REST API) into
/// a live session: every pause commits the phrase so far, which is transcribed and pasted
/// while you keep talking.
final class ChunkedEngine: SpeechEngine {
    let id: String
    let transcriber: Transcriber
    var name: String { transcriber.name }
    var needsKey: Bool { transcriber.needsKey }

    init(id: String, transcriber: Transcriber) { self.id = id; self.transcriber = transcriber }

    func prepare() { transcriber.prepare() }
    func shutdown() { transcriber.shutdown() }

    func startSession(_ ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) -> SpeechSession {
        ChunkedSession(transcriber: transcriber, ctx: ctx, onEvent: onEvent)
    }
}

final class ChunkedSession: SpeechSession {
    private let transcriber: Transcriber
    private let ctx: SessionContext
    private let onEvent: (SpeechEvent) -> Void
    private let segmenter = Segmenter()
    private var audio: [Float] = []
    private var chain: Task<Void, Never>?
    private var previous = ""
    private var finished = false
    private var cancelled = false
    private var partialRunning = false
    private var lastPartial = Date.distantPast

    init(transcriber: Transcriber, ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) {
        self.transcriber = transcriber; self.ctx = ctx; self.onEvent = onEvent
    }

    func append(_ samples: [Float]) {
        guard !finished, !cancelled else { return }
        audio.append(contentsOf: samples)
        let pending = Array(audio[segmenter.cut...])
        if let end = segmenter.findPhraseEnd(pending) {
            segmenter.advance(by: end)
            let phrase = Array(pending[..<end])
            if segmenter.hasSpeech(phrase) { commit(phrase) }
        } else if transcriber.livePartials, !partialRunning, Date().timeIntervalSince(lastPartial) > 0.5,
                  segmenter.hasSpeech(pending) {
            livePartial(pending)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let rest = segmenter.cut < audio.count ? Array(audio[segmenter.cut...]) : []
        if segmenter.hasSpeech(rest) { commit(rest) }
        let prev = chain
        Task { @MainActor in
            await prev?.value
            self.onEvent(.done)
        }
    }

    func cancel() { cancelled = true }

    private func commit(_ phrase: [Float]) {
        let prev = chain
        chain = Task { @MainActor in
            await prev?.value
            guard !self.cancelled else { return }
            let t0 = Date()
            do {
                let text = Self.clean(try await self.transcriber.transcribe(samples: phrase, hints: self.ctx.hints,
                                                                             previous: self.previous))
                Log.info(String(format: "%@: phrase %.1fs → %.2fs: %@", self.transcriber.name,
                                Double(phrase.count) / Recorder.sampleRate, Date().timeIntervalSince(t0), text))
                if !text.isEmpty { self.previous = text; self.onEvent(.final(text)) }
            } catch {
                self.onEvent(.failed(error.localizedDescription))
            }
        }
    }

    private func livePartial(_ pending: [Float]) {
        partialRunning = true
        lastPartial = Date()
        Task { @MainActor in
            defer { self.partialRunning = false }
            if let text = try? await self.transcriber.transcribe(samples: pending, hints: self.ctx.hints, previous: self.previous),
               !self.finished { self.onEvent(.partial(Self.clean(text))) }
        }
    }

    /// Whisper's stock phrases for near-silence.
    static func clean(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk: Set<String> = ["thank you.", "thank you", "thanks for watching!", "thanks for watching.",
                                 "you", "bye.", "vielen dank.", "untertitel der amara.org-community"]
        return junk.contains(t.lowercased()) ? "" : t
    }
}

enum PCM {
    static func int16(_ s: [Float]) -> Data {
        var d = Data(capacity: s.count * 2)
        for x in s {
            let v = Int16(max(-1, min(1, x)) * 32767).littleEndian
            withUnsafeBytes(of: v) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// Linear resample (16kHz → 24kHz for OpenAI).
    static func resample(_ s: [Float], from: Double, to: Double) -> [Float] {
        guard !s.isEmpty, from != to else { return s }
        let n = Int(Double(s.count) * to / from)
        return (0..<n).map { i in
            let x = Double(i) * from / to
            let j = Int(x), f = Float(x - Double(j))
            return j + 1 < s.count ? s[j] * (1 - f) + s[j + 1] * f : s[s.count - 1]
        }
    }
}
