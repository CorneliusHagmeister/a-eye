import Foundation

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GazeVoice.log")
    private static let queue = DispatchQueue(label: "log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func info(_ message: String) {
        let line = "\(fmt.string(from: Date())) \(message)\n"
        print(line, terminator: "")
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GazeVoice")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let recordings: URL = {
        let u = support.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let models = support.appendingPathComponent("models")
    static let targets = support.appendingPathComponent("targets.json")
    static let history = support.appendingPathComponent("history.jsonl")
}

enum Settings {
    private static let d = UserDefaults.standard
    static var autoSubmit: Bool {
        get { d.bool(forKey: "autoSubmit") }
        set { d.set(newValue, forKey: "autoSubmit") }
    }
    static var showGazeInMenuBar: Bool {
        get { d.object(forKey: "showGazeInMenuBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showGazeInMenuBar") }
    }
    /// Speech engine id (see `Engines.catalog`).
    static var engine: String {
        get { d.string(forKey: "engine") ?? "parakeet" }
        set { d.set(newValue, forKey: "engine") }
    }
    /// Languages you dictate in (ISO 639-1). Cloud engines use it to skip/limit detection.
    static var languages: [String] {
        get { d.stringArray(forKey: "languages") ?? ["en", "de"] }
        set { d.set(newValue, forKey: "languages") }
    }
    /// Seconds the mic stays open after a recording so the next one has pre-roll and no start lag.
    static var micWarmSeconds: Double {
        get { d.object(forKey: "micWarmSeconds") as? Double ?? 20 }
        set { d.set(newValue, forKey: "micWarmSeconds") }
    }
}
