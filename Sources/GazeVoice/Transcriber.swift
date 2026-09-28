import Foundation
import Speech

protocol Transcriber {
    var name: String { get }
    func transcribe(wav: URL, hints: [String]) async throws -> String
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

/// whisper.cpp CLI, if installed (`brew install whisper-cpp`) with a ggml model in
/// ~/Library/Application Support/GazeVoice/models/.
final class WhisperTranscriber: Transcriber {
    let binary: URL
    let model: URL
    var name: String { "Whisper (\(model.deletingPathExtension().lastPathComponent))" }

    init?() {
        let bins = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        guard let bin = bins.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let model = (try? FileManager.default.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: nil))?
                .filter({ $0.pathExtension == "bin" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        else { return nil }
        binary = URL(fileURLWithPath: bin)
        self.model = model
    }

    func transcribe(wav: URL, hints: [String]) async throws -> String {
        let p = Process()
        p.executableURL = binary
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
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
