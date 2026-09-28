import CoreImage
import Foundation

/// Saves camera frames with their calibration labels during a recorded onboarding run, as a
/// real test set for comparing gaze approaches offline (e.g. learned gaze models vs. pupils).
/// Output: frame-NNNNN.jpg + frames.jsonl in a timestamped folder.
final class GazeRecorder {
    let dir: URL
    private let lines: FileHandle
    private let ctx = CIContext()
    private let lock = NSLock()
    private var current: (step: Int, label: String, dot: CGPoint)?
    private var count = 0

    init?() {
        dir = Paths.support.appendingPathComponent("gaze-recordings/\(Delivery.stamp())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("frames.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: file) else { return nil }
        lines = h
    }

    /// Which dot is being collected right now (nil between dots). Main thread.
    func setStep(_ step: (Int, String, CGPoint)?) {
        lock.lock(); current = step.map { (step: $0.0, label: $0.1, dot: $0.2) }; lock.unlock()
    }

    /// Called from the tracker's vision queue for every processed frame.
    func frame(_ px: CVPixelBuffer, face: CGRect?, sample: GazeSample?) {
        lock.lock(); let cur = current; lock.unlock()
        guard let cur, let face, let s = sample else { return }
        count += 1
        let name = String(format: "frame-%05d.jpg", count)
        let img = CIImage(cvPixelBuffer: px)
        guard let jpg = ctx.jpegRepresentation(of: img, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
        else { return }
        try? jpg.write(to: dir.appendingPathComponent(name))
        let row: [String: Any] = [
            "file": name, "step": cur.step, "label": cur.label, "dotX": cur.dot.x, "dotY": cur.dot.y,
            "yaw": s.yaw, "pitch": s.pitch, "faceX": s.faceX, "faceY": s.faceY, "faceSize": s.faceSize,
            "pupilX": s.pupilX, "pupilY": s.pupilY, "hasEyes": s.hasEyes,
            "bbox": [face.minX, face.minY, face.width, face.height],  // Vision: normalised, origin bottom-left
            "w": CVPixelBufferGetWidth(px), "h": CVPixelBufferGetHeight(px),
        ]
        if var d = try? JSONSerialization.data(withJSONObject: row) { d.append(0x0A); lines.write(d) }
    }

    func close() -> Int { try? lines.close(); return count }
}
