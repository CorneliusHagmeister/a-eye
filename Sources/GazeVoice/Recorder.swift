import AVFoundation

/// Mic capture at 16kHz mono. The engine stays warm for a while after each recording so the
/// next one starts instantly and gets pre-roll (audio from just before the key went down).
final class Recorder {
    static let sampleRate = 16_000.0
    private let preRollSeconds = 0.5
    let postRollSeconds = 0.35

    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recorder.sampleRate,
                                          channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var ring: [Float] = []
    private var recording: [Float]?
    private var coolDown: DispatchWorkItem?
    private(set) var level: Float = 0  // 0…1, for the HUD meter

    var isRunning: Bool { engine.isRunning }

    func begin() throws {
        coolDown?.cancel()
        if !engine.isRunning { try startEngine() }
        lock.lock()
        recording = ring  // pre-roll (empty on a cold start)
        lock.unlock()
    }

    /// Stops after the post-roll so trailing words aren't clipped; returns everything captured.
    func end(completion: @escaping ([Float]) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + postRollSeconds) { [self] in
            lock.lock()
            let samples = recording ?? []
            recording = nil
            lock.unlock()
            scheduleCoolDown()
            completion(samples)
        }
    }

    /// Audio recorded so far, from `start` on (index into the current recording).
    func samples(from start: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard let r = recording, start < r.count else { return [] }
        return Array(r[start...])
    }

    func cancel() {
        lock.lock(); recording = nil; lock.unlock()
        scheduleCoolDown()
    }

    private func scheduleCoolDown() {
        coolDown?.cancel()
        let item = DispatchWorkItem { [self] in
            lock.lock(); let busy = recording != nil; lock.unlock()
            guard !busy else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            lock.lock(); ring = []; lock.unlock()
            Log.info("mic: cooled down")
        }
        coolDown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.micWarmSeconds, execute: item)
    }

    private(set) var deviceName = ""

    private func startEngine() throws {
        let input = engine.inputNode
        if let dev = AudioDevices.preferredInput(), let unit = input.audioUnit {
            var id = dev.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            deviceName = dev.name
        }
        // After switching device the node's output format can still be the old device's
        // (e.g. AirPods' 24kHz), and a tap in that format never fires — use the hardware's.
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone input (permission?)"])
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.consume(buf)
        }
        engine.prepare()
        try engine.start()
        Log.info("mic: started \(deviceName) (\(Int(inFormat.sampleRate))Hz, \(inFormat.channelCount)ch)")
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / buf.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        if let err { Log.info("mic: convert error \(err)") }
        guard err == nil, let ch = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        var sum: Float = 0
        for s in samples { sum += s * s }
        level = min(1, (sum / Float(max(samples.count, 1))).squareRoot() * 8)

        lock.lock()
        if recording != nil { recording!.append(contentsOf: samples) }
        ring.append(contentsOf: samples)
        let maxRing = Int(preRollSeconds * Recorder.sampleRate)
        if ring.count > maxRing { ring.removeFirst(ring.count - maxRing) }
        lock.unlock()
    }
}

enum WAV {
    /// 16-bit PCM mono — the format whisper.cpp and everything else reads.
    static func write(_ samples: [Float], sampleRate: Int = 16_000, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!); u32(36 + bytes); data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(bytes)
        data.reserveCapacity(data.count + samples.count * 2)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try data.write(to: url)
    }
}
