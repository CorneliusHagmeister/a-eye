import AppKit

/// Maps head pose (+ where the face sits in the camera image) to a point on the screens,
/// learned from a short look-at-the-dots calibration. It's head tracking, not eye tracking,
/// so it's coarse (a few hundred px) — good enough to pick a window or half of a split pane;
/// the nearest text input does the fine targeting.
struct GazeModel: Codable {
    var quadratic: Bool
    var cx: [Double]
    var cy: [Double]
    /// Leave-one-out median error over the calibration points, in points.
    var errorPx: Double
    var points: Int

    static func load() -> GazeModel? {
        guard let d = try? Data(contentsOf: Paths.gazeModel) else { return nil }
        return try? JSONDecoder().decode(GazeModel.self, from: d)
    }

    func save() { try? JSONEncoder().encode(self).write(to: Paths.gazeModel) }

    static func features(_ s: GazeSample, quadratic: Bool) -> [Double] {
        let y = s.yaw / 30, p = s.pitch / 30, fx = (s.faceX - 0.5) * 2, fy = (s.faceY - 0.5) * 2
        return quadratic ? [1, y, p, y * y, p * p, y * p, fx, fy] : [1, y, p, fx, fy]
    }

    func predict(_ s: GazeSample) -> CGPoint {
        let f = Self.features(s, quadratic: quadratic)
        return CGPoint(x: zip(f, cx).map(*).reduce(0, +), y: zip(f, cy).map(*).reduce(0, +))
    }

    /// Ridge least squares for x and y separately.
    static func fit(_ data: [(GazeSample, CGPoint)]) -> GazeModel? {
        let quadratic = data.count >= 12
        let X = data.map { features($0.0, quadratic: quadratic) }
        guard let cx = solve(X, data.map { Double($0.1.x) }),
              let cy = solve(X, data.map { Double($0.1.y) }) else { return nil }
        var errors: [Double] = []
        for i in data.indices {  // leave-one-out: honest estimate of runtime error
            var rest = data; rest.remove(at: i)
            let Xr = rest.map { features($0.0, quadratic: quadratic) }
            guard let ax = solve(Xr, rest.map { Double($0.1.x) }), let ay = solve(Xr, rest.map { Double($0.1.y) }) else { continue }
            let m = GazeModel(quadratic: quadratic, cx: ax, cy: ay, errorPx: 0, points: 0)
            let p = m.predict(data[i].0)
            errors.append(hypot(p.x - data[i].1.x, p.y - data[i].1.y))
        }
        errors.sort()
        return GazeModel(quadratic: quadratic, cx: cx, cy: cy,
                         errorPx: errors.isEmpty ? 0 : errors[errors.count / 2], points: data.count)
    }

    private static func solve(_ X: [[Double]], _ y: [Double], lambda: Double = 1e-3) -> [Double]? {
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

    func start() {
        // 7 spots per display — centre, both side edges, four corners — monitor by monitor,
        // left to right, in global top-left coordinates.
        let h = AX.primaryScreenHeight
        let spots = [(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.08, 0.1), (0.92, 0.1), (0.92, 0.9), (0.08, 0.9)]
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
        hud.show("Look at each dot as you normally would — \(points.count) dots, about \(Int(Double(points.count) * 1.8))s · Esc cancels")
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
                    let median = GazeSample(yaw: sorted(\.yaw), pitch: sorted(\.pitch),
                                            faceX: sorted(\.faceX), faceY: sorted(\.faceY), time: 0)
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
        let model = data.count >= 5 ? GazeModel.fit(data) : nil
        if let model { model.save() }
        Log.info("calibration: \(data.count) points, model \(model.map { "±\(Int($0.errorPx))px" } ?? "failed")")
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
