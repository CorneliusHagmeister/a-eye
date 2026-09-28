import AVFoundation
print("auth:", AVCaptureDevice.authorizationStatus(for: .video).rawValue, "(0 notDetermined,1 restricted,2 denied,3 authorized)")
final class D: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  var n = 0
  func captureOutput(_ o: AVCaptureOutput, didOutput s: CMSampleBuffer, from c: AVCaptureConnection) { n += 1 }
}
let s = AVCaptureSession(); let d = D()
NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { print("runtime error:", $0.userInfo ?? [:]) }
let dev = AVCaptureDevice.default(for: .video)!
s.addInput(try! AVCaptureDeviceInput(device: dev))
let out = AVCaptureVideoDataOutput(); out.setSampleBufferDelegate(d, queue: DispatchQueue(label: "q")); s.addOutput(out)
s.startRunning()
print("running:", s.isRunning)
RunLoop.main.run(until: Date().addingTimeInterval(3))
print("frames in 3s:", d.n)
