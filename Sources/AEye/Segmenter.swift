import Foundation

/// Finds phrase boundaries (pauses) in a recording that's still growing, so each phrase can
/// be transcribed and pasted while you keep talking. Whisper isn't a streaming model, so
/// "streaming" here means committing a phrase every time you pause — committed text never
/// changes, which is what makes it safe to paste straight into the target.
final class Segmenter {
    private let frame = 480                  // 30ms at 16kHz
    private let pauseFrames = 15             // 450ms of quiet ends a phrase
    private let minSpeechFrames = 17         // ~0.5s of speech before a phrase can end
    private let maxPhrase = 12 * 16_000      // force a cut in very long run-on speech
    private var noiseFloor: Float = 0.002

    /// Start of the current, not-yet-committed phrase, as an index into the recording.
    private(set) var cut = 0

    func reset() { cut = 0 }
    func advance(by n: Int) { cut += n }

    /// End (relative to `s`, the audio since `cut`) of a finished phrase, if there is one.
    func findPhraseEnd(_ s: [Float]) -> Int? {
        let rms = frameRMS(s)
        guard !rms.isEmpty else { return nil }
        adaptFloor(rms)
        let speech = rms.map(isSpeech)
        let speechCount = speech.filter { $0 }.count
        if speechCount >= minSpeechFrames, let last = speech.lastIndex(of: true),
           rms.count - 1 - last >= pauseFrames {
            return min(s.count, (last + 1) * frame + 200 * 16)  // keep 200ms of tail
        }
        if s.count > maxPhrase {  // no pause: cut at the quietest point in the last 3s
            let from = max(0, rms.count - 100)
            let q = (from..<rms.count).min { rms[$0] < rms[$1] } ?? rms.count - 1
            return (q + 1) * frame
        }
        return nil
    }

    /// Enough speech to be worth transcribing (filters Whisper's "Thank you." on silence).
    func hasSpeech(_ s: [Float]) -> Bool {
        frameRMS(s).filter(isSpeech).count >= 10
    }

    private func isSpeech(_ r: Float) -> Bool { r > max(noiseFloor * 3, 0.004) }

    private func adaptFloor(_ rms: [Float]) {
        guard let quietest = rms.suffix(40).min() else { return }
        noiseFloor = quietest < noiseFloor ? quietest : noiseFloor * 0.98 + quietest * 0.02
    }

    private func frameRMS(_ s: [Float]) -> [Float] {
        stride(from: 0, to: s.count - frame + 1, by: frame).map { i in
            var sum: Float = 0
            for j in i..<(i + frame) { sum += s[j] * s[j] }
            return (sum / Float(frame)).squareRoot()
        }
    }
}
