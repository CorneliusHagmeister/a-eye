import AppKit

/// Maps where your head is and where it points to a point on the screens.
///
/// Geometric, not a black-box fit: face size in the image gives your distance, face position
/// gives your lateral offset, and a ray cast along the head direction is intersected with the
/// plane of the screens. Calibration only learns how that plane maps onto your monitors (a
/// smooth quadratic) and how much your eyes add on top of your head turn (`gx`, `gy`). So
/// leaning back or shifting sideways moves the estimate the way it physically should.
/// Head tracking, not eye tracking: expect a couple of hundred px of error.
struct GazeModel: Codable {
    var gx: Double
    var gy: Double
    var cx: [Double]
    var cy: [Double]
    /// Leave-one-out median error over the calibration points, in points.
    var errorPx: Double
    var points: Int
    /// Distances (model units) the calibration covered; outside this, suggest adding a posture.
    var hzMin: Double
    var hzMax: Double

    // Rough FaceTime-camera field of view (tan of half-angles) for the CIF preset.
    static let tanH = 0.58, tanV = 0.47

    static func load() -> GazeModel? {
        guard let d = try? Data(contentsOf: Paths.gazeModel) else { return nil }
        return try? JSONDecoder().decode(GazeModel.self, from: d)
    }

    func save() { try? JSONEncoder().encode(self).write(to: Paths.gazeModel) }

    /// Distance to the camera in arbitrary units (≈1 at a typical desk distance).
    static func distance(_ s: GazeSample) -> Double { 0.2 / max(s.faceSize, 0.02) }

    /// Where the head ray meets the screen plane, in head-distance units; signs follow the
    /// global screen axes (x right, y down). Yaw is + when looking to your left, pitch − up.
    static func plane(_ s: GazeSample, gx: Double, gy: Double) -> (u: Double, v: Double) {
        let hz = distance(s)
        let yaw = s.yaw * .pi / 180, pitch = s.pitch * .pi / 180
        let u = -((s.faceX - 0.5) * 2 * tanH * hz + gx * hz * tan(yaw))
        let v = -(s.faceY - 0.5) * 2 * tanV * hz + gy * hz * tan(pitch)
        return (u, v)
    }

    static func features(_ u: Double, _ v: Double, quadratic: Bool) -> [Double] {
        quadratic ? [1, u, v, u * u, v * v, u * v] : [1, u, v]
    }

    var quadratic: Bool { cx.count > 3 }

    func predict(_ s: GazeSample) -> CGPoint {
        let (u, v) = Self.plane(s, gx: gx, gy: gy)
        let f = Self.features(u, v, quadratic: quadratic)
        return CGPoint(x: zip(f, cx).map(*).reduce(0, +), y: zip(f, cy).map(*).reduce(0, +))
    }

    func isOutsideCalibratedPosture(_ s: GazeSample) -> Bool {
        let hz = Self.distance(s)
        return hz > hzMax * 1.2 || hz < hzMin / 1.2
    }

    /// Grid-searches the eye gain per axis (with a mild prior at 1.3 — from one posture it's
    /// barely identifiable) and fits the plane→screen mapping by least squares for each.
    static func fit(_ data: [(GazeSample, CGPoint)]) -> GazeModel? {
        guard data.count >= 5 else { return nil }
        let quadratic = data.count >= 12
        let gains = stride(from: 0.6, through: 2.4, by: 0.1).map { $0 }
        let prior = 3000.0 * Double(data.count)  // px² per unit² of gain away from 1.3
        var best: (gx: Double, gy: Double, cx: [Double], cy: [Double], cost: Double)?
        for gx in gains { for gy in gains {
            let uv = data.map { plane($0.0, gx: gx, gy: gy) }
            let X = uv.map { features($0.u, $0.v, quadratic: quadratic) }
            let tx = data.map { Double($0.1.x) }, ty = data.map { Double($0.1.y) }
            guard let cx = solve(X, tx), let cy = solve(X, ty) else { continue }
            var sse = 0.0
            for (i, f) in X.enumerated() {
                let px = zip(f, cx).map(*).reduce(0, +), py = zip(f, cy).map(*).reduce(0, +)
                sse += (px - tx[i]) * (px - tx[i]) + (py - ty[i]) * (py - ty[i])
            }
            let cost = sse + prior * ((gx - 1.3) * (gx - 1.3) + (gy - 1.3) * (gy - 1.3))
            if best == nil || cost < best!.cost { best = (gx, gy, cx, cy, cost) }
        } }
        guard let b = best else { return nil }
        var errors: [Double] = []
        for i in data.indices {  // leave-one-out at the chosen gains: honest runtime error
            var rest = data; rest.remove(at: i)
            let X = rest.map { d -> [Double] in let (u, v) = plane(d.0, gx: b.gx, gy: b.gy); return features(u, v, quadratic: quadratic) }
            guard let ax = solve(X, rest.map { Double($0.1.x) }), let ay = solve(X, rest.map { Double($0.1.y) }) else { continue }
            let m = GazeModel(gx: b.gx, gy: b.gy, cx: ax, cy: ay, errorPx: 0, points: 0, hzMin: 0, hzMax: 0)
            let p = m.predict(data[i].0)
            errors.append(hypot(p.x - data[i].1.x, p.y - data[i].1.y))
        }
        errors.sort()
        let hz = data.map { distance($0.0) }
        return GazeModel(gx: b.gx, gy: b.gy, cx: b.cx, cy: b.cy,
                         errorPx: errors.isEmpty ? 0 : errors[errors.count / 2], points: data.count,
                         hzMin: hz.min() ?? 1, hzMax: hz.max() ?? 1)
    }

    private static func solve(_ X: [[Double]], _ y: [Double], lambda: Double = 1e-6) -> [Double]? {
        let n = X.first?.count ?? 0
        var A = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for (row, t) in zip(X, y) {
            for i in 0..<n {
                for j in 0..<n { A[i][j] += row[i] * row[j] }
                A[i][n] += row[i] * t
            }
        }
        for i in 1..<n { A[i][i] += lambda }  // don't shrink the intercept
        for c in 0..<n {  // Gaussian elimination with partial pivoting
            guard let piv = (c..<n).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[piv][c]) > 1e-12 else { return nil }
            A.swapAt(c, piv)
            for r in 0..<n where r != c {
                let k = A[r][c] / A[c][c]
                for j in c...n { A[r][j] -= k * A[c][j] }
            }
        }
        return (0..<n).map { A[$0][n] / A[$0][$0] }
    }
}

/// Raw calibration samples, kept so extra postures can be added and the model refit.
enum CalibrationData {
    struct Point: Codable { var yaw, pitch, faceX, faceY, faceSize, x, y: Double }

    static func load() -> [(GazeSample, CGPoint)] {
        guard let d = try? Data(contentsOf: Paths.gazeCalibration),
              let pts = try? JSONDecoder().decode([Point].self, from: d) else { return [] }
        return pts.map { (GazeSample(yaw: $0.yaw, pitch: $0.pitch, faceX: $0.faceX, faceY: $0.faceY,
                                     faceSize: $0.faceSize, time: 0), CGPoint(x: $0.x, y: $0.y)) }
    }

    static func save(_ data: [(GazeSample, CGPoint)]) {
        let pts = data.map { Point(yaw: $0.0.yaw, pitch: $0.0.pitch, faceX: $0.0.faceX, faceY: $0.0.faceY,
                                   faceSize: $0.0.faceSize, x: Double($0.1.x), y: Double($0.1.y)) }
        try? JSONEncoder().encode(pts).write(to: Paths.gazeCalibration)
    }
}

/// Runs the dot sequence over every display: settle, sample, next. No tapping needed.
final class ScreenCalibrator {
    var onFinish: ((GazeModel?) -> Void)?
    private let dot = TargetDot()
    private let hud: HUD
    private var points: [CGPoint] = []
    private var index = 0
    private var collecting = false
    private var samples: [GazeSample] = []
    private var data: [(GazeSample, CGPoint)] = []
    private var cancelled = false
    private var escMonitor: Any?

    init(hud: HUD) { self.hud = hud }

    var isRunning: Bool { !points.isEmpty }

    private var appending = false

    /// `addPosture`: a shorter pass (5 dots per display) added to the existing calibration —
    /// do it leaning back or sitting forward so the model sees you in more than one position.
    func start(addPosture: Bool = false) {
        appending = addPosture
        // Full: centre, both side edges, four corners. Posture: centre, edges, top, bottom.
        // Monitor by monitor, left to right, in global top-left coordinates.
        let h = AX.primaryScreenHeight
        let spots = addPosture
            ? [(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.08), (0.5, 0.92)]
            : [(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.08, 0.1), (0.92, 0.1), (0.92, 0.9), (0.08, 0.9)]
        points = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }.flatMap { screen -> [CGPoint] in
            let f = screen.visibleFrame
            return spots.map { fx, fy in
                CGPoint(x: f.minX + f.width * fx, y: h - (f.minY + f.height * (1 - fy)))
            }
        }
        index = 0; data = []; cancelled = false
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel() }
        }
        hud.show(addPosture
                 ? "New posture: sit the way you want to add (e.g. leaned back), then look at each dot — \(points.count) dots · Esc cancels"
                 : "Look at each dot as you normally would — \(points.count) dots, about \(Int(Double(points.count) * 1.8))s · Esc cancels")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.next() }
    }

    /// Fed every tracker frame.
    func add(_ s: GazeSample?) {
        if collecting, let s { samples.append(s) }
    }

    private func next() {
        guard !cancelled else { return }
        guard index < points.count else { return finish() }
        let p = points[index]
        dot.show(at: p)
        hud.show("\(index + 1) / \(points.count)")
        samples = []
        // Let your head settle on the dot, then sample it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.collecting = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.collecting = false
                if self.samples.count >= 4 {
                    let sorted = { (k: KeyPath<GazeSample, Double>) in self.samples.map { $0[keyPath: k] }.sorted()[self.samples.count / 2] }
                    let median = GazeSample(yaw: sorted(\.yaw), pitch: sorted(\.pitch), faceX: sorted(\.faceX),
                                            faceY: sorted(\.faceY), faceSize: sorted(\.faceSize), time: 0)
                    self.data.append((median, p))
                } else {
                    Log.info("calibration: no face at dot \(self.index + 1), skipped")
                }
                self.index += 1
                self.next()
            }
        }
    }

    private func finish() {
        dot.hide()
        stopMonitor()
        points = []
        let all = appending ? CalibrationData.load() + data : data
        let model = GazeModel.fit(all)
        if let model { model.save(); CalibrationData.save(all) }
        Log.info("calibration: \(data.count) new / \(all.count) total points, model \(model.map { String(format: "±%.0fpx gains %.1f/%.1f distance %.2f–%.2f", $0.errorPx, $0.gx, $0.gy, $0.hzMin, $0.hzMax) } ?? "failed")")
        onFinish?(model)
    }

    func cancel() {
        cancelled = true
        collecting = false
        points = []
        dot.hide()
        stopMonitor()
        hud.show("Calibration cancelled", hideAfter: 1.5)
    }

    private func stopMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }
}

/// A rectangle outline drawn over what dictation will go to.
final class Highlight {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 8
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.06).cgColor
        panel.contentView = v
    }

    /// `rect` in global top-left coordinates.
    func show(_ rect: CGRect) {
        panel.setFrame(AX.toCocoa(rect.insetBy(dx: -6, dy: -6)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

/// Small ring that follows the estimated gaze point (debug / calibration check).
final class GazePointer {
    private let panel: NSPanel
    private let size: CGFloat = 36

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemOrange.cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = size / 2
        panel.contentView = v
    }

    func show(at p: CGPoint) {
        let c = NSPoint(x: p.x, y: AX.primaryScreenHeight - p.y)
        panel.setFrameOrigin(NSPoint(x: c.x - size / 2, y: c.y - size / 2))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
