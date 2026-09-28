import CoreGraphics
import Foundation

/// A place dictation can be routed to: a window, optionally a point inside it (e.g. one
/// VS Code pane), plus the head direction you have when looking at it.
struct Target: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bundleID: String
    var appName: String
    var windowTitle: String
    /// Window frame at capture time (global top-left coords) — used to find the window again.
    var windowFrame: CGRect
    /// Click point as a fraction of the window size; nil = just raise the window.
    var clickFraction: CGPoint?
    var yaw: Double
    var pitch: Double
    var spread: Double

    /// Same window + same spot = same destination, even for targets made fresh per key press.
    var key: String {
        let c = clickFraction.map { "\(Int($0.x * 20)),\(Int($0.y * 20))" } ?? "-"
        return "\(bundleID)|\(Int(windowFrame.minX)),\(Int(windowFrame.minY)),\(Int(windowFrame.width))|\(c)"
    }

    func clickPoint(in frame: CGRect) -> CGPoint? {
        clickFraction.map { CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height) }
    }
}

final class TargetStore {
    private(set) var targets: [Target] = []
    var onChange: (() -> Void)?

    init() {
        if let data = try? Data(contentsOf: Paths.targets),
           let t = try? JSONDecoder().decode([Target].self, from: data) {
            targets = t
        }
    }

    func upsert(_ t: Target) {
        if let i = targets.firstIndex(where: { $0.id == t.id }) { targets[i] = t } else { targets.append(t) }
        save()
    }

    func remove(_ id: UUID) { targets.removeAll { $0.id == id }; save() }
    func removeAll() { targets = []; save() }
    func target(_ id: UUID?) -> Target? { targets.first { $0.id == id } }

    /// Pairs of targets whose gaze centroids are too close to tell apart reliably.
    func tooClose(minDegrees: Double = 5) -> [(Target, Target)] {
        var out: [(Target, Target)] = []
        for i in targets.indices { for j in targets.indices where j > i {
            if GazeClassifier.distance(targets[i], yaw: targets[j].yaw, pitch: targets[j].pitch) < minDegrees {
                out.append((targets[i], targets[j]))
            }
        } }
        return out
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(targets).write(to: Paths.targets)
        onChange?()
    }
}

/// Nearest-centroid over (yaw, pitch) with hysteresis so the choice doesn't flicker
/// when you look between two targets.
final class GazeClassifier {
    private(set) var current: UUID?
    private var candidate: UUID?
    private var candidateFrames = 0
    private let marginDegrees = 2.0
    private let framesToSwitch = 3  // ~0.4s at 8fps

    static func distance(_ t: Target, yaw: Double, pitch: Double) -> Double {
        let dy = t.yaw - yaw, dp = t.pitch - pitch
        return (dy * dy + dp * dp).squareRoot()
    }

    func reset() { current = nil; candidate = nil; candidateFrames = 0 }

    @discardableResult
    func update(_ s: GazeSample?, targets: [Target]) -> UUID? {
        guard let s, !targets.isEmpty else { return current }
        if let c = current, !targets.contains(where: { $0.id == c }) { current = nil }
        let ranked = targets.map { ($0.id, Self.distance($0, yaw: s.yaw, pitch: s.pitch)) }.sorted { $0.1 < $1.1 }
        let best = ranked[0]
        guard let cur = current else { current = best.0; return current }
        if best.0 == cur { candidate = nil; candidateFrames = 0; return current }
        let curDist = ranked.first { $0.0 == cur }?.1 ?? .infinity
        if best.1 + marginDegrees < curDist {
            if candidate == best.0 { candidateFrames += 1 } else { candidate = best.0; candidateFrames = 1 }
            if candidateFrames >= framesToSwitch { current = best.0; candidate = nil; candidateFrames = 0 }
        } else {
            candidate = nil; candidateFrames = 0
        }
        return current
    }
}
