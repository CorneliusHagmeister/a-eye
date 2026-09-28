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
    /// Pupil position inside the eye outline, in eye-widths (both eyes averaged) — the eyes'
    /// own contribution on top of where the head points. + x = looking to your left.
    var pupilX: Double = 0
    var pupilY: Double = 0
    var hasEyes = false
    var time: CFTimeInterval
}

/// Webcam → Apple Vision: face rectangle (rev 3 gives head yaw/pitch, position, size) plus
/// face landmarks for the pupils, at 720p so the eyes have enough pixels (~40px wide).
/// Low frame rate: 8 fps is plenty to pick a window.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the main queue for every processed frame; nil = no face.
    var onSample: ((GazeSample?) -> Void)?
    /// Raw frame + face box + sample, on the vision queue (for recording test sets).
    var frameTap: ((CVPixelBuffer, CGRect?, GazeSample?) -> Void)?
    private(set) var latest: GazeSample?
    private(set) var isRunning = false

    private let fps: Int32 = 8
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "gaze.vision")
    private let request = VNDetectFaceRectanglesRequest()
    private let landmarks = VNDetectFaceLandmarksRequest()
    private var pupilX: Double?
    private var pupilY: Double?
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
        yaw = nil; pitch = nil; faceX = nil; faceY = nil; faceSize = nil; pupilX = nil; pupilY = nil
        onSample?(nil)
    }

    private func configure() throws {
        request.revision = VNDetectFaceRectanglesRequestRevision3
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        guard let dev = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "gaze", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }
        device = dev
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
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
            // Landmarks on the face we already found (no second detection pass).
            landmarks.inputFaceObservations = [face]
            try? handler.perform([landmarks], on: px, orientation: .up)
            let size = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
            if let lm = landmarks.results?.first?.landmarks, let p = Self.pupils(lm, imageSize: size) {
                pupilX = pupilX.map { $0 + a * (p.x - $0) } ?? p.x
                pupilY = pupilY.map { $0 + a * (p.y - $0) } ?? p.y
            }  // blink / eyes not found: hold the last pupil values
            sample = GazeSample(yaw: yaw!, pitch: pitch!, faceX: faceX!, faceY: faceY!, faceSize: faceSize!,
                                pupilX: pupilX ?? 0, pupilY: pupilY ?? 0, hasEyes: pupilX != nil, time: now)
        }
        frameTap?(px, request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox, sample)
        DispatchQueue.main.async { [self] in
            if let sample { latest = sample }
            onSample?(sample)
        }
    }

    /// Pupil offset from each eye outline's centre, in eye-widths, averaged over both eyes.
    /// Returns nil during a blink (outline nearly flat), when the pupil landmark is unreliable.
    static func pupils(_ lm: VNFaceLandmarks2D, imageSize: CGSize) -> (x: Double, y: Double)? {
        func one(_ eye: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> (Double, Double)? {
            guard let e = eye?.pointsInImage(imageSize: imageSize), e.count > 2,
                  let p = pupil?.pointsInImage(imageSize: imageSize).first else { return nil }
            let xs = e.map(\.x), ys = e.map(\.y)
            let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
            guard w > 4, h / w > 0.12 else { return nil }  // closed eye
            let cx = xs.reduce(0, +) / Double(xs.count), cy = ys.reduce(0, +) / Double(ys.count)
            return ((p.x - cx) / w, (p.y - cy) / w)
        }
        guard let l = one(lm.leftEye, lm.leftPupil), let r = one(lm.rightEye, lm.rightPupil) else { return nil }
        return ((l.0 + r.0) / 2, (l.1 + r.1) / 2)
    }
}
