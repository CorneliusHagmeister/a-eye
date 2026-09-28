import AVFoundation
import Vision

struct GazeSample {
    var yaw: Double    // degrees, + = turned towards the camera's right (your left)
    var pitch: Double  // degrees
    /// Face centre in the camera image (0…1) — where your head is, not just where it points.
    var faceX: Double = 0.5
    var faceY: Double = 0.5
    /// Face width as a fraction of the image — shrinks as you lean back.
    var faceSize: Double = 0.2
    var time: CFTimeInterval
}

/// Webcam → Apple Vision face rectangles (rev 3 gives yaw/pitch) → smoothed head direction.
/// Runs the camera at a low frame rate: we only need "which window", not eye-level precision.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue for every processed frame; nil = no face.
    var onSample: ((GazeSample?) -> Void)?
    private(set) var latest: GazeSample?
    private(set) var isRunning = false

    private let fps: Int32 = 8
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "gaze.vision")
    private let request = VNDetectFaceRectanglesRequest()
    private let handler = VNSequenceRequestHandler()
    private var device: AVCaptureDevice?
    private var yaw: Double?
    private var pitch: Double?
    private var faceX: Double?
    private var faceY: Double?
    private var faceSize: Double?
    private var lastProcessed: CFTimeInterval = 0

    func start() {
        guard !isRunning else { return }
        if device == nil {
            do { try configure() } catch { Log.info("gaze: configure failed: \(error)"); return }
        }
        queue.async { [self] in
            session.startRunning()
            throttleCamera()  // presets reset frame duration on start, so set it after
            Log.info("gaze: camera running (\(device?.localizedName ?? "?"))")
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        queue.async { [self] in session.stopRunning() }
        isRunning = false
        latest = nil
        yaw = nil; pitch = nil; faceX = nil; faceY = nil; faceSize = nil
        onSample?(nil)
    }

    private func configure() throws {
        request.revision = VNDetectFaceRectanglesRequestRevision3
        guard let dev = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "gaze", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }
        device = dev
        session.beginConfiguration()
        session.sessionPreset = .cif352x288
        session.addInput(try AVCaptureDeviceInput(device: dev))
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.commitConfiguration()
    }

    private func throttleCamera() {
        guard let dev = device, (try? dev.lockForConfiguration()) != nil else { return }
        let ok = dev.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) }
        if ok {
            let d = CMTime(value: 1, timescale: fps)
            dev.activeVideoMinFrameDuration = d
            dev.activeVideoMaxFrameDuration = d
        }
        dev.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        // Belt and braces in case the camera ignored the frame-rate cap.
        guard now - lastProcessed >= 0.9 / Double(fps), let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastProcessed = now
        try? handler.perform([request], on: px, orientation: .up)
        var sample: GazeSample?
        if let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
           let y = face.yaw?.doubleValue {
            let yd = y * 180 / .pi
            let pd = (face.pitch?.doubleValue ?? 0) * 180 / .pi
            let a = 0.5
            yaw = yaw.map { $0 + a * (yd - $0) } ?? yd
            pitch = pitch.map { $0 + a * (pd - $0) } ?? pd
            let fx = Double(face.boundingBox.midX), fy = Double(face.boundingBox.midY)
            faceX = faceX.map { $0 + a * (fx - $0) } ?? fx
            faceY = faceY.map { $0 + a * (fy - $0) } ?? fy
            let fs = Double(face.boundingBox.width)
            faceSize = faceSize.map { $0 + a * (fs - $0) } ?? fs
            sample = GazeSample(yaw: yaw!, pitch: pitch!, faceX: faceX!, faceY: faceY!, faceSize: faceSize!, time: now)
        }
        DispatchQueue.main.async { [self] in
            if let sample { latest = sample }
            onSample?(sample)
        }
    }
}
