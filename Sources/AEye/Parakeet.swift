#if canImport(FluidAudio)
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT v3 on the Neural Engine via FluidAudio (Apache-2.0; model CC-BY-4.0).
/// Fast enough (~100× real time) to re-run on the phrase in progress for live text, and it
/// covers 25 European languages including English and German. Loads on first key-down and
/// unloads after a few idle minutes.
final class ParakeetTranscriber: Transcriber {
    let name = "Parakeet v3 (local)"
    var livePartials: Bool { true }

    private var loading: Task<(AsrManager, Int)?, Never>?
    private var idleStop: DispatchWorkItem?

    func prepare() {
        idleStop?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.shutdown() }
        idleStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: item)
        guard loading == nil else { return }
        loading = Task {
            do {
                let t0 = Date()
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                Log.info(String(format: "parakeet: loaded in %.1fs", Date().timeIntervalSince(t0)))
                return (manager, AsrModelVersion.v3.decoderLayers)
            } catch {
                Log.info("parakeet: load failed: \(error)")
                return nil
            }
        }
    }

    func shutdown() {
        guard loading != nil else { return }
        loading = nil
        Log.info("parakeet: unloaded")
    }

    func transcribe(samples: [Float], hints: [String], previous: String) async throws -> String {
        await MainActor.run { prepare() }
        guard let (manager, layers) = await loading?.value else {
            throw NSError(domain: "parakeet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Parakeet model not loaded"])
        }
        // Parakeet wants at least ~1s; pad short phrases with silence.
        let padded = samples.count < 16_000 ? samples + [Float](repeating: 0, count: 16_000 - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: layers)
        let lang = Settings.languages.count == 1 ? Language(rawValue: Settings.languages[0]) : nil
        return try await manager.transcribe(padded, decoderState: &state, language: lang).text
    }

    func transcribe(wav: URL, hints: [String], previous: String) async throws -> String {
        try await transcribe(samples: WAV.read(wav), hints: hints, previous: previous)
    }
}
#endif
