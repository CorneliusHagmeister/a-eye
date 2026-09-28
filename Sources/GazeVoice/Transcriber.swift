import Foundation
import Speech

protocol Transcriber {
    var name: String { get }
    /// Called on talk-key down so slow engines can warm up while you speak.
    func prepare()
    func shutdown()
    func transcribe(wav: URL, hints: [String]) async throws -> String
}

extension Transcriber {
    func prepare() {}
    func shutdown() {}
}

/// Apple's built-in recognizer, forced on-device. No download, decent quality.
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

    func transcribe(wav: URL, hints: [String]) async throws -> String {
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
/// after a few idle minutes so ~1GB isn't held all day. Falls back to the one-shot CLI.
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
        Log.info("whisper-server stopped (idle)")
    }

    func transcribe(wav: URL, hints: [String]) async throws -> String {
        await MainActor.run { prepare() }
        if let ready, await ready.value {
            do { return clean(try await viaServer(wav: wav, hints: hints)) } catch {
                Log.info("whisper-server request failed, using CLI: \(error)")
            }
        }
        return clean(try await viaCLI(wav: wav, hints: hints))
    }

    private func viaServer(wav: URL, hints: [String]) async throws -> String {
        let boundary = "gv-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "text")
        field("prompt", hints.joined(separator: ", "))
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wav))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "whisper", code: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func viaCLI(wav: URL, hints: [String]) async throws -> String {
        let p = Process()
        p.executableURL = cli
        p.arguments = ["-m", model.path, "-f", wav.path, "-nt", "-np", "-l", "auto",
                       "--prompt", hints.joined(separator: ", ")]
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
        s.replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
