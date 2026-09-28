import Foundation

/// Deepgram Nova-3 over WebSocket: true streaming — live interim text, finals as it detects
/// the end of each phrase. `language=multi` handles English/German code-switching.
final class DeepgramEngine: SpeechEngine {
    let id = "deepgram"
    let name = "Deepgram Nova-3"
    var needsKey: Bool { true }

    func startSession(_ ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) -> SpeechSession {
        DeepgramSession(key: Keychain.get(id), ctx: ctx, onEvent: onEvent)
    }
}

final class DeepgramSession: SpeechSession {
    private var task: URLSessionWebSocketTask?
    private let onEvent: (SpeechEvent) -> Void
    private var finishing = false
    private var done = false

    init(key: String?, ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) {
        self.onEvent = onEvent
        guard let key else {
            DispatchQueue.main.async { onEvent(.failed(EngineError.missingKey("Deepgram").localizedDescription)) }
            return
        }
        var c = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        c.queryItems = [
            .init(name: "model", value: "nova-3"),
            .init(name: "language", value: ctx.languages.count == 1 ? ctx.languages[0] : "multi"),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "endpointing", value: "300"),
        ] + ctx.hints.prefix(20).map { .init(name: "keyterm", value: $0) }
        var req = URLRequest(url: c.url!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    func append(_ samples: [Float]) {
        guard let task, !finishing, !samples.isEmpty else { return }
        task.send(.data(PCM.int16(samples))) { _ in }
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        guard let task else { return end() }
        task.send(.string(#"{"type":"Finalize"}"#)) { _ in }
        task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.end() }
    }

    func cancel() {
        finishing = true
        task?.cancel(with: .normalClosure, reason: nil)
        done = true
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                switch result {
                case .success(let msg):
                    self.handle(msg)
                    self.receive()
                case .failure(let error):
                    if !self.finishing {
                        let status = (self.task?.response as? HTTPURLResponse)?.statusCode
                        self.onEvent(.failed("Deepgram: \(status.map { "HTTP \($0) — " } ?? "")\(error.localizedDescription)"))
                    }
                    self.end()
                }
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        guard case .string(let s) = msg,
              let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
        switch json["type"] as? String {
        case "Results":
            let alt = ((json["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]])?.first
            let text = (alt?["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            onEvent((json["is_final"] as? Bool ?? false) ? .final(text) : .partial(text))
        case "Metadata":
            if finishing { end() }  // arrives after CloseStream once everything is flushed
        case "Error":
            onEvent(.failed("Deepgram: \(json["description"] ?? json)"))
        default: break
        }
    }

    private func end() {
        guard !done else { return }
        done = true
        task?.cancel(with: .normalClosure, reason: nil)
        onEvent(.done)
    }
}

/// OpenAI Realtime transcription session with `gpt-live-transcribe`: live deltas while you
/// speak. The model has no server-side turn detection, so our pause detector decides when
/// to commit each phrase; its completed transcript is the final text.
final class OpenAIEngine: SpeechEngine {
    let id = "openai"
    let name = "OpenAI live transcribe"
    var needsKey: Bool { true }

    func startSession(_ ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) -> SpeechSession {
        OpenAISession(key: Keychain.get(id), ctx: ctx, onEvent: onEvent)
    }
}

final class OpenAISession: SpeechSession {
    private var task: URLSessionWebSocketTask?
    private let onEvent: (SpeechEvent) -> Void
    private let segmenter = Segmenter()
    private var sinceCommit: [Float] = []
    private var commitsSent = 0
    private var finalsEmitted = 0
    private var order: [String] = []                  // committed item ids, in speech order
    private var finals: [String: String] = [:]
    private var partials: [(id: String, text: String)] = []
    private var finishing = false
    private var done = false

    init(key: String?, ctx: SessionContext, onEvent: @escaping (SpeechEvent) -> Void) {
        self.onEvent = onEvent
        guard let key else {
            DispatchQueue.main.async { onEvent(.failed(EngineError.missingKey("OpenAI").localizedDescription)) }
            return
        }
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        var transcription: [String: Any] = [
            "model": "gpt-live-transcribe",
            "prompt": "Dictation to an AI coding assistant.",
            "keywords": Array(ctx.hints.prefix(30)),
            "delay": "low",
        ]
        if !ctx.languages.isEmpty { transcription["languages"] = ctx.languages }
        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ]],
            ],
        ])
        receive()
    }

    func append(_ samples: [Float]) {
        guard task != nil, !finishing, !samples.isEmpty else { return }
        let pcm = PCM.int16(PCM.resample(samples, from: 16_000, to: 24_000))
        send(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
        sinceCommit.append(contentsOf: samples)
        if let end = segmenter.findPhraseEnd(sinceCommit) {
            commitOrClear(Array(sinceCommit[..<end]))
        }
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        guard task != nil else { return end() }
        commitOrClear(sinceCommit)
        checkDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.end() }
    }

    func cancel() {
        done = true
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func commitOrClear(_ phrase: [Float]) {
        if segmenter.hasSpeech(phrase) {
            send(["type": "input_audio_buffer.commit"])
            commitsSent += 1
        } else {
            send(["type": "input_audio_buffer.clear"])
        }
        sinceCommit = []
        segmenter.reset()
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                switch result {
                case .success(let msg):
                    self.handle(msg)
                    self.receive()
                case .failure(let error):
                    let status = (self.task?.response as? HTTPURLResponse)?.statusCode
                    self.onEvent(.failed("OpenAI: \(status.map { "HTTP \($0) — " } ?? "")\(error.localizedDescription)"))
                    self.end()
                }
            }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        guard case .string(let s) = msg,
              let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
        let itemID = json["item_id"] as? String ?? ""
        switch json["type"] as? String {
        case "input_audio_buffer.committed":
            order.append(itemID)
        case "conversation.item.input_audio_transcription.delta":
            let delta = json["delta"] as? String ?? ""
            if let i = partials.firstIndex(where: { $0.id == itemID }) { partials[i].text += delta }
            else { partials.append((itemID, delta)) }
            onEvent(.partial(partials.map(\.text).joined(separator: " ")))
        case "conversation.item.input_audio_transcription.completed":
            finals[itemID] = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            partials.removeAll { $0.id == itemID }
            flush()
        case "error":
            let e = json["error"] as? [String: Any]
            onEvent(.failed("OpenAI: \(e?["message"] as? String ?? s)"))
        default: break
        }
    }

    /// Completions can arrive out of order across phrases; emit them in speech order.
    private func flush() {
        while let first = order.first, let text = finals[first] {
            order.removeFirst()
            finals[first] = nil
            finalsEmitted += 1
            if !text.isEmpty { onEvent(.final(text)) }
        }
        checkDone()
    }

    private func checkDone() {
        if finishing, finalsEmitted >= commitsSent { end() }
    }

    private func end() {
        guard !done else { return }
        done = true
        task?.cancel(with: .normalClosure, reason: nil)
        onEvent(.done)
    }
}
