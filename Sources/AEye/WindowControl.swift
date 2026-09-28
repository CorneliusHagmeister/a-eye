import AppKit
import ApplicationServices

/// Accessibility helpers. All coordinates are global, top-left origin (AX / CGWindow space).
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "?" }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func element(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success
        else { return nil }
        return el
    }

    /// Electron apps (VS Code, Claude, Discord, Cursor) only build their accessibility tree
    /// when asked; without this, windows look empty below the top level.
    static func enableElectronTree(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Editable text elements under `root` (breadth-first, bounded).
    static func textInputs(in root: AXUIElement, limit: Int = 4000) -> [(AXUIElement, CGRect)] {
        var out: [(AXUIElement, CGRect)] = []
        var queue = [root], seen = 0
        while !queue.isEmpty, seen < limit {
            let el = queue.removeFirst(); seen += 1
            let r = role(el)
            if r == kAXTextAreaRole || r == kAXTextFieldRole, let f = frame(el), f.width > 20, f.height > 8 {
                out.append((el, f))
            }
            queue.append(contentsOf: children(el))
        }
        return out
    }

    static var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Current mouse location in top-left coords.
    static var mouseLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Converts a top-left global rect to AppKit's bottom-left screen coords.
    static func toCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }
}

struct WindowRef {
    let pid: pid_t
    let app: NSRunningApplication
    let window: AXUIElement
    let frame: CGRect
    let title: String
}

enum WindowControl {
    /// Topmost normal window under a point. Uses CGWindowList (no Screen Recording needed for
    /// pid + bounds), then matches the AX window by frame to get something we can raise.
    static func window(at p: CGPoint) -> WindowRef? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in info {  // front-to-back order
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"] else { continue }
            let bounds = CGRect(x: x, y: y, width: wd, height: h)
            guard bounds.contains(p), let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let axApp = AXUIElementCreateApplication(pid)
            let match = AX.windows(axApp)
                .compactMap { win in AX.frame(win).map { (win, $0) } }
                .min { dist($0.1, bounds) < dist($1.1, bounds) }
            guard let (win, frame) = match, dist(frame, bounds) < 40 else { continue }
            return WindowRef(pid: pid, app: app, window: win, frame: frame,
                             title: AX.string(win, kAXTitleAttribute) ?? "")
        }
        return nil
    }

    /// Finds the live window for a target. Window titles change (VS Code puts the open file
    /// in it), so score on frame, exact title and the workspace suffix of the title.
    static func resolve(_ t: Target) -> WindowRef? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).first else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let savedSuffix = suffix(t.windowTitle)
        var best: (WindowRef, Double)?
        let windows = AX.windows(axApp)
        for win in windows {
            guard let frame = AX.frame(win), frame.width > 50 else { continue }
            let title = AX.string(win, kAXTitleAttribute) ?? ""
            var score = 0.0
            if title == t.windowTitle { score += 3 }
            if !savedSuffix.isEmpty && suffix(title) == savedSuffix { score += 2 }
            if dist(frame, t.windowFrame) < 40 { score += 2 }
            let ref = WindowRef(pid: app.processIdentifier, app: app, window: win, frame: frame, title: title)
            if best == nil || score > best!.1 { best = (ref, score) }
        }
        // A zero score means "some other window of this app" — the real one is closed or on
        // another Space. Better to fail than to paste into the wrong window.
        guard let (ref, score) = best, score >= 2 || windows.count == 1 else { return nil }
        return ref
    }

    /// Brings the target's window to the front. With `click`, also clicks the stored point so
    /// the right pane inside the window gets keyboard focus.
    @discardableResult
    static func focus(_ t: Target, click: Bool) async -> Bool {
        guard let ref = resolve(t) else { Log.info("focus: \(t.name) not found"); return false }
        let axApp = AXUIElementCreateApplication(ref.pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ref.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(ref.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard click, let hint = t.clickPoint(in: ref.frame) else { return true }
        AX.enableElectronTree(ref.pid)
        try? await Task.sleep(nanoseconds: 90_000_000)  // let the raise land
        // Chat inputs move (Claude's composer sits mid-window in a new chat, at the bottom
        // once there's a conversation), so prefer the text input nearest the calibrated point.
        if let (input, f) = nearestInput(to: hint, in: ref.window) {
            AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !isFocused(input, pid: ref.pid) {
                await Input.click(at: CGPoint(x: f.maxX - 12, y: f.maxY - 8))  // end of the text
            }
            return true
        }
        await Input.click(at: hint)
        return true
    }

    /// The editable text element closest to `p`: search outwards from whatever is under the
    /// point (cheap), then the whole window.
    static func nearestInput(to p: CGPoint, in window: AXUIElement, maxDistance: CGFloat = 250) -> (AXUIElement, CGRect)? {
        func best(_ c: [(AXUIElement, CGRect)]) -> (AXUIElement, CGRect)? {
            let scored: [((AXUIElement, CGRect), CGFloat)] = c.map { ($0, distance(p, $0.1)) }
            return scored.filter { $0.1 <= maxDistance }.min { $0.1 < $1.1 }?.0
        }
        var el = AX.element(at: p)
        for _ in 0..<12 {
            guard let cur = el else { break }
            if let hit = best(AX.textInputs(in: cur, limit: 400)) { return hit }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            el = (parent as! AXUIElement)
        }
        return best(AX.textInputs(in: window, limit: 3000))
    }

    private static func isFocused(_ el: AXUIElement, pid: pid_t) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v else { return false }
        return CFEqual(v, el)
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// Text of the focused input in the frontmost app, if its accessibility exposes it.
    static func focusedText() -> String? {
        guard let pid = frontmostPID() else { return nil }
        var el: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &el) == .success,
              let el, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return AX.string(el as! AXUIElement, kAXValueAttribute)
    }

    private static func dist(_ a: CGRect, _ b: CGRect) -> Double {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// "main.ts — myproject — Visual Studio Code" → "myproject — Visual Studio Code"
    private static func suffix(_ title: String) -> String {
        let parts = title.components(separatedBy: " — ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : ""
    }
}

/// Hands the pasted text to whichever app asks for it, and notes that it did.
final class PasteProvider: NSObject, NSPasteboardItemDataProvider {
    let text: String
    private(set) var delivered = false

    init(_ text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        delivered = true
    }
}

/// Synthetic input. Uses a private event source and explicit flags so a held talk key
/// (Right ⌥) doesn't turn our click into an Option-click (= add cursor in VS Code).
enum Input {
    private static let source = CGEventSource(stateID: .privateState)
    /// So our own clicks don't look like "the user clicked somewhere else".
    private(set) static var lastSyntheticClick = Date.distantPast

    static func click(at p: CGPoint) async {
        lastSyntheticClick = Date()
        let back = AX.mouseLocation
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        CGWarpMouseCursorPosition(back)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private(set) static var lastSyntheticKey = Date.distantPast

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        lastSyntheticKey = Date()
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Pastes via the clipboard, then restores what was on it.
    ///
    /// The text is only *promised* to the clipboard; your previous clipboard is restored once the
    /// target app has actually fetched it. A fixed delay isn't enough: an app busy streaming a
    /// reply can read the clipboard late, after the restore, and paste your old clipboard instead.
    @MainActor
    static func paste(_ text: String, submit: Bool) async {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        let provider = PasteProvider(text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pb.clearContents()
        pb.writeObjects([item])
        key(9, flags: .maskCommand)  // ⌘V
        let t0 = Date()
        while !provider.delivered, Date().timeIntervalSince(t0) < 1.5 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if !provider.delivered { Log.info("paste: the app didn't read the clipboard within 1.5s") }
        if submit { key(36) }  // Return, once the text is in
        try? await Task.sleep(nanoseconds: 250_000_000)  // margin in case it reads the type twice
        pb.clearContents()
        if !saved.isEmpty {
            pb.writeObjects(saved.map { d in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            })
        }
    }
}
