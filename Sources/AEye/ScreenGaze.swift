import AppKit

/// Maps where your head is and where it points to a point on the screens.
///
/// Geometric, not a black-box fit: face size in the image gives your distance, face position
/// gives your lateral offset, and a ray cast along the head direction is intersected with the
/// plane of the screens. Calibration only learns how that plane maps onto your monitors (a
/// smooth quadratic) and how much your eyes add on top of your head turn (`gx`, `gy`). So
/// leaning back or shifting sideways moves the estimate the way it physically should.
/// On top of that, the pupils' position inside the eyes adds the eyes' own contribution
/// (scaled by distance — the same eye turn covers more screen from further away), so a glance
/// without turning your head still moves the estimate.
struct GazeModel: Codable {
    var gx: Double
    var gy: Double
    /// Pupil terms in use (calibrated with eye data).
    var eyes: Bool
    /// Calibration-average pupil position, used when the eyes can't be read (e.g. glasses glare).
    var meanPupilX: Double
    var meanPupilY: Double
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

    static func features(_ s: GazeSample, gx: Double, gy: Double, quadratic: Bool,
                         eyes: Bool, meanPupil: (Double, Double)) -> [Double] {
        let (u, v) = plane(s, gx: gx, gy: gy)
        var f = quadratic ? [1, u, v, u * u, v * v, u * v] : [1, u, v]
        if eyes {
            let hz = distance(s)
            // Relative to your resting pupil position — the raw landmark isn't centred at zero,
            // and scaling that offset by distance would shift everything when you lean back.
            let px = s.hasEyes ? s.pupilX - meanPupil.0 : 0, py = s.hasEyes ? s.pupilY - meanPupil.1 : 0
            f += [hz * px * 10, hz * py * 10]  // ×10: similar scale to u, v
        }
        return f
    }

    var quadratic: Bool { cx.count - (eyes ? 2 : 0) > 3 }

    func predict(_ s: GazeSample) -> CGPoint {
        let f = Self.features(s, gx: gx, gy: gy, quadratic: quadratic, eyes: eyes, meanPupil: (meanPupilX, meanPupilY))
        return CGPoint(x: zip(f, cx).map(*).reduce(0, +), y: zip(f, cy).map(*).reduce(0, +))
    }

    func isOutsideCalibratedPosture(_ s: GazeSample) -> Bool {
        let hz = Self.distance(s)
        return hz > hzMax * 1.2 || hz < hzMin / 1.2
    }

    /// Grid-searches the eye gain per axis (with a mild prior at 1.3 — from one posture it's
    /// barely identifiable) and fits the plane→screen mapping by least squares for each.
    static func fit(_ data: [(GazeSample, CGPoint)], useEyes: Bool = true) -> GazeModel? {
        guard data.count >= 5 else { return nil }
        let withEyes = data.filter { $0.0.hasEyes }
        let eyes = useEyes && Double(withEyes.count) >= 0.8 * Double(data.count) && data.count >= 10
        let meanPupil = (withEyes.map(\.0.pupilX).reduce(0, +) / Double(max(withEyes.count, 1)),
                         withEyes.map(\.0.pupilY).reduce(0, +) / Double(max(withEyes.count, 1)))
        let quadratic = data.count >= (eyes ? 16 : 12)
        let gains = stride(from: 0.6, through: 2.4, by: 0.1).map { $0 }
        // Head gain prior: without eye data the head has to account for the eyes too (~1.3);
        // with it, the head should explain roughly its own angle (~1.0).
        let centre = eyes ? 1.0 : 1.3
        let prior = 3000.0 * Double(data.count)  // px² per unit² of gain away from the centre
        var best: (gx: Double, gy: Double, cx: [Double], cy: [Double], cost: Double)?
        for gx in gains { for gy in gains {
            let X = data.map { features($0.0, gx: gx, gy: gy, quadratic: quadratic, eyes: eyes, meanPupil: meanPupil) }
            let tx = data.map { Double($0.1.x) }, ty = data.map { Double($0.1.y) }
            guard let cx = solve(X, tx), let cy = solve(X, ty) else { continue }
            var sse = 0.0
            for (i, f) in X.enumerated() {
                let px = zip(f, cx).map(*).reduce(0, +), py = zip(f, cy).map(*).reduce(0, +)
                sse += (px - tx[i]) * (px - tx[i]) + (py - ty[i]) * (py - ty[i])
            }
            let cost = sse + prior * ((gx - centre) * (gx - centre) + (gy - centre) * (gy - centre))
            if best == nil || cost < best!.cost { best = (gx, gy, cx, cy, cost) }
        } }
        guard let b = best else { return nil }
        var errors: [Double] = []
        for i in data.indices {  // leave-one-out at the chosen gains: honest runtime error
            var rest = data; rest.remove(at: i)
            let X = rest.map { features($0.0, gx: b.gx, gy: b.gy, quadratic: quadratic, eyes: eyes, meanPupil: meanPupil) }
            guard let ax = solve(X, rest.map { Double($0.1.x) }), let ay = solve(X, rest.map { Double($0.1.y) }) else { continue }
            let m = GazeModel(gx: b.gx, gy: b.gy, eyes: eyes, meanPupilX: meanPupil.0, meanPupilY: meanPupil.1,
                              cx: ax, cy: ay, errorPx: 0, points: 0, hzMin: 0, hzMax: 0)
            let p = m.predict(data[i].0)
            errors.append(hypot(p.x - data[i].1.x, p.y - data[i].1.y))
        }
        errors.sort()
        let hz = data.map { distance($0.0) }
        return GazeModel(gx: b.gx, gy: b.gy, eyes: eyes, meanPupilX: meanPupil.0, meanPupilY: meanPupil.1, cx: b.cx, cy: b.cy,
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
    struct Point: Codable {
        var yaw, pitch, faceX, faceY, faceSize, x, y: Double
        var pupilX, pupilY: Double?
    }

    static func load() -> [(GazeSample, CGPoint)] {
        guard let d = try? Data(contentsOf: Paths.gazeCalibration),
              let pts = try? JSONDecoder().decode([Point].self, from: d) else { return [] }
        return pts.map { (GazeSample(yaw: $0.yaw, pitch: $0.pitch, faceX: $0.faceX, faceY: $0.faceY,
                                     faceSize: $0.faceSize, pupilX: $0.pupilX ?? 0, pupilY: $0.pupilY ?? 0,
                                     hasEyes: $0.pupilX != nil, time: 0), CGPoint(x: $0.x, y: $0.y)) }
    }

    static func save(_ data: [(GazeSample, CGPoint)]) {
        let pts = data.map { Point(yaw: $0.0.yaw, pitch: $0.0.pitch, faceX: $0.0.faceX, faceY: $0.0.faceY,
                                   faceSize: $0.0.faceSize, x: Double($0.1.x), y: Double($0.1.y),
                                   pupilX: $0.0.hasEyes ? $0.0.pupilX : nil, pupilY: $0.0.hasEyes ? $0.0.pupilY : nil) }
        try? JSONEncoder().encode(pts).write(to: Paths.gazeCalibration)
    }
}

/// Guided calibration. The full onboarding (~2½ min) varies head and eyes independently so
/// the model can learn how they combine — looking naturally alone moves them in lockstep:
///   1. Look naturally — 7 dots per monitor
///   2. Eyes only — head kept on the orange ring at the monitor centre, eyes follow 4 dots
///   3. Head only — eyes stay on a dot while the head slowly turns around it
///   4–6. Postures — sitting up straight, leaning back a little, leaning back all the way;
///        4 dots per monitor each, looking naturally (so distance changes are learned, not guessed)
/// "Add a posture" runs just a short natural pass in whatever posture you're in.
final class ScreenCalibrator {
    var onFinish: ((GazeModel?) -> Void)?
    /// When set, frames are saved with their labels while each dot is being collected.
    var recorder: GazeRecorder?

    private enum Kind { case natural, eyesOnly(anchor: CGPoint), headTurn }
    private typealias Card = CalibrationStage.Card
    private struct Step { var point: CGPoint; var kind: Kind; var intro: Card?; var label: String }

    private let stage = CalibrationStage()
    private let hud: HUD
    private var steps: [Step] = []
    private var index = 0
    private var collecting = false
    private var samples: [GazeSample] = []
    private var data: [(GazeSample, CGPoint)] = []
    private var labels: [String] = []  // which step kind each data point came from
    private var cancelled = false
    private var appending = false
    private var escMonitor: Any?

    init(hud: HUD) { self.hud = hud }

    var isRunning: Bool { !steps.isEmpty }

    func start(addPosture: Bool = false) {
        appending = addPosture
        let h = AX.primaryScreenHeight
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        func at(_ screen: NSScreen, _ fx: Double, _ fy: Double) -> CGPoint {
            let f = screen.visibleFrame
            return CGPoint(x: f.minX + f.width * fx, y: h - (f.minY + f.height * (1 - fy)))
        }
        func natural(_ spots: [(Double, Double)], intro: Card, label: String) -> [Step] {
            var out: [Step] = []
            for sc in screens { for (fx, fy) in spots { out.append(Step(point: at(sc, fx, fy), kind: .natural, intro: nil, label: label)) } }
            out[0].intro = intro
            return out
        }
        if addPosture {
            steps = natural([(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.08), (0.5, 0.92)],
                            intro: Card(symbol: "figure.seated.side", phase: 0, of: 0, title: "Add a posture",
                                        body: "Sit the way you want A-EYE to learn, then follow the dot naturally."),
                            label: "posture")
        } else {
            steps = natural([(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.08, 0.1), (0.92, 0.1), (0.92, 0.9), (0.08, 0.9)],
                            intro: Card(symbol: "eye", phase: 1, of: 6, title: "Look naturally",
                                        body: "Follow the dot the way you normally look around your screens."),
                            label: "natural")
            var eyes: [Step] = []
            for sc in screens {
                let c = at(sc, 0.5, 0.5)
                for (fx, fy) in [(0.3, 0.5), (0.7, 0.5), (0.5, 0.25), (0.5, 0.75)] {
                    eyes.append(Step(point: at(sc, fx, fy), kind: .eyesOnly(anchor: c), intro: nil, label: "eyes only"))
                }
            }
            eyes[0].intro = Card(symbol: "eyes", phase: 2, of: 6, title: "Eyes only",
                                 body: "Keep your nose on the orange ring. Follow the dot with just your eyes.")
            var head = screens.map { Step(point: at($0, 0.5, 0.5), kind: .headTurn, intro: nil, label: "head only") }
            head[0].intro = Card(symbol: "arrow.triangle.2.circlepath", phase: 3, of: 6, title: "Head only",
                                 body: "Keep your eyes on the dot. Trace the circling marker with your nose.")
            let postureSpots = [(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.1)]
            let postures =
                natural(postureSpots, intro: Card(symbol: "figure.stand", phase: 4, of: 6, title: "Sit up straight",
                                                  body: "Sit very upright — or lean in a little — and follow the dot."),
                        label: "sitting straight")
                + natural(postureSpots, intro: Card(symbol: "chair", phase: 5, of: 6, title: "Lean back a little",
                                                    body: "Settle back a bit, the way you do mid-task, and follow the dot."),
                          label: "leaned back a little")
                + natural(postureSpots, intro: Card(symbol: "chair.lounge", phase: 6, of: 6, title: "Lean all the way back",
                                                    body: "As relaxed as you ever sit. Keep following the dot."),
                          label: "leaned right back")
            steps = steps + eyes + head + postures
        }
        index = 0; data = []; labels = []; cancelled = false
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.cancel() }
        }
        var secs = 0.0
        for st in steps {
            if st.intro != nil { secs += 4 }
            if case .headTurn = st.kind { secs += 7.5 } else { secs += 1.8 }
        }
        stage.open()
        stage.progress(0, label: "Esc to cancel")
        let welcome = Card(symbol: "eye.circle", phase: 0, of: 0,
                           title: addPosture ? "One more posture" : "Let's learn where you look",
                           body: addPosture ? "About \(Int(secs / 60 + 0.5)) min · Esc cancels"
                               : "About \(Int(secs / 60 + 0.5)) minutes · 6 short phases · a dot to follow · Esc cancels anytime")
        stage.show(welcome, near: steps[0].point, for: 3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.next() }
    }

    /// Fed every tracker frame.
    func add(_ s: GazeSample?) {
        if collecting, let s { samples.append(s) }
    }

    private func next() {
        guard !cancelled else { return }
        guard index < steps.count else { return finish() }
        let step = steps[index]
        if let intro = step.intro {  // phase card: read it, then go
            steps[index].intro = nil
            stage.show(intro, near: step.point, for: 4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.next() }
            return
        }
        switch step.kind {
        case .natural: stage.moveTarget(to: step.point, style: .natural)
        case .eyesOnly(let c): stage.moveTarget(to: step.point, style: .eyesOnly(anchor: c))
        case .headTurn: stage.moveTarget(to: step.point, style: .headTurn)
        }
        stage.progress(Double(index) / Double(steps.count), label: "\(index + 1) of \(steps.count) · \(step.label) · Esc to cancel")
        samples = []
        let (settle, collect): (Double, Double) = { if case .headTurn = step.kind { return (0.5, 7.0) } else { return (0.9, 0.9) } }()
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.collecting = true
            if case .headTurn = step.kind { self.stage.collect(collect, headTurn: true) } else { self.stage.collect(collect, headTurn: false) }
            self.recorder?.setStep((self.index, step.label, step.point))
            DispatchQueue.main.asyncAfter(deadline: .now() + collect) { [weak self] in
                guard let self, !self.cancelled else { return }
                self.collecting = false
                self.recorder?.setStep(nil)
                self.stage.captured()
                if case .headTurn = step.kind {
                    // The head sweeps while the eyes hold: each half-second is its own data point.
                    for chunk in stride(from: 0, to: self.samples.count - 2, by: 4) {
                        let window = Array(self.samples[chunk..<min(chunk + 4, self.samples.count)])
                        if let m = Self.median(window) { self.data.append((m, step.point)); self.labels.append(step.label) }
                    }
                } else if let m = Self.median(self.samples) {
                    self.data.append((m, step.point)); self.labels.append(step.label)
                } else {
                    Log.info("calibration: no face at step \(self.index + 1), skipped")
                }
                self.index += 1
                self.next()
            }
        }
    }

    private static func median(_ s: [GazeSample]) -> GazeSample? {
        guard s.count >= 3 else { return nil }
        func m(_ k: KeyPath<GazeSample, Double>, _ from: [GazeSample]) -> Double {
            let v = from.map { $0[keyPath: k] }.sorted(); return v.isEmpty ? 0 : v[v.count / 2]
        }
        let eyed = s.filter(\.hasEyes)
        return GazeSample(yaw: m(\.yaw, s), pitch: m(\.pitch, s), faceX: m(\.faceX, s), faceY: m(\.faceY, s),
                          faceSize: m(\.faceSize, s), pupilX: m(\.pupilX, eyed), pupilY: m(\.pupilY, eyed),
                          hasEyes: eyed.count * 2 >= s.count, time: 0)
    }

    private func finish() {
        stage.hideTarget()
        let near = steps.last?.point ?? .zero
        steps = []
        let all = appending ? CalibrationData.load() + data : data
        let model = GazeModel.fit(all)
        if let model { model.save(); CalibrationData.save(all) }
        Log.info("calibration: \(data.count) new / \(all.count) total points, model \(model.map { String(format: "±%.0fpx eyes %@ gains %.1f/%.1f distance %.2f–%.2f", $0.errorPx, $0.eyes ? "on" : "off", $0.gx, $0.gy, $0.hzMin, $0.hzMax) } ?? "failed")")
        var headOnlyPx: Double?
        if model?.eyes == true, let headOnly = GazeModel.fit(all, useEyes: false) {
            headOnlyPx = headOnly.errorPx
            Log.info(String(format: "calibration: head-only would be ±%.0fpx", headOnly.errorPx))
        }
        postureReport = appending ? nil : heldOutPostures()
        showResults(model, headOnlyPx: headOnlyPx, points: all.count, near: near)
        onFinish?(model)
    }

    private var showingResults = false

    private func showResults(_ m: GazeModel?, headOnlyPx: Double?, points: Int, near: CGPoint) {
        stage.progress(1, label: "Done · Esc to close")
        guard let m else {
            stage.results(headline: "Couldn't calibrate",
                          detail: ["I couldn't see your face at enough dots.", "Check the lighting and camera, then try again."],
                          good: false, near: near)
            closeResults(after: 6)
            return
        }
        let headline = m.errorPx < 200 ? "Excellent" : m.errorPx < 350 ? "Calibrated" : "Calibrated — a bit rough"
        var detail = [String(format: "Typical error ±%.0f px over %d points", m.errorPx, points)]
        if let h = headOnlyPx, h > m.errorPx {
            detail.append(String(format: "Eye tracking makes it %.0f%% sharper than head alone (±%.0f px)", (1 - m.errorPx / h) * 100, h))
        }
        if let r = postureReport { detail.append("Robustness " + r) }
        detail.append("Tip: menu › Show gaze pointer to see it live")
        stage.results(headline: headline, detail: detail, good: true, near: near)
        NSSound(named: "Glass")?.play()
        closeResults(after: 9)
    }

    private func closeResults(after delay: TimeInterval) {
        showingResults = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.showingResults else { return }
            self.dismissResults()
        }
    }

    private func dismissResults() {
        showingResults = false
        stopMonitor()
        stage.close()
    }

    /// Real-data check of posture robustness: for each posture pass, fit on everything else and
    /// measure the error on that posture's dots — "would it cope if I'd never calibrated this?"
    private(set) var postureReport: String?

    private func heldOutPostures() -> String? {
        var parts: [String] = []
        for label in ["sitting straight", "leaned back a little", "leaned right back", "eyes only"] {
            let held = data.indices.filter { labels[$0] == label }
            guard held.count >= 3 else { continue }
            let rest = data.indices.filter { labels[$0] != label }.map { data[$0] }
            guard let m = GazeModel.fit(rest) else { continue }
            let errs = held.map { i -> Double in let p = m.predict(data[i].0); return hypot(p.x - data[i].1.x, p.y - data[i].1.y) }.sorted()
            parts.append(String(format: "%@ %.0fpx", label, errs[errs.count / 2]))
        }
        guard !parts.isEmpty else { return nil }
        let report = "if never calibrated: " + parts.joined(separator: " · ")
        Log.info("calibration: " + report)
        return report
    }

    func cancel() {
        if showingResults { dismissResults(); return }  // Esc on the results card just closes it
        cancelled = true
        collecting = false
        steps = []
        recorder?.setStep(nil)
        stage.hideTarget()
        stage.close()
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
