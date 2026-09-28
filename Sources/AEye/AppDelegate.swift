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
    private let highlight = Highlight()
    private let pointer = GazePointer()
    private lazy var screenCal = ScreenCalibrator(hud: hud)
    private var gazeModel = GazeModel.load()
    /// Smoothed estimate of where you're looking (global top-left coords), screen mode only.
    private var gazePoint: CGPoint?
    private var latchedRect: CGRect?
    private var frameCount = 0
    private var lastPostureHint = Date.distantPast
    private var pupilProbe: PupilProbe?
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
        Log.info("A-EYE starting")
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
            runTranscribeCLI(CommandLine.arguments[i + 1]); return
        }
        if CommandLine.arguments.contains("--mic-test") { runMicTest(); return }
        if CommandLine.arguments.contains("--inspect") { runInspect(); return }
        if CommandLine.arguments.contains("--gaze-fit-test") { runGazeFitTest(); return }
        if CommandLine.arguments.contains("--commands-test") { runCommandsTest(); return }
        if CommandLine.arguments.contains("--cleanup-test") { runCleanupTest(); return }
        if CommandLine.arguments.contains("--clipboard-test") { runClipboardTest(); return }
        if CommandLine.arguments.contains("--pupil-test") { pupilProbe = PupilProbe(); pupilProbe?.run(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--engine-test"), i + 2 < CommandLine.arguments.count {
            runEngineTest(CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--segment-test"), i + 1 < CommandLine.arguments.count {
            runSegmentTest(CommandLine.arguments[i + 1]); return
        }
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "A-EYE")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        tracker.onSample = { [weak self] s in self?.onGaze(s) }
        screenCal.onFinish = { [weak self] m in self?.calibrationFinished(m) }
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
            hud.show("Grant Accessibility to A-EYE so it can hear the talk key and focus windows", hideAfter: 8)
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
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            // You typed yourself: stop editing our pasted sentences in place.
            if Date().timeIntervalSince(Input.lastSyntheticKey) > 0.5, self?.ptt.isHeld == false { self?.delivery.userTyped() }
        }
        prepareElectronTrees()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AX.enableElectronTree(app.processIdentifier)
            }
        }
    }

    // MARK: gaze

    private func onGaze(_ s: GazeSample?) {
        screenCal.add(s)
        frameCount += 1
        if let model = gazeModel, let s, !screenCal.isRunning {
            let p = model.predict(s)
            gazePoint = gazePoint.map { CGPoint(x: $0.x + 0.5 * (p.x - $0.x), y: $0.y + 0.5 * (p.y - $0.y)) } ?? p
            if Settings.showGazePointer, let g = gazePoint { pointer.show(at: g) }
            // Grace period after key-down: your head may still be turning to the target.
            if ptt.isHeld, recordingActive, Date() < latchUntil, let g = gazePoint,
               let (t, rect) = screenTarget(at: g), rect != latchedRect {
                latch(t, rect: rect)
                Log.info("re-latched → \(t.name)")
            }
        } else if gazeModel == nil {
            let cur = classifier.update(s, targets: store.targets)
            if ptt.isHeld, Date() < latchUntil, let cur, cur != latched?.id, let t = store.target(cur) {
                latched = t
                press?.target = t
                Log.info("re-latched → \(t.name)")
                Task { await WindowControl.focus(t, click: false) }
            }
        }
        if capturing, let s { captureSamples.append(s) }
        if frameCount % 4 == 0 { updateStatusTitle(face: s != nil) }
    }

    /// Screen mode: the window visible under the gaze point, and the text input in it nearest
    /// that point (Discord's message box, one of two split panes…). No input → the window.
    private func screenTarget(at p: CGPoint) -> (Target, CGRect)? {
        guard let w = WindowControl.window(at: clampToScreens(p)) else { return nil }
        AX.enableElectronTree(w.pid)
        let app = w.app.localizedName ?? "App"
        let title = w.title.components(separatedBy: " — ").dropFirst().first ?? String(w.title.prefix(30))
        var t = Target(name: title.isEmpty ? app : "\(app) · \(title)", bundleID: w.app.bundleIdentifier ?? "",
                       appName: app, windowTitle: w.title, windowFrame: w.frame, clickFraction: nil,
                       yaw: 0, pitch: 0, spread: 0)
        var rect = w.frame
        if let (_, f) = WindowControl.nearestInput(to: p, in: w.window, maxDistance: 500) {
            t.clickFraction = CGPoint(x: (f.midX - w.frame.minX) / w.frame.width, y: (f.midY - w.frame.minY) / w.frame.height)
            rect = f
        }
        return (t, rect)
    }

    private func latch(_ t: Target, rect: CGRect?) {
        latched = t
        latchedRect = rect
        press?.target = t
        if let rect { highlight.show(rect) }
        Task { await WindowControl.focus(t, click: false) }
    }

    /// Head-pose estimates can land just off the edge; pull them onto the nearest display.
    private func clampToScreens(_ p: CGPoint) -> CGPoint {
        let h = AX.primaryScreenHeight
        let frames = NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: h - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        if frames.contains(where: { $0.contains(p) }) { return p }
        return frames.map { f in CGPoint(x: min(max(p.x, f.minX + 1), f.maxX - 1), y: min(max(p.y, f.minY + 1), f.maxY - 1)) }
            .min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) } ?? p
    }

    private func calibrationFinished(_ m: GazeModel?) {
        if let rec = screenCal.recorder {
            tracker.frameTap = nil
            screenCal.recorder = nil
            Log.info("gaze test set: \(rec.close()) frames in \(rec.dir.path)")
        }
        guard let m else {
            hud.show("⚠︎ Calibration failed — couldn't see your face at enough dots", hideAfter: 4); return
        }
        gazeModel = m
        gazePoint = nil
        let postures = m.hzMax / max(m.hzMin, 0.01) > 1.15 ? "several postures" : "one posture — add one leaning back for robustness"
        hud.show("✓ Calibrated (\(postures), eyes \(m.eyes ? "on" : "off")) — typical error ±\(Int(m.errorPx))px. “Show gaze pointer” to check it.",
                 hideAfter: 6)
        if let r = screenCal.postureReport {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in self?.hud.show("Robustness — \(r)", hideAfter: 8) }
        }
    }

    private func updateStatusTitle(face: Bool) {
        guard let button = statusItem?.button else { return }
        guard Settings.showGazeInMenuBar, gazeModel != nil || !store.targets.isEmpty else { button.title = ""; return }
        if !tracker.isRunning { button.title = " paused"; return }
        if !face { button.title = " –"; return }
        if gazeModel != nil {
            button.title = " " + short(gazePoint.flatMap { WindowControl.window(at: clampToScreens($0))?.app.localizedName } ?? "?")
            return
        }
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
        if screenCal.isRunning { return }
        latchedRect = nil
        if gazeModel != nil {
            latched = nil
            if let g = gazePoint, let (t, rect) = screenTarget(at: g) { latched = t; latchedRect = rect; highlight.show(rect) }
            if let s = tracker.latest, gazeModel!.isOutsideCalibratedPosture(s), Date().timeIntervalSince(lastPostureHint) > 300 {
                lastPostureHint = Date()
                Log.info("posture outside calibration (distance \(GazeModel.distance(s)))")
                hud.show("You're sitting differently from calibration — menu › Add a posture helps", hideAfter: 3)
            }
        } else {
            latched = store.target(classifier.current)
        }
        latchUntil = Date().addingTimeInterval(0.4)
        engine.prepare()
        Cleanup.warm()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.recordingActive == false { self?.highlight.hide() }
        }
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
        highlight.hide()
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
            if p === press { livePartial = "" }
            if Settings.pasteWhileSpeaking {
                // Each phrase is pasted as you pause; commands act per phrase ("scratch that"
                // on its own removes the last pasted phrase). Commands are read from the raw
                // text so clean-up can't tidy them away.
                let cmd = VoiceCommands.interpret(t)
                p.phrases += 1
                if cmd.undoLast, Settings.cleanup == "openai", !p.pieces.isEmpty {
                    // Mid-dictation "scratch that": let the rewrite apply the correction in context
                    // (after a rewrite this press is one piece, so a blind undo would remove it all).
                    pasteSentences(t, p)
                    return
                }
                if cmd.undoLast { delivery.enqueue(.undoLast(p)) }
                if cmd.clearFirst { delivery.enqueue(.clear(p)) }
                if cmd.submit { p.submitRequested = true }
                if !cmd.text.isEmpty { pasteSentences(cmd.text, p) }
            } else {
                p.text += p.phrases > 0 ? " " + t : t  // held until release, then interpreted whole
                p.phrases += 1
            }
        case .failed(let msg):
            p.error = msg
            Log.info("engine error: \(msg)")
            if !recordingActive { hud.show("⚠︎ \(msg.prefix(90))", hideAfter: 3) }
        case .done:
            finishPress(p)
        }
    }

    /// Pastes `text` a sentence at a time, each tidied locally straight away. With OpenAI
    /// clean-up on, every sentence also goes off in parallel and its cleaned version is
    /// swapped in place as soon as it comes back.
    private func pasteSentences(_ text: String, _ p: Press) {
        if Settings.cleanup == "openai" {
            // Rolling clean-up: paste the quick-tidied piece now, then have the whole
            // dictation so far rewritten and edited in place as it gets clearer.
            let quick = Cleanup.basic(text)
            guard !quick.isEmpty else { return }
            p.pieces.append(quick)
            p.text += (p.text.isEmpty ? "" : " ") + quick
            delivery.enqueue(.text(quick, p, segment: nil))
            scheduleRewrite(p)
            return
        }
        for sentence in Self.sentences(text) {
            let quick = Settings.cleanup == "off" ? sentence : Cleanup.basic(sentence)
            guard !quick.isEmpty else { continue }
            let id = UUID()
            let context = p.text
            p.text += (p.text.isEmpty ? "" : " ") + quick
            delivery.enqueue(.text(quick, p, segment: id))
            guard Settings.cleanup == "openai" else { continue }
            p.cleanups.append(Task { @MainActor in
                let cleaned = await Cleanup.openAI(sentence, previous: context)
                guard !cleaned.isEmpty, cleaned != quick else { return }
                p.text = p.text.replacingOccurrences(of: quick, with: cleaned)
                self.delivery.enqueue(.replace(id, cleaned, p))
            })
        }
    }

    /// One rewrite in flight per press; if more was said meanwhile, go again with the latest.
    private func scheduleRewrite(_ p: Press) {
        guard !p.rewriting else { p.rewriteDirty = true; return }
        p.rewriting = true
        p.rewriteDirty = false
        let upTo = p.pieces.count
        let transcript = p.pieces.joined(separator: " ")
        p.cleanups.append(Task { @MainActor in
            if let cleaned = await Cleanup.rewrite(transcript) {
                // Pieces that arrived while this was in flight stay after the cleaned part.
                let later = p.pieces[upTo...].joined(separator: " ")
                let full = later.isEmpty ? cleaned : cleaned + " " + later
                p.text = full
                p.rewrittenUpTo = upTo
                self.delivery.enqueue(.rewrite(p, full))
            }
            p.rewriting = false
            if p.rewriteDirty || (p.state != .live && p.rewrittenUpTo < p.pieces.count) { self.scheduleRewrite(p) }
        })
    }

    /// Waits until the rolling clean-up has covered everything said in this press.
    @MainActor
    private func settleRewrites(_ p: Press) async {
        while true {
            let pending = p.cleanups
            for t in pending { await t.value }
            if !p.rewriting, p.cleanups.count == pending.count { break }
        }
    }

    static func sentences(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s {
            cur.append(ch)
            if ".!?".contains(ch) { out.append(cur); cur = "" }
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func finishPress(_ p: Press) {
        // The cloud engine failed before producing anything: transcribe the saved audio locally.
        if p.phrases == 0, p.error != nil, let wav = p.wav {
            Log.info("falling back to local transcription")
            Task { @MainActor in
                let local = Engines.localTranscriber()
                if let text = try? await local.transcribe(wav: wav, hints: self.sessionContext().hints, previous: ""),
                   !ChunkedSession.clean(text).isEmpty {
                    p.phrases = 1
                    p.pastedWhole = true
                    self.pasteSentences(ChunkedSession.clean(text), p)
                }
                self.completePress(p)
            }
            return
        }
        completePress(p)
    }

    private func completePress(_ p: Press) {
        Task { @MainActor in await self.completePressAsync(p) }
    }

    @MainActor
    private func completePressAsync(_ p: Press) async {
        var submit = (Settings.autoSubmit || p.submitRequested) && !p.text.isEmpty
        if !Settings.pasteWhileSpeaking, p.phrases > 0, !p.pastedWhole {
            let raw = p.text
            p.text = ""
            p.pastedWhole = true
            let cmd = VoiceCommands.interpret(raw)
            if cmd.text != raw || cmd.clearFirst || cmd.undoLast || cmd.submit {
                Log.info("voice command: clear=\(cmd.clearFirst) scratch=\(cmd.undoLast) send=\(cmd.submit) text=\(cmd.text)")
            }
            if cmd.undoLast { delivery.enqueue(.undoLast(p)) }
            if cmd.clearFirst { delivery.enqueue(.clear(p)) }
            if !cmd.text.isEmpty { pasteSentences(cmd.text, p) }
            submit = (Settings.autoSubmit || cmd.submit) && !p.text.isEmpty
        }
        // Send only once the clean-up has caught up with everything said.
        let polishing = p.rewriting && !recordingActive
        if polishing { showHUD("✨ Polishing with OpenAI…", for: p.target) }
        await settleRewrites(p)
        if polishing, !recordingActive { showHUD("✓ Polished: \(tail(p.text, 48))", for: p.target, hideAfter: 1.6) }
        if submit { delivery.enqueue(.submit(p)) }
        if p.state == .undeliverable {
            // Paste-while-speaking: earlier phrases failed; copy the whole text now.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.text, forType: .string)
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
        let running = [press?.text ?? "", livePartial].filter { !$0.isEmpty }.joined(separator: " ")
        let live = running.isEmpty ? "" : "  " + tail(running)
        let polishing = press?.rewriting == true ? "  ✨ OpenAI" : ""
        showHUD("● \(latched?.name ?? "focused app")  \(lvl)\(live)\(polishing)", for: latched)
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
        delivery.onUndeliverable = { [weak self] p in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.text, forType: .string)
            self?.hud.show("⚠︎ Couldn't find \(p.target?.name ?? "the window") — text copied to clipboard", hideAfter: 3)
        }
        delivery.onCommandDone = { [weak self] p, message in
            guard let self, !self.recordingActive else { return }
            self.showHUD(message, for: p.target, hideAfter: 1.5)
        }
        delivery.onDelivered = { [weak self] p, text in
            guard let self, !self.recordingActive else { return }
            self.showHUD("✓ \(p.target?.name ?? "pasted"): \(self.tail(text, 48))", for: p.target, hideAfter: 1.6)
        }
    }

    /// Electron apps build their accessibility tree lazily and slowly the first time; ask
    /// early so the first delivery can find the text input.
    private func prepareElectronTrees() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            AX.enableElectronTree(app.processIdentifier)
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
        let looking = gazeModel != nil
            ? (gazePoint.flatMap { screenTarget(at: $0)?.0.name } ?? "—")
            : (store.target(classifier.current)?.name ?? (store.targets.isEmpty ? "no targets yet" : "—"))
        menu.addItem(item("Looking at: \(looking)", nil))
        menu.addItem(item(gazeModel == nil ? "Calibrate screens…" : "Recalibrate screens… (±\(Int(gazeModel!.errorPx))px)",
                          #selector(calibrateScreens)))
        if gazeModel != nil {
            menu.addItem(item("Add a posture (e.g. leaning back)…", #selector(addPosture)))
            menu.addItem(item("Record gaze test set (3 min, saves frames)…", #selector(recordGazeSet)))
            menu.addItem(item("Show gaze pointer", #selector(togglePointer), on: Settings.showGazePointer))
            menu.addItem(item("Forget screen calibration (use pinned targets)", #selector(forgetScreenCalibration)))
        }
        if !AX.isTrusted { menu.addItem(item("⚠︎ Grant Accessibility…", #selector(openAXSettings))) }
        menu.addItem(.separator())

        if gazeModel == nil, !store.targets.isEmpty { menu.addItem(item("Pinned targets:", nil)) }
        for t in store.targets where gazeModel == nil {
            let sub = NSMenu()
            sub.addItem(item(String(format: "yaw %.0f°  pitch %.0f°  ±%.1f°", t.yaw, t.pitch, t.spread), nil))
            sub.addItem(item("Recalibrate", #selector(recalibrateOne(_:)), t.id))
            sub.addItem(item("Remove", #selector(removeTarget(_:)), t.id))
            let i = item(t.name, nil, on: t.id == classifier.current); i.submenu = sub
            menu.addItem(i)
        }
        if gazeModel == nil {
            menu.addItem(item(store.targets.isEmpty ? "Pin targets instead…" : "Add targets…", #selector(addTargets)))
            if store.targets.count > 1 { menu.addItem(item("Recalibrate all…", #selector(recalibrateAll))) }
            if !store.targets.isEmpty { menu.addItem(item("Remove all targets", #selector(removeAll))) }
        }
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
        menu.addItem(item("Paste while speaking (at each pause)", #selector(togglePasteWhileSpeaking), on: Settings.pasteWhileSpeaking))
        let csub = NSMenu()
        csub.addItem(item("Off — exactly as heard", #selector(chooseCleanup(_:)), "off", on: Settings.cleanup == "off"))
        csub.addItem(item("Basic — remove fillers (local)", #selector(chooseCleanup(_:)), "basic", on: Settings.cleanup == "basic"))
        csub.addItem(item("OpenAI \(Settings.cleanupModel)\(Keychain.get("openai") == nil ? " — add API key…" : "")",
                          #selector(chooseCleanup(_:)), "openai", on: Settings.cleanup == "openai"))
        let names = ["off": "off", "basic": "basic", "openai": "OpenAI"]
        let ci = item("Clean-up: \(names[Settings.cleanup] ?? Settings.cleanup)", nil); ci.submenu = csub
        menu.addItem(ci)
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
        menu.addItem(NSMenuItem(title: "Quit A-EYE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func addTargets() { startAdding() }
    @objc private func calibrateScreens() { guard !screenCal.isRunning else { return }; pointer.hide(); screenCal.start() }
    @objc private func recordGazeSet() {
        guard !screenCal.isRunning, let rec = GazeRecorder() else { return }
        pointer.hide()
        screenCal.recorder = rec
        tracker.frameTap = { px, face, s in rec.frame(px, face: face, sample: s) }
        screenCal.start()
        Log.info("recording gaze test set to \(rec.dir.path)")
    }
    @objc private func addPosture() { guard !screenCal.isRunning else { return }; pointer.hide(); screenCal.start(addPosture: true) }
    @objc private func togglePointer() { Settings.showGazePointer.toggle(); if !Settings.showGazePointer { pointer.hide() } }
    @objc private func forgetScreenCalibration() {
        try? FileManager.default.removeItem(at: Paths.gazeModel)
        try? FileManager.default.removeItem(at: Paths.gazeCalibration)
        gazeModel = nil; gazePoint = nil; pointer.hide()
    }
    @objc private func recalibrateAll() { startRecalibrating(store.targets.map(\.id)) }
    @objc private func recalibrateOne(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { startRecalibrating([id]) } }
    @objc private func removeTarget(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { store.remove(id) } }
    @objc private func removeAll() { store.removeAll() }
    @objc private func toggleSubmit() { Settings.autoSubmit.toggle() }
    @objc private func togglePasteWhileSpeaking() { Settings.pasteWhileSpeaking.toggle() }
    @objc private func chooseCleanup(_ s: NSMenuItem) {
        guard let mode = s.representedObject as? String else { return }
        if mode == "openai", Keychain.get("openai") == nil, !promptForKey("openai") { return }
        Settings.cleanup = mode
    }
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

    /// Menu-bar-only apps have no main menu, and ⌘V/⌘C/⌘A in text fields are routed through
    /// the Edit menu — without one, pasting into the API-key field silently does nothing.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "A-EYE", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Asks for an API key and stores it in the Keychain. Returns true if one is saved.
    private func promptForKey(_ id: String) -> Bool {
        let name = Engines.catalog.first { $0.id == id }?.name ?? id
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(name) API key"
        alert.informativeText = "Paste it below (⌘V), or copy it and click “Use key from clipboard”. "
            + "Stored in your macOS Keychain and only sent to \(name)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Use key from clipboard")
        alert.addButton(withTitle: "Cancel")
        if Keychain.get(id) != nil { alert.addButton(withTitle: "Remove key") }
        alert.window.initialFirstResponder = field
        func save(_ raw: String?) -> Bool {
            let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !key.contains(" "), !key.contains("\n") else {
                hud.show("⚠︎ That doesn't look like an API key — nothing saved", hideAfter: 3); return false
            }
            Keychain.set(id, key)
            hud.show("✓ \(name) key saved to the Keychain", hideAfter: 2)
            return true
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save(field.stringValue)
        case .alertSecondButtonReturn:
            return save(NSPasteboard.general.string(forType: .string))
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            Keychain.set(id, nil)
            hud.show("\(name) key removed", hideAfter: 2)
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

    /// `AEye --clipboard-test` — offers text on the clipboard the way paste does (no ⌘V) and
    /// logs when another process reads it, then restores the previous clipboard.
    private func runClipboardTest() {
        let pb = NSPasteboard.general
        let before = pb.string(forType: .string)
        let provider = PasteProvider("A-EYE clipboard test")
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pb.clearContents(); pb.writeObjects([item])
        let t0 = Date()
        Log.info("clipboard-test: offered")
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
            if provider.delivered || Date().timeIntervalSince(t0) > 8 {
                t.invalidate()
                Log.info(String(format: "clipboard-test: delivered=%@ after %.2fs", provider.delivered ? "yes" : "no", Date().timeIntervalSince(t0)))
                pb.clearContents(); if let before { pb.setString(before, forType: .string) }
                exit(0)
            }
        }
    }

    /// `AEye --cleanup-test` — sends sample dictations through OpenAI clean-up (needs the
    /// OpenAI key in the Keychain) and logs latency and output for each.
    private func runCleanupTest() {
        let samples = [
            "Um so I I think we should, uh, like, run the tests first and then, you know, open the PR.",
            "Can you check the, the auth middleware, actually no, the rate limiter in VS Code?",
            "Ähm, kannst du bitte äh die Tests laufen lassen und mir sagen ob der Build grün ist?",
            "What's the capital of France?",
        ]
        Task { @MainActor in
            for s in samples { _ = await Cleanup.openAI(s, previous: "") }
            exit(0)
        }
    }

    /// `AEye --commands-test` — runs sample transcripts through the voice-command parser.
    private func runCommandsTest() {
        let cases = [
            "Scratch that.", "Clear the input.", "clear input",
            "Let's use Redis. Scratch that. Let's use Postgres instead.",
            "Scratch that. Try the other branch.",
            "Clear the input. Can you run the tests?",
            "Can you run the tests and open a PR, send it.",
            "Can you clear the input field in the form component?",
            "Refactor the parser, scratch that, rewrite the parser.",
        ]
        for c in ["Um, so I I think we should, uh, run the tests.", "Ähm, kannst du äh die Tests laufen lassen?",
                  "Do I need to restart um the the tool though?", "The umbrella summary is humble."] {
            Log.info("basic cleanup: \(c)\n    → \(Cleanup.basic(c))")
        }
        for c in cases {
            let r = VoiceCommands.interpret(c)
            Log.info("\(c)\n    → text=\"\(r.text)\" clear=\(r.clearFirst) scratch=\(r.undoLast) send=\(r.submit)")
        }
        exit(0)
    }

    /// `AEye --gaze-fit-test` — simulates a person at a desk: the head turns 1/1.4 of the gaze
    /// angle and the eyes do the rest, with pupil sensitivity and noise as measured by
    /// --pupil-test (≈0.0035 eye-widths/° horizontally, 0.0013/° vertically) and 1° head-pose
    /// noise. Calibrates, then tests: natural looking, an unseen leaned-back posture, and
    /// eyes-only glances with the head left pointing at the laptop.
    private func runGazeFitTest() {
        let normal = (x: 0.0, y: 12.0, z: 55.0), leanBack = (x: 0.0, y: 4.0, z: 75.0)
        let straight = (x: 0.0, y: 16.0, z: 47.0), littleBack = (x: 0.0, y: 8.0, z: 64.0), allBack = (x: 1.0, y: 0.0, z: 88.0)
        var rng = SystemRandomNumberGenerator()
        func noise(_ a: Double) -> Double { Double.random(in: -a...a, using: &rng) }
        let cmPerPt = 0.024, faceCm = 15.0, g = 1.4
        func angles(_ p: CGPoint, _ head: (x: Double, y: Double, z: Double)) -> (yaw: Double, pitch: Double) {
            let X = Double(p.x) * cmPerPt, Y = Double(p.y) * cmPerPt  // camera at the origin
            return (-atan((X - head.x) / head.z) * 180 / .pi, atan((Y - head.y) / head.z) * 180 / .pi)
        }
        let laptopCentre = CGPoint(x: 756, y: 500)
        func sample(_ p: CGPoint, head: (x: Double, y: Double, z: Double), glance: Bool = false,
                    aimAt: CGPoint? = nil) -> GazeSample {
            let gaze = angles(p, head)
            // Where the head points: at the target (natural), or held at a fixed spot (eyes only).
            let aim = aimAt.map { angles($0, head) } ?? (glance ? angles(laptopCentre, head) : gaze)
            let headYaw = aim.yaw / g, headPitch = aim.pitch / g
            let eyeYaw = gaze.yaw - headYaw, eyePitch = gaze.pitch - headPitch
            let tanH = GazeModel.tanH, tanV = GazeModel.tanV
            return GazeSample(yaw: headYaw + noise(1), pitch: headPitch + noise(1),
                              faceX: 0.5 - head.x / (2 * tanH * head.z), faceY: 0.5 - head.y / (2 * tanV * head.z),
                              faceSize: faceCm / (2 * tanH * head.z),
                              pupilX: -0.016 + eyeYaw * 0.0035 + noise(0.005),
                              pupilY: 0.043 - eyePitch * 0.0013 + noise(0.002), hasEyes: true, time: 0)
        }
        let screens: [CGRect] = [CGRect(x: 0, y: 33, width: 1512, height: 949),
                                 CGRect(x: -1895, y: -1440, width: 2560, height: 1440),
                                 CGRect(x: 665, y: -1440, width: 2560, height: 1440)]
        func dots(_ spots: [(Double, Double)], on list: [CGRect] = screens) -> [CGPoint] {
            list.flatMap { f in spots.map { CGPoint(x: f.minX + f.width * $0.0, y: f.minY + f.height * $0.1) } }
        }
        let full = dots([(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.08, 0.1), (0.92, 0.1), (0.92, 0.9), (0.08, 0.9)])
        // Eyes-only phase: head held on each monitor's centre, eyes to four nearby dots.
        let eyePhase: [(GazeSample, CGPoint)] = screens.flatMap { f -> [(GazeSample, CGPoint)] in
            let c = CGPoint(x: f.midX, y: f.midY)
            return [(0.3, 0.5), (0.7, 0.5), (0.5, 0.25), (0.5, 0.75)].map { fx, fy in
                let p = CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
                return (sample(p, head: normal, aimAt: c), p)
            }
        }
        let short = dots([(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.08), (0.5, 0.92)])

        let unseen = (x: 6.0, y: 2.0, z: 80.0)
        let probes = dots([(0.25, 0.3), (0.75, 0.6), (0.5, 0.2), (0.3, 0.8)])
        let glances = dots([(0.15, 0.5), (0.85, 0.5), (0.5, 0.15), (0.5, 0.85)], on: [screens[0]])  // eyes only, on the laptop
        func err(_ m: GazeModel, _ pts: [CGPoint], _ make: (CGPoint) -> GazeSample) -> Double {
            let e = pts.map { p -> Double in let q = m.predict(make(p)); return hypot(q.x - p.x, q.y - p.y) }.sorted()
            return e[e.count / 2]
        }
        // Head-only phase: eyes fixed on a dot while the head turns around it.
        let headPhase: [(GazeSample, CGPoint)] = screens.flatMap { f -> [(GazeSample, CGPoint)] in
            let p = CGPoint(x: f.midX, y: f.midY)
            return [(-450.0, 0.0), (450, 0), (0, -300), (0, 300), (-300, -200), (300, 200)].map { dx, dy in
                (sample(p, head: normal, aimAt: CGPoint(x: p.x + dx, y: p.y + dy)), p)
            }
        }
        let natural = full.map { (sample($0, head: normal), $0) }
        let lean = short.map { (sample($0, head: leanBack), $0) }
        let postureDots = dots([(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.1)])
        let postures = [straight, littleBack, allBack].flatMap { h in postureDots.map { (sample($0, head: h), $0) } }
        if CommandLine.arguments.contains("--postures") {
            // Average of 20 calibrations; tests postures between, beyond and beside the calibrated ones.
            let tests: [(String, (x: Double, y: Double, z: Double))] = [
                ("between (z60)", (0, 10, 60)), ("between (z75)", (0, 5, 75)),
                ("beyond (z95)", (0, -3, 95)), ("shifted 8cm", (8, 10, 60))]
            for (name, build) in [("1 lean pass ", { natural + eyePhase + headPhase + short.map { (sample($0, head: leanBack), $0) } }),
                                  ("3 postures  ", { natural + eyePhase + headPhase + [straight, littleBack, allBack].flatMap { h in postureDots.map { (sample($0, head: h), $0) } } })] as [(String, () -> [(GazeSample, CGPoint)])] {
                var sums = [Double](repeating: 0, count: tests.count)
                for _ in 0..<20 {
                    guard let m = GazeModel.fit(build()) else { continue }
                    for (i, t) in tests.enumerated() { sums[i] += err(m, probes) { sample($0, head: t.1) } / 20 }
                }
                Log.info("\(name): " + zip(tests, sums).map { String(format: "%@ %3.0fpx", $0.0.0, $0.1) }.joined(separator: " · "))
            }
            exit(0)
        }
        for (name, data) in [("natural only            ", natural),
                             ("+ eyes-only            ", natural + eyePhase),
                             ("+ eyes-only + head-only", natural + eyePhase + headPhase),
                             ("old onboarding (+1 lean)", natural + eyePhase + headPhase + lean),
                             ("new onboarding (3 postures)", natural + eyePhase + headPhase + postures)] {
            for eyes in [false, true] {
                guard let m = GazeModel.fit(data, useEyes: eyes) else { continue }
                Log.info(String(format: "%@ %@: natural %4.0fpx · unseen posture %4.0fpx · eyes-only glance %4.0fpx",
                                name, eyes ? "head+eyes" : "head only",
                                err(m, probes) { sample($0, head: normal) },
                                err(m, probes) { sample($0, head: unseen) },
                                err(m, glances) { sample($0, head: normal, glance: true) }))
            }
        }
        exit(0)
    }

    /// `AEye --engine-test <engine-id> file.wav` — plays a 16kHz WAV into an engine in
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

    /// `AEye --segment-test file.wav` — replays a 16kHz 16-bit WAV as if live and logs
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

    /// `AEye --inspect` — for each target, logs what's under its click point and the
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

    /// `AEye --mic-test` — opens the chosen mic for 2s, logs device and peak level, exits.
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

    /// `AEye --transcribe file.wav` — transcribes and exits (for testing the speech side).
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
