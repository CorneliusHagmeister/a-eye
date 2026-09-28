import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = GazeTracker()
    private let store = TargetStore()
    private let classifier = GazeClassifier()
    private let recorder = Recorder()
    private let ptt = PushToTalk()
    private let hud = HUD()
    private let dot = TargetDot()
    private let delivery = Delivery()
    private lazy var engine: SpeechEngine = Engines.make(Settings.engine) ?? Engines.make("parakeet")
        ?? Engines.make("whisper") ?? Engines.make("apple")!
    private var statusItem: NSStatusItem!

    // Recording state
    private var latched: Target?
    private var latchUntil = Date.distantPast
    private var meter: Timer?
    private var recordingActive = false
    private var session: SpeechSession?
    private var press: Press?
    private var sentSamples = 0
    private var livePartial = ""

    // Calibration state
    private enum CalMode { case none, add, recalibrate([UUID]) }
    private var calMode = CalMode.none
    private var capturing = false

    private var cameraPaused = false

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("GazeVoice starting")
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
            runTranscribeCLI(CommandLine.arguments[i + 1]); return
        }
        if CommandLine.arguments.contains("--mic-test") { runMicTest(); return }
        if CommandLine.arguments.contains("--inspect") { runInspect(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--engine-test"), i + 2 < CommandLine.arguments.count {
            runEngineTest(CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--segment-test"), i + 1 < CommandLine.arguments.count {
            runSegmentTest(CommandLine.arguments[i + 1]); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "GazeVoice")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        tracker.onSample = { [weak self] s in self?.onGaze(s) }
        store.onChange = { [weak self] in self?.classifier.reset() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let w = self?.statusItem.button?.window
            Log.info("status item frame \(w?.frame ?? .zero) visible \(w?.isVisible ?? false) on \(w?.screen?.localizedName ?? "no screen")")
        }
        wirePushToTalk()
        wireDispatcher()
        requestPermissions()
    }

    /// Opening the app again (Finder, Spotlight, `open`) pops the menu at the mouse — the
    /// menu bar icon can be hidden behind the notch when the menu bar is crowded.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let menu = statusItem?.menu else { return false }
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func applicationWillTerminate(_ note: Notification) { engine.shutdown() }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { ok ? self.tracker.start() : Log.info("camera denied") }
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in if !ok { Log.info("mic denied") } }
        Task { if !(await AppleTranscriber.requestAuthorization()) { Log.info("speech recognition denied") } }
        if AX.isTrusted {
            ptt.start()
        } else {
            AX.promptForTrust()
            hud.show("Grant Accessibility to GazeVoice so it can hear the talk key and focus windows", hideAfter: 8)
            // Global event monitors registered before trust never fire, so wait and re-register.
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                guard AX.isTrusted else { return }
                t.invalidate(); self?.ptt.start()
                Log.info("accessibility granted")
                self?.hud.show("Ready — hold Right ⌥ to talk", hideAfter: 2)
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // You clicked somewhere; don't trust stale focus (our own clicks excepted).
            if Date().timeIntervalSince(Input.lastSyntheticClick) > 0.5 { self?.delivery.focusedTarget = nil }
        }
        prepareElectronTrees()
    }

    // MARK: gaze

    private func onGaze(_ s: GazeSample?) {
        let cur = classifier.update(s, targets: store.targets)
        // Grace period after key-down: your head may still be turning to the target.
        if ptt.isHeld, Date() < latchUntil, let cur, cur != latched?.id, let t = store.target(cur) {
            latched = t
            press?.target = t
            Log.info("re-latched → \(t.name)")
            Task { await WindowControl.focus(t, click: false) }
        }
        if capturing, let s { captureSamples.append(s) }
        updateStatusTitle(face: s != nil)
    }

    private func updateStatusTitle(face: Bool) {
        guard let button = statusItem?.button else { return }
        guard Settings.showGazeInMenuBar, !store.targets.isEmpty else { button.title = ""; return }
        if !tracker.isRunning { button.title = " paused"; return }
        if !face { button.title = " –"; return }
        button.title = " " + short(store.target(classifier.current)?.name ?? "?")
    }

    private func short(_ s: String) -> String { s.count > 18 ? String(s.prefix(17)) + "…" : s }

    // MARK: talk key

    private func wirePushToTalk() {
        ptt.onDown = { [weak self] in self?.keyDown() }
        ptt.onUp = { [weak self] held in self?.keyUp(held) }
        ptt.onCancel = { [weak self] in self?.keyCancel() }
    }

    private func keyDown() {
        if case .none = calMode {} else { beginCapture(); return }
        latched = store.target(classifier.current)
        latchUntil = Date().addingTimeInterval(0.4)
        engine.prepare()
        do { try recorder.begin() } catch {
            hud.show("⚠︎ Mic: \(error.localizedDescription)", hideAfter: 3); return
        }
        recordingActive = true
        sentSamples = 0
        livePartial = ""
        let p = Press(target: latched, engine: engine.name)
        press = p
        delivery.track(p)
        session = engine.startSession(sessionContext()) { [weak self] ev in self?.handle(ev, for: p) }
        if let t = latched { Task { await WindowControl.focus(t, click: false) } }
        Log.info("talk ↓ → \(latched?.name ?? "front app") [\(engine.name)]")
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pumpAudio()
            self?.showRecordingHUD()
        }
        showRecordingHUD()
    }

    /// Feed the engine what the mic captured since the last tick.
    private func pumpAudio() {
        guard recordingActive, let session else { return }
        let new = recorder.samples(from: sentSamples)
        guard !new.isEmpty else { return }
        sentSamples += new.count
        session.append(new)
    }

    private func keyUp(_ held: TimeInterval) {
        guard recordingActive, let s = session, let p = press else { return }  // e.g. a calibration tap's release
        recordingActive = false
        meter?.invalidate(); meter = nil
        session = nil
        let sent = sentSamples
        Log.info(String(format: "talk ↑ after %.1fs", held))
        showHUD("… \(p.target?.name ?? "transcribing")\(livePartial.isEmpty ? "" : ": " + tail(livePartial))", for: p.target)
        recorder.end { samples in
            // Keep the whole press on disk first: the fallback and "Recent" retry use it.
            let url = Paths.recordings.appendingPathComponent(Delivery.stamp() + ".wav")
            if (try? WAV.write(samples, to: url)) != nil { p.wav = url }
            if sent < samples.count { s.append(Array(samples[sent...])) }  // incl. post-roll
            s.finish()
        }
    }

    private func keyCancel() {
        guard recordingActive else { return }
        recordingActive = false
        meter?.invalidate(); meter = nil
        session?.cancel(); session = nil
        if let p = press { delivery.forget(p) }
        recorder.cancel()
        hud.hide()
    }

    private func sessionContext() -> SessionContext {
        let names = store.targets.flatMap { [$0.appName, $0.name] }
        let vocab = ["Claude", "Claude Code", "VS Code", "Cursor", "TypeScript", "Swift", "npm", "git",
                     "PR", "API", "JSON", "README", "repo", "commit"]
        var seen = Set<String>()
        return SessionContext(hints: (names + vocab).filter { seen.insert($0).inserted }, languages: Settings.languages)
    }

    private func handle(_ ev: SpeechEvent, for p: Press) {
        switch ev {
        case .partial(let t):
            if p === press, recordingActive { livePartial = t }
        case .final(let t):
            let text = p.phrases > 0 ? " " + t : t
            p.text += text
            p.phrases += 1
            if p === press { livePartial = "" }
            delivery.enqueue(.text(text, p))
        case .failed(let msg):
            p.error = msg
            Log.info("engine error: \(msg)")
            if !recordingActive { hud.show("⚠︎ \(msg.prefix(90))", hideAfter: 3) }
        case .done:
            finishPress(p)
        }
    }

    private func finishPress(_ p: Press) {
        // The cloud engine failed before producing anything: transcribe the saved audio locally.
        if p.phrases == 0, p.error != nil, let wav = p.wav {
            Log.info("falling back to local transcription")
            Task { @MainActor in
                let local = Engines.localTranscriber()
                if let text = try? await local.transcribe(wav: wav, hints: self.sessionContext().hints, previous: ""),
                   !ChunkedSession.clean(text).isEmpty {
                    p.text = ChunkedSession.clean(text); p.phrases = 1
                    self.delivery.enqueue(.text(p.text, p))
                }
                self.completePress(p)
            }
            return
        }
        completePress(p)
    }

    private func completePress(_ p: Press) {
        if Settings.autoSubmit, p.phrases > 0 { delivery.enqueue(.submit(p)) }
        if p.state == .undeliverable {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.text, forType: .string)
            hud.show("⚠︎ Couldn't find \(p.target?.name ?? "the window") — text copied to clipboard", hideAfter: 3)
        } else if p.phrases == 0 {
            p.state = p.error == nil ? .empty : .failed
            if !recordingActive { showHUD(p.error == nil ? "(nothing heard)" : "⚠︎ Failed — audio kept, retry from Recent",
                                          for: p.target, hideAfter: 1.5) }
        } else {
            p.state = .done
        }
        logPress(p)
    }

    private func logPress(_ p: Press) {
        Log.info("press done [\(p.engine)] → \(p.target?.name ?? "front app"): \(p.text)")
        Delivery.appendHistory(p)
    }

    private func tail(_ s: String, _ n: Int = 60) -> String { s.count > n ? "…" + s.suffix(n) : s }

    private func showRecordingHUD() {
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇"]
        let lvl = bars[min(bars.count - 1, Int(recorder.level * Float(bars.count)))]
        let live = livePartial.isEmpty ? "" : "  " + tail(livePartial)
        showHUD("● \(latched?.name ?? "focused app")  \(lvl)\(live)", for: latched)
    }

    private func showHUD(_ text: String, for t: Target?, hideAfter: TimeInterval? = nil) {
        var rect: CGRect?
        if let t, let ref = WindowControl.resolve(t) {
            rect = ref.frame
            if let p = t.clickPoint(in: ref.frame) {  // centre the pill over the pane, not the window
                rect = CGRect(x: p.x - 1, y: ref.frame.minY, width: 2, height: ref.frame.height)
            }
        }
        hud.show(text, over: rect, hideAfter: hideAfter)
    }

    // MARK: dispatcher

    private func wireDispatcher() {
        delivery.currentFocusTarget = { [weak self] in
            guard let self, self.ptt.isHeld else { return nil }
            return self.latched
        }
        delivery.onDelivered = { [weak self] p, text in
            guard let self, !self.recordingActive else { return }
            self.showHUD("✓ \(p.target?.name ?? "pasted"): \(self.tail(text, 48))", for: p.target, hideAfter: 1.6)
        }
    }

    /// Electron apps build their accessibility tree lazily and slowly the first time; ask
    /// early so the first delivery can find the text input.
    private func prepareElectronTrees() {
        for id in Set(store.targets.map(\.bundleID)) {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { AX.enableElectronTree($0.processIdentifier) }
        }
    }

    // MARK: calibration

    private var captureSamples: [GazeSample] = []

    private func startAdding() {
        calMode = .add
        hud.show("Hover a target (a pane or window), look at it, tap Right ⌥ · Esc when done")
        watchEscape()
    }

    private func startRecalibrating(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        calMode = .recalibrate(ids)
        promptRecalibrate()
        watchEscape()
    }

    private func promptRecalibrate() {
        guard case .recalibrate(let ids) = calMode, let id = ids.first, let t = store.target(id) else { return finishCalibration() }
        if let ref = WindowControl.resolve(t) {
            dot.show(at: t.clickPoint(in: ref.frame) ?? CGPoint(x: ref.frame.midX, y: ref.frame.midY))
        }
        hud.show("Look at the dot for \(t.name) and tap Right ⌥ · Esc to stop")
    }

    private var escMonitor: Any?
    private func watchEscape() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finishCalibration() }
        }
    }

    private func finishCalibration() {
        calMode = .none
        dot.hide()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let (a, b) = store.tooClose().first {
            hud.show("⚠︎ \(a.name) and \(b.name) are too close to tell apart — recalibrate turning your head more",
                     hideAfter: 5)
        } else {
            hud.show("✓ \(store.targets.count) target\(store.targets.count == 1 ? "" : "s") ready — hold Right ⌥ to talk",
                     hideAfter: 2.5)
        }
    }

    private func beginCapture() {
        guard !capturing else { return }
        guard tracker.isRunning else { hud.show("Camera is off — resume it from the menu", hideAfter: 3); return }
        let mouse = AX.mouseLocation
        var window: WindowRef?
        if case .add = calMode {
            window = WindowControl.window(at: mouse)
            guard window != nil else { hud.show("No window under the mouse — hover the target first"); return }
        }
        capturing = true
        captureSamples = []
        hud.show("Hold still — reading where you're looking…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.finishCapture(mouse: mouse, window: window)
        }
    }

    private func finishCapture(mouse: CGPoint, window: WindowRef?) {
        capturing = false
        guard captureSamples.count >= 4 else {
            hud.show("Couldn't see your face clearly — tap Right ⌥ to try again"); return
        }
        let yaws = captureSamples.map(\.yaw).sorted(), pitches = captureSamples.map(\.pitch).sorted()
        let yaw = yaws[yaws.count / 2], pitch = pitches[pitches.count / 2]
        let mean = yaws.reduce(0, +) / Double(yaws.count)
        let spread = (yaws.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(yaws.count)).squareRoot()
        Log.info(String(format: "captured gaze yaw %.1f pitch %.1f spread %.1f (%d samples)",
                        yaw, pitch, spread, captureSamples.count))

        switch calMode {
        case .add:
            guard let w = window else { return }
            let frac = CGPoint(x: (mouse.x - w.frame.minX) / w.frame.width, y: (mouse.y - w.frame.minY) / w.frame.height)
            let appName = w.app.localizedName ?? "App"
            var t = Target(name: appName, bundleID: w.app.bundleIdentifier ?? "", appName: appName,
                           windowTitle: w.title, windowFrame: w.frame, clickFraction: frac,
                           yaw: yaw, pitch: pitch, spread: spread)
            t.name = uniqueName(for: t)
            store.upsert(t)
            AX.enableElectronTree(w.pid)
            hud.show("✓ Added \(t.name) (yaw \(Int(yaw))°) — next target, or Esc when done")
        case .recalibrate(var ids):
            if var t = store.target(ids.first) {
                t.yaw = yaw; t.pitch = pitch; t.spread = spread
                store.upsert(t)
            }
            ids.removeFirst()
            calMode = .recalibrate(ids)
            ids.isEmpty ? finishCalibration() : promptRecalibrate()
        case .none: break
        }
    }

    /// "Cursor", or "Cursor · left" / "Cursor · right" when several targets share a window.
    private func uniqueName(for t: Target) -> String {
        let project = t.windowTitle.components(separatedBy: " — ").dropFirst().first ?? ""
        var base = t.appName + (project.isEmpty ? "" : " · \(project)")
        let siblings = store.targets.filter { $0.bundleID == t.bundleID && $0.windowTitle.hasSuffix(project) }
        if !siblings.isEmpty {
            let side = (t.clickFraction?.x ?? 0.5) < 0.5 ? "left" : "right"
            base += " · \(side)"
            for var s in siblings where !s.name.hasSuffix("left") && !s.name.hasSuffix("right") {
                s.name += (s.clickFraction?.x ?? 0.5) < 0.5 ? " · left" : " · right"
                store.upsert(s)
            }
        }
        var name = base, n = 2
        while store.targets.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, _ obj: Any? = nil, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self; i.representedObject = obj; i.state = on ? .on : .off
            return i
        }
        let looking = store.target(classifier.current)?.name ?? (store.targets.isEmpty ? "no targets yet" : "—")
        menu.addItem(item("Looking at: \(looking)", nil))
        if !AX.isTrusted { menu.addItem(item("⚠︎ Grant Accessibility…", #selector(openAXSettings))) }
        menu.addItem(.separator())

        for t in store.targets {
            let sub = NSMenu()
            sub.addItem(item(String(format: "yaw %.0f°  pitch %.0f°  ±%.1f°", t.yaw, t.pitch, t.spread), nil))
            sub.addItem(item("Recalibrate", #selector(recalibrateOne(_:)), t.id))
            sub.addItem(item("Remove", #selector(removeTarget(_:)), t.id))
            let i = item(t.name, nil, on: t.id == classifier.current); i.submenu = sub
            menu.addItem(i)
        }
        menu.addItem(item(store.targets.isEmpty ? "Set up targets…" : "Add targets…", #selector(addTargets)))
        if store.targets.count > 1 { menu.addItem(item("Recalibrate all…", #selector(recalibrateAll))) }
        if !store.targets.isEmpty { menu.addItem(item("Remove all targets", #selector(removeAll))) }
        menu.addItem(.separator())

        if !delivery.recent.isEmpty {
            let sub = NSMenu()
            for p in delivery.recent {
                let label: String
                switch p.state {
                case .live: label = "… \(p.text.isEmpty ? "listening" : String(p.text.suffix(50)))"
                case .failed: label = "⚠︎ failed — click to transcribe locally"
                case .empty: label = "(nothing heard)"
                case .undeliverable: label = "not delivered — click to copy: \(p.text.prefix(40))"
                case .done: label = String(p.text.prefix(60))
                }
                sub.addItem(item("\(p.target?.name ?? "—"): \(label)", #selector(recentClicked(_:)), p))
            }
            let r = item("Recent", nil); r.submenu = sub
            menu.addItem(r)
        }
        menu.addItem(item("Press Return after pasting", #selector(toggleSubmit), on: Settings.autoSubmit))
        menu.addItem(item("Show target in menu bar", #selector(toggleMenuBar), on: Settings.showGazeInMenuBar))

        let esub = NSMenu()
        for (id, name) in Engines.catalog {
            let e = id == engine.id ? engine : Engines.make(id)
            var title = name
            if e == nil { title += id == "parakeet" ? " — needs Swift 6 toolchain" : " — not installed" }
            else if e?.hasKey == false { title += " — add API key…" }
            let i = item(title, e == nil ? nil : #selector(chooseEngine(_:)), id, on: id == engine.id)
            esub.addItem(i)
        }
        esub.addItem(.separator())
        for (id, name) in Engines.catalog where Engines.make(id)?.needsKey == true {
            esub.addItem(item("\(Keychain.get(id) == nil ? "Add" : "Change") \(name) API key…", #selector(editKey(_:)), id))
        }
        let ei = item("Engine: \(engine.name)", nil); ei.submenu = esub
        menu.addItem(ei)
        menu.addItem(item(tracker.isRunning ? "Pause camera" : "Resume camera", #selector(toggleCamera)))
        menu.addItem(item("Open recordings folder", #selector(openRecordings)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GazeVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func addTargets() { startAdding() }
    @objc private func recalibrateAll() { startRecalibrating(store.targets.map(\.id)) }
    @objc private func recalibrateOne(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { startRecalibrating([id]) } }
    @objc private func removeTarget(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { store.remove(id) } }
    @objc private func removeAll() { store.removeAll() }
    @objc private func toggleSubmit() { Settings.autoSubmit.toggle() }
    @objc private func toggleMenuBar() { Settings.showGazeInMenuBar.toggle(); updateStatusTitle(face: tracker.latest != nil) }
    @objc private func chooseEngine(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let e = Engines.make(id) else { return }
        if !e.hasKey, !promptForKey(id) { return }
        engine.shutdown()
        engine = e
        Settings.engine = id
        hud.show("Engine: \(e.name)", hideAfter: 1.5)
    }

    @objc private func editKey(_ s: NSMenuItem) {
        if let id = s.representedObject as? String { _ = promptForKey(id) }
    }

    /// Asks for an API key and stores it in the Keychain. Returns true if one is saved.
    private func promptForKey(_ id: String) -> Bool {
        let name = Engines.catalog.first { $0.id == id }?.name ?? id
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(name) API key"
        alert.informativeText = "Stored in your macOS Keychain and only sent to \(name)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if Keychain.get(id) != nil { alert.addButton(withTitle: "Remove key") }
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return false }
            Keychain.set(id, key)
            return true
        case .alertThirdButtonReturn:
            Keychain.set(id, nil)
            return false
        default:
            return Keychain.get(id) != nil
        }
    }
    @objc private func toggleCamera() {
        tracker.isRunning ? tracker.stop() : tracker.start()
        updateStatusTitle(face: false)
    }
    @objc private func openRecordings() { NSWorkspace.shared.open(Paths.recordings) }
    @objc private func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func recentClicked(_ s: NSMenuItem) {
        guard let p = s.representedObject as? Press else { return }
        if p.state == .failed, let wav = p.wav {  // retry locally; result goes to the clipboard
            hud.show("Transcribing locally…")
            Task { @MainActor in
                let text = (try? await Engines.localTranscriber().transcribe(wav: wav, hints: self.sessionContext().hints, previous: "")) ?? ""
                p.text = ChunkedSession.clean(text)
                p.state = p.text.isEmpty ? .empty : .done
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.text, forType: .string)
                self.hud.show(p.text.isEmpty ? "(nothing heard)" : "Copied: \(self.tail(p.text, 48))", hideAfter: 2)
            }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.text, forType: .string)
        hud.show("Copied", hideAfter: 1)
    }

    // MARK: CLI test hooks

    /// `GazeVoice --engine-test <engine-id> file.wav` — plays a 16kHz WAV into an engine in
    /// real time (100ms chunks, like the mic) and logs every event with its timing.
    private func runEngineTest(_ id: String, _ path: String) {
        guard let e = Engines.make(id), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            Log.info("engine-test: no engine \(id) or unreadable file"); exit(1)
        }
        let all: [Float] = data.dropFirst(44).withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32767 } }
        e.prepare()
        let t0 = Date()
        let stamp = { String(format: "%5.2fs", Date().timeIntervalSince(t0)) }
        let s = e.startSession(sessionContext()) { ev in
            switch ev {
            case .partial(let t): Log.info("\(stamp()) partial: \(t)")
            case .final(let t): Log.info("\(stamp()) FINAL: \(t)")
            case .failed(let m): Log.info("\(stamp()) failed: \(m)")
            case .done: Log.info("\(stamp()) done"); e.shutdown(); exit(0)
            }
        }
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            let j = min(all.count, i + 1600)
            s.append(Array(all[i..<j])); i = j
            if i >= all.count { t.invalidate(); Log.info("\(stamp()) audio end"); s.finish() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { Log.info("engine-test timeout"); exit(1) }
    }

    /// `GazeVoice --segment-test file.wav` — replays a 16kHz 16-bit WAV as if live and logs
    /// where phrases would be committed.
    private func runSegmentTest(_ path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 44 else { exit(1) }
        let all: [Float] = data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32767 }
        }
        let seg = Segmenter()
        var fed = 0
        while fed < all.count {
            fed = min(all.count, fed + 3200)  // 200ms ticks, like the live timer
            let s = Array(all[seg.cut..<fed])
            if let end = seg.findPhraseEnd(s) {
                Log.info(String(format: "commit %.2fs–%.2fs (speech: %@)", Double(seg.cut) / 16000,
                                Double(seg.cut + end) / 16000, seg.hasSpeech(Array(s[..<end])) ? "yes" : "no"))
                seg.advance(by: end)
            }
        }
        Log.info(String(format: "final %.2fs–%.2fs", Double(seg.cut) / 16000, Double(all.count) / 16000))
        exit(0)
    }

    /// `GazeVoice --inspect` — for each target, logs what's under its click point and the
    /// text inputs in its window. Diagnoses "focused the window but paste went nowhere".
    private func runInspect() {
        for t in store.targets {
            guard let ref = WindowControl.resolve(t) else { Log.info("inspect \(t.name): window not found"); continue }
            AX.enableElectronTree(ref.pid)
            let p = t.clickPoint(in: ref.frame) ?? .zero
            Log.info("inspect \(t.name): window '\(ref.title)' \(ref.frame), click \(p)")
            // Electron builds the tree lazily after the flag is set.
            for _ in 0..<6 where AX.textInputs(in: ref.window).isEmpty {
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            }
            if let el = AX.element(at: p) {
                Log.info("  at click: \(AX.role(el)) '\(AX.string(el, kAXDescriptionAttribute) ?? "")' \(AX.frame(el) ?? .zero)")
            }
            for (el, f) in AX.textInputs(in: ref.window) {
                Log.info("  input: \(AX.role(el)) '\(AX.string(el, kAXDescriptionAttribute) ?? AX.string(el, kAXPlaceholderValueAttribute) ?? "")' \(f)")
            }
        }
        exit(0)
    }

    /// `GazeVoice --mic-test` — opens the chosen mic for 2s, logs device and peak level, exits.
    private func runMicTest() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { [self] in
                Log.info("mic permission: \(granted)")
                Log.info("default input: \(AudioDevices.defaultInput()?.name ?? "none"); chosen: \(AudioDevices.preferredInput()?.name ?? "none")")
                do { try recorder.begin() } catch { Log.info("mic error: \(error)"); exit(1) }
                var peak: Float = 0
                Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in peak = max(peak, self.recorder.level) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.recorder.end { samples in
                        Log.info(String(format: "mic-test: %d samples (%.1fs), peak level %.2f", samples.count,
                                        Double(samples.count) / Recorder.sampleRate, peak))
                        exit(0)
                    }
                }
            }
        }
    }

    /// `GazeVoice --transcribe file.wav` — transcribes and exits (for testing the speech side).
    private func runTranscribeCLI(_ path: String) {
        Task { @MainActor in
            _ = await AppleTranscriber.requestAuthorization()
            let t = Engines.localTranscriber()
            for run in 1...2 {  // second run shows warm (resident model) latency
                let t0 = Date()
                do {
                    let text = try await t.transcribe(wav: URL(fileURLWithPath: path), hints: ["Claude", "VS Code"], previous: "")
                    Log.info(String(format: "[%@ run %d %.2fs] %@", t.name, run, Date().timeIntervalSince(t0), text))
                } catch {
                    Log.info("transcribe error: \(error)")
                }
            }
            t.shutdown()
            exit(0)
        }
    }
}
