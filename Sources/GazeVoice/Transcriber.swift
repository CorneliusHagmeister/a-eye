import Foundation
import Speech

/// Transcribes one finished clip. Wrapped by `ChunkedEngine` to stream phrase by phrase.
protocol Transcriber: AnyObject {
    var name: String { get }
    var needsKey: Bool { get }
    /// Fast enough to re-run on the phrase in progress every ~0.5s for live text.
    var livePartials: Bool { get }
    func prepare()
    func shutdown()
    /// `previous` is the text of the phrase before this one, for continuity.
    func transcribe(wav: URL, hints: [String], previous: String) async throws -> String
    func transcribe(samples: [Float], hints: [String], previous: String) async throws -> String
}

extension Transcriber {
    var needsKey: Bool { false }
    var livePartials: Bool { false }
    func prepare() {}
    func shutdown() {}

    func transcribe(samples: [Float], hints: [String], previous: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gv-\(UUID().uuidString).wav")
        try WAV.write(samples, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(wav: url, hints: hints, previous: previous)
    }
}

/// Apple's built-in recognizer, forced on-device. Needs Siri & Dictation enabled.
final class AppleTranscriber: Transcriber {
    let name = "Apple on-device"
    private let recognizer: SFSpeechRecognizer

    init() {
        let preferred = SFSpeechRecognizer(locale: Locale.current)
        recognizer = (preferred?.supportsOnDeviceRecognition == true ? preferred : nil)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(wav: URL, hints: [String], previous: String) async throws -> String {
        let req = SFSpeechURLRecognitionRequest(url: wav)
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.shouldReportPartialResults = false
        req.taskHint = .dictation
        req.contextualStrings = hints
        return try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true; c.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    done = true
                    // "No speech detected" is not a failure — the clip was just silent.
                    if (error as NSError).code == 1110 { c.resume(returning: "") } else { c.resume(throwing: error) }
                }
            }
        }
    }
}

/// whisper.cpp (`brew install whisper-cpp`) with a ggml model in
/// ~/Library/Application Support/GazeVoice/models/. Keeps `whisper-server` resident while
/// you're dictating — started on key-down so the model loads while you speak — and stops it
/// after a few idle minutes so ~700MB isn't held all day. Falls back to the one-shot CLI.
final class WhisperTranscriber: Transcriber {
    let cli: URL
    let server: URL?
    let model: URL
    var name: String { "Whisper (\(model.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: "")))" }

    private let port = 18178
    private let idleSeconds = 300.0
    private var process: Process?
    private var ready: Task<Bool, Never>?
    private var idleStop: DispatchWorkItem?

    init?() {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let fm = FileManager.default
        guard let dir = dirs.first(where: { fm.isExecutableFile(atPath: $0 + "/whisper-cli") }),
              let model = (try? fm.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: nil))?
                .filter({ $0.pathExtension == "bin" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        else { return nil }
        cli = URL(fileURLWithPath: dir + "/whisper-cli")
        server = fm.isExecutableFile(atPath: dir + "/whisper-server") ? URL(fileURLWithPath: dir + "/whisper-server") : nil
        self.model = model
    }

    /// Main thread. Cheap to call repeatedly.
    func prepare() {
        idleStop?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.shutdown() }
        idleStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleSeconds, execute: item)
        guard let server, process?.isRunning != true else { return }
        let p = Process()
        p.executableURL = server
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-l", "auto"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.info("whisper-server failed to start: \(error)"); return }
        process = p
        let port = port
        let t0 = Date()
        ready = Task.detached {
            for _ in 0..<600 {  // up to 60s (first run compiles Metal shaders)
                if (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)) != nil {
                    Log.info(String(format: "whisper-server ready in %.1fs", Date().timeIntervalSince(t0)))
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        Log.info("whisper-server starting (pid \(p.processIdentifier))")
    }

    func shutdown() {
        guard let p = process else { return }
        if p.isRunning { p.terminate() }
        process = nil; ready = nil
        Log.info("whisper-server stopped")
    }

    func transcribe(wav: URL, hints: [String], previous: String) async throws -> String {
        await MainActor.run { prepare() }
        let prompt = (hints + (previous.isEmpty ? [] : [String(previous.suffix(200))])).joined(separator: ", ")
        if let ready, await ready.value {
            do { return clean(try await viaServer(wav: wav, prompt: prompt)) } catch {
                Log.info("whisper-server request failed, using CLI: \(error)")
            }
        }
        return clean(try await viaCLI(wav: wav, prompt: prompt))
    }

    private func viaServer(wav: URL, prompt: String) async throws -> String {
        var form = Multipart()
        form.field("response_format", "text")
        form.field("prompt", prompt)
        form.file("file", filename: "a.wav", type: "audio/wav", data: try Data(contentsOf: wav))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: form.body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "whisper", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func viaCLI(wav: URL, prompt: String) async throws -> String {
        let p = Process()
        p.executableURL = cli
        p.arguments = ["-m", model.path, "-f", wav.path, "-nt", "-np", "-l", "auto", "--prompt", prompt]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "whisper", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "whisper-cli exited \(p.terminationStatus)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "[BLANK_AUDIO]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Wispr Flow's REST API, one call per phrase (~0.4s server time). Their WebSocket API only
/// returns text at the end, so per-phrase REST gets text in sooner. Tells Flow it's dictating
/// into an AI app and what came before, which it uses for casing and punctuation.
final class WisprTranscriber: Transcriber {
    let name = "Wispr Flow"
    var needsKey: Bool { true }

    func transcribe(wav: URL, hints: [String], previous: String) async throws -> String {
        guard let key = Keychain.get("wispr") else { throw EngineError.missingKey("Wispr Flow") }
        let body: [String: Any] = [
            "audio": try Data(contentsOf: wav).base64EncodedString(),
            "language": Settings.languages,
            "context": [
                "app": ["type": "ai"],
                "dictionary_context": hints,
                "textbox_contents": ["before_text": previous, "selected_text": "", "after_text": ""],
            ],
        ]
        var req = URLRequest(url: URL(string: "https://platform-api.wisprflow.ai/api/v1/dash/api")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.http("Wispr Flow", status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return json["text"] as? String ?? ""
    }
}

enum EngineError: LocalizedError {
    case missingKey(String)
    case http(String, Int, String)
    case closed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let s): return "No \(s) API key — add one from the menu"
        case .http(let s, let code, let body): return "\(s) HTTP \(code): \(body)"
        case .closed(let s, let why): return "\(s) connection closed: \(why)"
        }
    }
}

struct Multipart {
    let boundary = "gv-\(UUID().uuidString)"
    private(set) var body = Data()
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func file(_ name: String, filename: String, type: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
