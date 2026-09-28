import Foundation

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/A-EYE.log")
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("A-EYE")
        // Renamed from GazeVoice: bring calibration, recordings and models along.
        let old = base.appendingPathComponent("GazeVoice")
        if !FileManager.default.fileExists(atPath: u.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: u)
        }
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
    static let gazeModel = support.appendingPathComponent("gaze-model-v3.json")
    static let gazeCalibration = support.appendingPathComponent("gaze-calibration-v3.json")
}

enum Settings {
    private static let d = UserDefaults.standard
    static var autoSubmit: Bool {
        get { d.bool(forKey: "autoSubmit") }
        set { d.set(newValue, forKey: "autoSubmit") }
    }
    /// Paste each phrase as you pause (true) or everything at once on key release (false).
    static var pasteWhileSpeaking: Bool {
        get { d.object(forKey: "pasteWhileSpeaking") as? Bool ?? true }
        set { d.set(newValue, forKey: "pasteWhileSpeaking") }
    }
    /// Transcript clean-up before pasting: "off", "basic" (local) or "openai".
    static var cleanup: String {
        get { d.string(forKey: "cleanup") ?? "basic" }
        set { d.set(newValue, forKey: "cleanup") }
    }
    static var cleanupModel: String {
        get { d.string(forKey: "cleanupModel") ?? "gpt-6-luna" }
        set { d.set(newValue, forKey: "cleanupModel") }
    }
    /// Use the learned gaze model (if installed) alongside head pose and pupils.
    static var learnedGaze: Bool {
        get { d.object(forKey: "learnedGaze") as? Bool ?? true }
        set { d.set(newValue, forKey: "learnedGaze") }
    }
    static var showGazePointer: Bool {
        get { d.bool(forKey: "showGazePointer") }
        set { d.set(newValue, forKey: "showGazePointer") }
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
