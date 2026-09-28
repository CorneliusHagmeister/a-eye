// Spike: does Apple Vision head yaw separate "looking left" from "looking right",
// and what does it cost? Prints smoothed yaw/pitch ~5x/sec plus RSS + CPU.
//
// Build: swiftc -O spike/yawprobe.swift -o spike/yawprobe
// Run:   ./spike/yawprobe [seconds=30] [fps=10]

import AVFoundation
import Darwin
import Foundation
import Vision

let args = CommandLine.arguments
let runSeconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
let targetFPS = args.count > 2 ? Double(args[2]) ?? 10 : 10

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec)
        + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "vision")
    let request = VNDetectFaceRectanglesRequest()
    let seqHandler = VNSequenceRequestHandler()
    var lastProcessed = 0.0
    var smoothYaw: Double?
    var smoothPitch: Double?
    var frames = 0
    var noFace = 0
    var visionTime = 0.0

    func start() throws {
        request.revision = VNDetectFaceRectanglesRequestRevision3  // yaw + pitch + roll
        session.sessionPreset = (ProcessInfo.processInfo.environment["GV_LOWRES"] != nil || CommandLine.arguments.count > 3) ? .cif352x288 : .vga640x480
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }
        print("camera: \(device.localizedName)")
        session.addInput(try AVCaptureDeviceInput(device: device))
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcessed >= 1 / targetFPS, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastProcessed = now
        let t0 = CACurrentMediaTime()
        try? seqHandler.perform([request], on: px, orientation: .up)
        visionTime += CACurrentMediaTime() - t0
        frames += 1
        // Largest face = the person at the laptop.
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let yaw = face.yaw?.doubleValue else { noFace += 1; return }
        let y = yaw * 180 / .pi
        let p = (face.pitch?.doubleValue ?? 0) * 180 / .pi
        let a = 0.4  // EMA
        smoothYaw = smoothYaw.map { $0 + a * (y - $0) } ?? y
        smoothPitch = smoothPitch.map { $0 + a * (p - $0) } ?? p
    }
}

let probe = Probe()
switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized: break
case .notDetermined:
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
    sem.wait()
default:
    print("camera access denied — grant it in System Settings > Privacy > Camera"); exit(1)
}
do { try probe.start() } catch { print("error: \(error.localizedDescription)"); exit(1) }

let t0 = Date()
let cpu0 = cpuSeconds()
var peakRSS = 0.0
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    let rss = rssMB(); peakRSS = max(peakRSS, rss)
    let yaw = probe.smoothYaw.map { String(format: "%+6.1f", $0) } ?? "  —  "
    let pitch = probe.smoothPitch.map { String(format: "%+6.1f", $0) } ?? "  —  "
    let side = probe.smoothYaw.map { $0 > 5 ? "RIGHT →" : $0 < -5 ? "← LEFT " : "center " } ?? "no face"
    print("yaw \(yaw)°  pitch \(pitch)°  \(side)   rss \(String(format: "%.0f", rss))MB")
    if Date().timeIntervalSince(t0) >= runSeconds {
        let el = Date().timeIntervalSince(t0)
        print(String(format: "\n--- %.0fs: %d frames (%.1f fps), no-face %d, vision avg %.1fms/frame, CPU %.1f%% of one core, peak RSS %.0fMB",
                     el, probe.frames, Double(probe.frames) / el, probe.noFace,
                     probe.visionTime / Double(max(probe.frames, 1)) * 1000,
                     (cpuSeconds() - cpu0) / el * 100, peakRSS))
        exit(0)
    }
}
RunLoop.main.run()
