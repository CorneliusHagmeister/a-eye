import CoreML
import Foundation
import Vision

/// Optional learned gaze model: MobileOne-S0 from yakhyo/gaze-estimation, converted to Core ML
/// by tools/convert_gaze_coreml.py (face crop → yaw/pitch in degrees, runs on the Neural
/// Engine). The weights are Gaze360-trained — research / non-commercial use only — so the model
/// isn't bundled: it lives in Application Support and the app works without it.
enum LearnedGaze {
    static let package = Paths.models.appendingPathComponent("GazeMobileOne.mlpackage")
    private static let compiled = Paths.support.appendingPathComponent("compiled/GazeMobileOne.mlmodelc")

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: package.path) }

    /// Vision request for the model, compiling the package on first use (and after updates).
    static func request() -> VNCoreMLRequest? {
        guard isInstalled else { return nil }
        let fm = FileManager.default
        let pkgDate = (try? fm.attributesOfItem(atPath: package.path)[.modificationDate] as? Date) ?? .distantPast
        let binDate = (try? fm.attributesOfItem(atPath: compiled.path)[.modificationDate] as? Date) ?? .distantPast
        if !fm.fileExists(atPath: compiled.path) || binDate < pkgDate {
            do {
                let tmp = try MLModel.compileModel(at: package)
                try? fm.removeItem(at: compiled)
                try fm.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: compiled)
                Log.info("learned gaze: compiled model")
            } catch {
                Log.info("learned gaze: compile failed: \(error)"); return nil
            }
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let ml = try? MLModel(contentsOf: compiled, configuration: config),
              let vn = try? VNCoreMLModel(for: ml) else { Log.info("learned gaze: load failed"); return nil }
        let r = VNCoreMLRequest(model: vn)
        r.imageCropAndScaleOption = .scaleFill  // the crop below is already square in pixels
        return r
    }

    /// Square face crop (Vision-normalised, origin bottom-left), padded like the model's
    /// training crops — the same crop tools/eval_gaze.py uses.
    static func crop(_ face: CGRect, width w: CGFloat, height h: CGFloat, scale: CGFloat = 1.15) -> CGRect {
        let side = max(face.width * w, face.height * h) * scale
        let cx = face.midX * w, cy = face.midY * h
        let r = CGRect(x: (cx - side / 2) / w, y: (cy - side / 2) / h, width: side / w, height: side / h)
        return r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
