import AppKit

/// Small floating pill that never takes focus. Shows where dictation is going.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 19
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
    }

    /// `over` is a global top-left rect (a target window); the pill sits near its top.
    func show(_ text: String, over rect: CGRect? = nil, hideAfter: TimeInterval? = nil) {
        hideWork?.cancel()
        label.stringValue = text
        let width = min(560, max(220, label.intrinsicContentSize.width + 40))
        let size = NSSize(width: width, height: 38)
        let origin: NSPoint
        if let rect {
            let c = AX.toCocoa(rect)
            origin = NSPoint(x: c.midX - size.width / 2, y: c.maxY - size.height - 44)
        } else {
            let s = NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: s.midX - size.width / 2, y: s.maxY - size.height - 12)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if let hideAfter {
            let w = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: w)
        }
    }

    func hide() { hideWork?.cancel(); panel.orderOut(nil) }
}

/// A pulsing dot drawn at a screen point — "look here" during calibration.
final class TargetDot {
    private let panel: NSPanel

    init() {
        let d: CGFloat = 28
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        v.layer?.cornerRadius = d / 2
        v.layer?.borderColor = NSColor.white.cgColor
        v.layer?.borderWidth = 3
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.35; pulse.duration = 0.6
        pulse.autoreverses = true; pulse.repeatCount = .infinity
        v.layer?.add(pulse, forKey: "pulse")
        panel.contentView = v
    }

    func show(at p: CGPoint) {
        let c = NSPoint(x: p.x, y: AX.primaryScreenHeight - p.y)
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: c.x - s.width / 2, y: c.y - s.height / 2))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
