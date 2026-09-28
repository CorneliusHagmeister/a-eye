import AVFoundation
import AppKit
import Vision

/// `AEye --pupil-test` — does Vision's pupil landmark follow the eyes when the head stays
/// still? Shows a dot on the built-in display; you follow it with your eyes only. Logs, per
/// dot position, the pupil offset inside the eye outline next to head yaw/pitch, then how
/// well each signal separates the positions.
final class PupilProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private struct Frame { var px, py, yaw, pitch: Double }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pupil")
    private let request = VNDetectFaceLandmarksRequest()
    private let dot = TargetDot()
    private let hud = HUD()
    private var collecting: String?
    private var frames: [String: [Frame]] = [:]
    private var visionMs: [Double] = []
    private var lastFrame: CFTimeInterval = 0

    func run() {
        request.revision = VNDetectFaceLandmarksRequestRevision3
        guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else {
            Log.info("pupil-test: no camera"); exit(1)
        }
        session.sessionPreset = .hd1280x720  // eyes need pixels: ~40px wide here vs ~12 at CIF
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        queue.async { self.session.startRunning() }

        let screen = NSScreen.screens.first { $0.localizedName.contains("Built-in") } ?? NSScreen.main!
        let h = AX.primaryScreenHeight, f = screen.visibleFrame
        func at(_ fx: Double, _ fy: Double) -> CGPoint {
            CGPoint(x: f.minX + f.width * fx, y: h - (f.minY + f.height * (1 - fy)))
        }
        let steps: [(String, CGPoint)] = [("centre", at(0.5, 0.5)), ("left", at(0.04, 0.5)), ("right", at(0.96, 0.5)),
                                          ("centre2", at(0.5, 0.5)), ("up", at(0.5, 0.05)), ("down", at(0.5, 0.95))]
        hud.show("Pupil test: keep your HEAD STILL and follow the red dot with your EYES only — starting in 4s")
        var t = 4.0
        for (name, p) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [self] in
                dot.show(at: p); hud.show("Eyes only → \(name.replacingOccurrences(of: "2", with: ""))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 1.0) { [self] in collecting = name }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 3.0) { [self] in collecting = nil }
            t += 3.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { [self] in
            dot.hide(); hud.hide(); session.stopRunning(); report(); exit(0)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame > 0.08, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastFrame = now
        let t0 = CACurrentMediaTime()
        try? VNImageRequestHandler(cvPixelBuffer: px, orientation: .up).perform([request])
        let ms = (CACurrentMediaTime() - t0) * 1000
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = face.landmarks else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
        // Pupil position relative to the eye outline's centre, in eye-widths.
        func offset(_ eye: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> (Double, Double)? {
            guard let e = eye?.pointsInImage(imageSize: size), e.count > 2,
                  let p = pupil?.pointsInImage(imageSize: size).first else { return nil }
            let xs = e.map(\.x), ys = e.map(\.y)
            let w = (xs.max()! - xs.min()!), cx = xs.reduce(0, +) / Double(xs.count), cy = ys.reduce(0, +) / Double(ys.count)
            guard w > 1 else { return nil }
            return ((p.x - cx) / w, (p.y - cy) / w)
        }
        guard let l = offset(lm.leftEye, lm.leftPupil), let r = offset(lm.rightEye, lm.rightPupil) else { return }
        let f = Frame(px: (l.0 + r.0) / 2, py: (l.1 + r.1) / 2,
                      yaw: (face.yaw?.doubleValue ?? 0) * 180 / .pi, pitch: (face.pitch?.doubleValue ?? 0) * 180 / .pi)
        DispatchQueue.main.async { [self] in
            visionMs.append(ms)
            if let c = collecting { frames[c, default: []].append(f) }
        }
    }

    private func report() {
        func stats(_ v: [Double]) -> (m: Double, s: Double) {
            let m = v.reduce(0, +) / Double(max(v.count, 1))
            return (m, (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(v.count, 1))).squareRoot())
        }
        for name in ["centre", "left", "right", "centre2", "up", "down"] {
            let fs = frames[name] ?? []
            let px = stats(fs.map(\.px)), py = stats(fs.map(\.py)), yaw = stats(fs.map(\.yaw)), pitch = stats(fs.map(\.pitch))
            Log.info(String(format: "%-8@ n=%2d  pupilX %+.3f±%.3f  pupilY %+.3f±%.3f  | head yaw %+5.1f°±%.1f  pitch %+5.1f°±%.1f",
                            name, fs.count, px.m, px.s, py.m, py.s, yaw.m, yaw.s, pitch.m, pitch.s))
        }
        // Separation: gap between the two means in units of the pooled spread (>3 = clean signal).
        func sep(_ a: String, _ b: String, _ k: KeyPath<Frame, Double>) -> Double {
            let x = stats((frames[a] ?? []).map { $0[keyPath: k] }), y = stats((frames[b] ?? []).map { $0[keyPath: k] })
            return abs(x.m - y.m) / max(((x.s * x.s + y.s * y.s) / 2).squareRoot(), 1e-6)
        }
        Log.info(String(format: "separation left↔right: pupil %.1f vs head yaw %.1f  |  up↔down: pupil %.1f vs head pitch %.1f",
                        sep("left", "right", \.px), sep("left", "right", \.yaw), sep("up", "down", \.py), sep("up", "down", \.pitch)))
        let ms = visionMs.sorted()
        Log.info(String(format: "landmarks at 720p: median %.1fms/frame over %d frames", ms.isEmpty ? 0 : ms[ms.count / 2], ms.count))
    }
}
