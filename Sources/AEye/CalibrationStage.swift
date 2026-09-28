import AppKit
import QuartzCore

/// The visual side of calibration: a dimmed stage over every display with a progress bar,
/// phase cards, and a target that glides between spots, fills a ring while it measures and
/// pops when done. Coordinates in and out are global top-left (AX space).
final class CalibrationStage {
    struct Card {
        var symbol: String
        var phase: Int
        var of: Int
        var title: String
        var body: String
    }

    enum Style { case natural, eyesOnly(anchor: CGPoint), headTurn }

    private let accent = NSColor(calibratedRed: 0.20, green: 0.78, blue: 1.0, alpha: 1)
    private let warm = NSColor.systemOrange
    private var overlays: [Overlay] = []
    private let target = TargetLayer()
    private let anchor = AnchorLayer()
    private let orbit = OrbitLayer()
    private let link = CAShapeLayer()
    private var targetScreen: Overlay?
    private var card: NSView?

    var isOpen: Bool { !overlays.isEmpty }

    // MARK: lifecycle

    func open() {
        guard overlays.isEmpty else { return }
        overlays = NSScreen.screens.map { Overlay(screen: $0, accent: accent) }
        target.build(accent: accent)
        anchor.build(color: warm)
        orbit.build(color: warm)
        link.strokeColor = warm.withAlphaComponent(0.5).cgColor
        link.fillColor = nil
        link.lineWidth = 1.5
        link.lineDashPattern = [5, 6]
        for o in overlays { o.fade(in: true) }
    }

    func close(after delay: TimeInterval = 0) {
        let closing = overlays
        overlays = []
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for o in closing { o.fade(in: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { closing.forEach { $0.window.orderOut(nil) } }
        }
    }

    // MARK: progress + cards

    func progress(_ fraction: Double, label: String) {
        for o in overlays { o.setProgress(fraction, label: label) }
    }

    /// A phase card on the display where the next spot will appear, with a countdown ring.
    func show(_ c: Card, near point: CGPoint, for duration: TimeInterval) {
        hideTarget()
        card?.removeFromSuperview()
        guard let o = overlay(for: point) else { return }
        let v = CardView(card: c, accent: accent, duration: duration)
        o.content.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: o.content.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: o.content.centerYAnchor),
            v.widthAnchor.constraint(equalToConstant: 560),
        ])
        v.appear()
        card = v
        DispatchQueue.main.asyncAfter(deadline: .now() + duration - 0.35) { [weak v] in v?.disappear() }
    }

    // MARK: target

    func moveTarget(to p: CGPoint, style: Style) {
        card?.removeFromSuperview(); card = nil
        guard let o = overlay(for: p) else { return }
        let local = o.local(p)
        if targetScreen !== o {  // new display: appear there rather than fly across
            for l in [target as CALayer, anchor, orbit, link] { l.removeFromSuperlayer() }
            o.stage.addSublayer(link); o.stage.addSublayer(anchor); o.stage.addSublayer(orbit); o.stage.addSublayer(target)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            target.position = local
            CATransaction.commit()
            target.popIn()
            targetScreen = o
        } else {
            target.glide(to: local)
        }
        target.breathe(true)
        target.resetProgress()
        orbit.stop()
        switch style {
        case .natural:
            anchor.isHidden = true; link.isHidden = true
        case .eyesOnly(let a):
            let la = o.local(a)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            anchor.position = la
            let path = CGMutablePath(); path.move(to: la); path.addLine(to: local)
            link.path = path
            CATransaction.commit()
            anchor.isHidden = false; link.isHidden = false
        case .headTurn:
            anchor.isHidden = true; link.isHidden = true
        }
    }

    /// Measuring: fill the ring over `duration`. Head-only also starts the circling marker.
    func collect(_ duration: TimeInterval, headTurn: Bool) {
        target.breathe(false)
        target.fill(over: duration)
        if headTurn {
            orbit.position = target.position
            orbit.start(radius: 110, period: duration / 2)
        }
    }

    func captured() {
        target.burst()
        orbit.stop()
    }

    func hideTarget() {
        for l in [target as CALayer, anchor, orbit, link] { l.removeFromSuperlayer() }
        orbit.stop()
        targetScreen = nil
    }

    // MARK: results

    func results(headline: String, detail: [String], good: Bool, near point: CGPoint) {
        hideTarget()
        guard let o = overlay(for: point) ?? overlays.first else { return }
        let v = ResultView(headline: headline, detail: detail, accent: good ? accent : warm)
        o.content.addSubview(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: o.content.centerXAnchor),
            v.centerYAnchor.constraint(equalTo: o.content.centerYAnchor),
            v.widthAnchor.constraint(equalToConstant: 620),
        ])
        v.appear()
        card = v
        if good { o.confetti(colors: [accent, warm, .systemPink, .systemGreen, .white]) }
    }

    private func overlay(for p: CGPoint) -> Overlay? {
        overlays.first { $0.contains(p) } ?? overlays.first
    }
}

// MARK: - Overlay window per display

private final class Overlay {
    let screen: NSScreen
    let window: NSPanel
    let content: NSView
    let stage = CALayer()
    private let bar = CALayer()
    private let barFill = CALayer()
    private let label = CATextLayer()

    init(screen: NSScreen, accent: NSColor) {
        self.screen = screen
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.alphaValue = 0
        content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        window.contentView = content
        let root = content.layer!

        // Dim with a soft vignette so the target is the brightest thing on screen.
        let dim = CAGradientLayer()
        dim.type = .radial
        dim.frame = root.bounds
        dim.colors = [NSColor(white: 0.04, alpha: 0.78).cgColor, NSColor(white: 0.0, alpha: 0.9).cgColor]
        dim.startPoint = CGPoint(x: 0.5, y: 0.5)
        dim.endPoint = CGPoint(x: 1.2, y: 1.2)
        root.addSublayer(dim)
        stage.frame = root.bounds
        root.addSublayer(stage)

        let w = root.bounds.width
        bar.frame = CGRect(x: w * 0.3, y: root.bounds.height - 46, width: w * 0.4, height: 4)
        bar.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        bar.cornerRadius = 2
        barFill.frame = CGRect(x: 0, y: 0, width: 0, height: 4)
        barFill.backgroundColor = accent.cgColor
        barFill.cornerRadius = 2
        bar.addSublayer(barFill)
        root.addSublayer(bar)
        label.frame = CGRect(x: w * 0.3, y: root.bounds.height - 76, width: w * 0.4, height: 22)
        label.alignmentMode = .center
        label.fontSize = 13
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.foregroundColor = NSColor(white: 1, alpha: 0.6).cgColor
        label.contentsScale = screen.backingScaleFactor
        root.addSublayer(label)
        window.orderFrontRegardless()
    }

    func fade(in: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            window.animator().alphaValue = `in` ? 1 : 0
        }
    }

    func setProgress(_ f: Double, label text: String) {
        barFill.frame.size.width = bar.bounds.width * CGFloat(max(0, min(1, f)))
        label.string = text
    }

    func contains(_ p: CGPoint) -> Bool {
        let h = AX.primaryScreenHeight
        return screen.frame.contains(NSPoint(x: p.x, y: h - p.y))
    }

    func local(_ p: CGPoint) -> CGPoint {
        let h = AX.primaryScreenHeight
        return CGPoint(x: p.x - screen.frame.minX, y: (h - p.y) - screen.frame.minY)
    }

    func confetti(colors: [NSColor]) {
        let e = CAEmitterLayer()
        e.emitterPosition = CGPoint(x: content.bounds.midX, y: content.bounds.height + 10)
        e.emitterShape = .line
        e.emitterSize = CGSize(width: content.bounds.width * 0.6, height: 1)
        e.emitterCells = colors.map { c in
            let cell = CAEmitterCell()
            cell.contents = Self.chip(c)
            cell.birthRate = 28
            cell.lifetime = 6
            cell.velocity = 260
            cell.velocityRange = 120
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 5
            cell.yAcceleration = -220
            cell.spin = 3
            cell.spinRange = 6
            cell.scale = 0.9
            cell.scaleRange = 0.4
            return cell
        }
        content.layer?.addSublayer(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { e.removeFromSuperlayer() }
    }

    private static func chip(_ c: NSColor) -> CGImage? {
        let img = NSImage(size: NSSize(width: 10, height: 6), flipped: false) { r in
            c.setFill(); NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill(); return true
        }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - Layers

private func circle(_ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
}

/// Halo + ring + progress arc + core.
private final class TargetLayer: CALayer {
    private let halo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let core = CAShapeLayer()

    func build(accent: NSColor) {
        guard sublayers == nil else { return }
        bounds = CGRect(x: -60, y: -60, width: 120, height: 120)
        halo.path = circle(38); halo.fillColor = accent.withAlphaComponent(0.16).cgColor
        ring.path = circle(22); ring.fillColor = nil; ring.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor; ring.lineWidth = 2
        // Arc starts at 12 o'clock and runs clockwise.
        let p = CGMutablePath()
        p.addArc(center: .zero, radius: 22, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        arc.path = p; arc.fillColor = nil; arc.strokeColor = accent.cgColor; arc.lineWidth = 4.5; arc.lineCap = .round
        arc.strokeEnd = 0
        core.path = circle(6); core.fillColor = NSColor.white.cgColor
        for l in [halo, ring, arc, core] { addSublayer(l) }
    }

    func popIn() {
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.2; a.toValue = 1; a.damping = 11; a.duration = a.settlingDuration
        add(a, forKey: "pop")
        let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = 0; f.toValue = 1; f.duration = 0.25
        add(f, forKey: "fade")
    }

    func glide(to p: CGPoint) {
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = NSValue(point: presentation()?.position ?? position)
        a.toValue = NSValue(point: p)
        a.duration = 0.5
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin(); CATransaction.setDisableActions(true); position = p; CATransaction.commit()
        add(a, forKey: "glide")
    }

    func breathe(_ on: Bool) {
        if on {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.85; a.toValue = 1.12; a.duration = 0.9; a.autoreverses = true; a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(a, forKey: "breathe")
        } else {
            halo.removeAnimation(forKey: "breathe")
        }
    }

    func resetProgress() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.removeAllAnimations(); arc.strokeEnd = 0
        CATransaction.commit()
    }

    func fill(over d: TimeInterval) {
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0; a.toValue = 1; a.duration = d
        CATransaction.begin(); CATransaction.setDisableActions(true); arc.strokeEnd = 1; CATransaction.commit()
        arc.add(a, forKey: "fill")
    }

    /// A ring that expands and fades: "got it".
    func burst() {
        let b = CAShapeLayer()
        b.path = circle(22); b.fillColor = nil; b.strokeColor = arc.strokeColor; b.lineWidth = 3
        addSublayer(b)
        let s = CABasicAnimation(keyPath: "transform.scale"); s.toValue = 2.4
        let o = CABasicAnimation(keyPath: "opacity"); o.toValue = 0
        let g = CAAnimationGroup(); g.animations = [s, o]; g.duration = 0.45
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.isRemovedOnCompletion = false; g.fillMode = .forwards
        b.add(g, forKey: "burst")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { b.removeFromSuperlayer() }
    }
}

/// "Keep your nose here" ring for the eyes-only phase.
private final class AnchorLayer: CALayer {
    func build(color: NSColor) {
        guard sublayers == nil else { return }
        bounds = CGRect(x: -80, y: -80, width: 160, height: 160)
        let ring = CAShapeLayer()
        ring.path = circle(30); ring.fillColor = color.withAlphaComponent(0.1).cgColor
        ring.strokeColor = color.cgColor; ring.lineWidth = 2.5; ring.lineDashPattern = [8, 5]
        let spin = CABasicAnimation(keyPath: "lineDashPhase"); spin.fromValue = 0; spin.toValue = 26
        spin.duration = 1.2; spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
        let dot = CAShapeLayer(); dot.path = circle(4); dot.fillColor = color.cgColor
        let text = CATextLayer()
        text.string = "keep your nose here"
        text.fontSize = 13; text.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        text.foregroundColor = color.cgColor; text.alignmentMode = .center
        text.frame = CGRect(x: -80, y: -62, width: 160, height: 18)
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        for l in [ring, dot, text] { addSublayer(l) }
    }
}

/// A marker circling the target for the head-only phase: trace it with your nose.
private final class OrbitLayer: CALayer {
    private let track = CAShapeLayer()
    private let marker = CAShapeLayer()

    func build(color: NSColor) {
        guard sublayers == nil else { return }
        track.fillColor = nil; track.strokeColor = color.withAlphaComponent(0.25).cgColor
        track.lineWidth = 1.5; track.lineDashPattern = [3, 7]
        marker.path = circle(9); marker.fillColor = color.cgColor
        marker.shadowColor = color.cgColor; marker.shadowRadius = 8; marker.shadowOpacity = 0.9; marker.shadowOffset = .zero
        addSublayer(track); addSublayer(marker)
        isHidden = true
    }

    func start(radius: CGFloat, period: TimeInterval) {
        track.path = circle(radius)
        let path = CGMutablePath()
        path.addArc(center: .zero, radius: radius, startAngle: .pi, endAngle: .pi - 2 * .pi, clockwise: true)
        let a = CAKeyframeAnimation(keyPath: "position")
        a.path = path; a.duration = period; a.repeatCount = .infinity; a.calculationMode = .paced
        marker.add(a, forKey: "orbit")
        isHidden = false
    }

    func stop() {
        marker.removeAllAnimations()
        isHidden = true
    }
}

// MARK: - Cards

private func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

private class FadingView: NSView {
    func appear() {
        wantsLayer = true
        alphaValue = 0
        layer?.transform = CATransform3DMakeTranslation(0, -14, 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        let t = CABasicAnimation(keyPath: "transform"); t.duration = 0.4
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.transform = CATransform3DIdentity
        layer?.add(t, forKey: "rise")
    }

    func disappear() {
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.3; animator().alphaValue = 0 }
    }

    func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font; l.textColor = color; l.alignment = .center
        return l
    }
}

private final class CardView: FadingView {
    init(card c: CalibrationStage.Card, accent: NSColor, duration: TimeInterval) {
        super.init(frame: .zero)
        let icon = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 54, weight: .light)
        icon.image = (NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)
                      ?? NSImage(systemSymbolName: "eye", accessibilityDescription: nil))?.withSymbolConfiguration(cfg)
        icon.contentTintColor = accent
        let step = label(c.phase > 0 ? "PHASE \(c.phase) OF \(c.of)" : "CALIBRATION", rounded(13, .semibold), accent)
        let title = label(c.title, rounded(40, .bold), .white)
        let body = label(c.body, rounded(18, .regular), NSColor(white: 1, alpha: 0.72))
        let ring = CountdownRing(color: accent, duration: duration)
        let stack = NSStackView(views: [icon, step, title, body, ring])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(4, after: step)
        stack.setCustomSpacing(22, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ring.widthAnchor.constraint(equalToConstant: 34),
            ring.heightAnchor.constraint(equalToConstant: 34),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class ResultView: FadingView {
    init(headline: String, detail: [String], accent: NSColor) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 60, weight: .regular))
        icon.contentTintColor = accent
        let title = label(headline, rounded(44, .bold), .white)
        let lines = detail.map { label($0, rounded(17, .regular), NSColor(white: 1, alpha: 0.75)) }
        let stack = NSStackView(views: [icon, title] + lines)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Small ring that empties over the card's lifetime.
private final class CountdownRing: NSView {
    init(color: NSColor, duration: TimeInterval) {
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        wantsLayer = true
        let s = CAShapeLayer()
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: 17, y: 17), radius: 14, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        s.path = p; s.fillColor = nil; s.strokeColor = color.cgColor; s.lineWidth = 3; s.lineCap = .round
        s.strokeEnd = 0
        let a = CABasicAnimation(keyPath: "strokeEnd"); a.fromValue = 1; a.toValue = 0; a.duration = duration
        s.add(a, forKey: "count")
        layer?.addSublayer(s)
    }

    required init?(coder: NSCoder) { fatalError() }
}
