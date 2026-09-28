import AppKit

/// Hold Right ⌥ to talk. Watches modifier changes globally (needs Accessibility).
/// A tap shorter than `minHold`, or any other key pressed early in the hold (you were typing
/// ⌥3 for "#"), counts as not-a-dictation.
final class PushToTalk {
    var onDown: (() -> Void)?
    var onUp: ((_ held: TimeInterval) -> Void)?
    var onCancel: (() -> Void)?

    private let keyCode: UInt16 = 61  // right option
    private let minHold: TimeInterval = 0.25
    private var downAt: Date?
    private var monitors: [Any] = []

    var isHeld: Bool { downAt != nil }

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e) }
        let keys: (NSEvent) -> Void = { [weak self] e in self?.handleKey(e) }
        monitors.compactMap { $0 }.forEach(NSEvent.removeMonitor)
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any,
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any,
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) as Any,
        ]
    }

    private func handleFlags(_ e: NSEvent) {
        guard e.keyCode == keyCode else { return }
        let down = e.modifierFlags.contains(.option)
        if down, downAt == nil {
            downAt = Date()
            onDown?()
        } else if !down, let t = downAt {
            downAt = nil
            let held = Date().timeIntervalSince(t)
            if held < minHold { onCancel?() } else { onUp?(held) }
        }
    }

    private func handleKey(_ e: NSEvent) {
        guard let t = downAt else { return }
        if e.keyCode == 53 || Date().timeIntervalSince(t) < 0.4 {  // Esc, or ⌥+key typing
            downAt = nil
            onCancel?()
        }
    }
}
