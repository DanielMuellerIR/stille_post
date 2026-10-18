import AppKit
import Sparkle
@testable import StillePostCore

// Echte App-Verdrahtung, künstliches Audio und künstliche Textdienste.
// Keine Mikrofonfreigabe, kein Audio-/Textnetzwerk und kein gestarteter Updater.
@main struct TestDictationRegression {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STILLEPOST_CONFIG"] != nil, environment["STILLEPOST_APP_SUPPORT"] != nil,
              environment["STILLEPOST_ALLOW_MULTIPLE"] == "1" else { throw FixtureFailure.isolation }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let scenario = CommandLine.arguments[2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let counts = FixtureCounts()
        var engine: DictationEngine?
        var segmenter: FixtureSegmenter?, recorder: FixtureRecorder?
        var segmentNumber = 0
        var recordingFrontPID: pid_t?
        var wrapped = false
        let clipboard = NSPasteboard.general.changeCount
        let delegate = AppDelegate(makeEngine: { config in
            let cleanup = FixtureCleanup(counts: counts, fallback: scenario == "private")
            let value = DictationEngine(config: config, history: HistoryStore(), dependencies: .init(
                transcriber: FixtureTranscriber(counts: counts, language: config.whisper.language, scenario: scenario),
                server: FixtureServer(), cleanup: cleanup,
                makeRecorder: { _ in
                    let value = FixtureRecorder(counts: counts, fails: scenario == "failure", automatic: !scenario.hasPrefix("preview"))
                    recorder = value; return value
                },
                makeSegmenter: { _ in let value = FixtureSegmenter(); segmenter = value; return value },
                makeWavWriter: { try WavFileWriter(url: $0) },
                makeTranscriber: { FixtureTranscriber(counts: counts, language: $0.language, scenario: scenario) },
                requestMicrophoneAccess: {
                    if scenario == "delay" { try? await Task.sleep(nanoseconds: 10_000_000_000) }
                    return true
                }))
            engine = value
            return value
        }, testContext: { _ in
            var context = DiagnosticContext()
            context.microphone = .authorized; context.selectedInputAvailable = true
            context.accessibility = true; context.keyboardReadable = true
            return context
        }, startsUpdater: false)
        app.delegate = delegate
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let engine else { return }
                if !wrapped {
                    let receive = engine.onResult
                    engine.onResult = { value in counts.delivered(value); receive?(value) }
                    wrapped = true
                }
                let control = root.appendingPathComponent("control.json")
                if let data = try? Data(contentsOf: control),
                   let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    try? FileManager.default.removeItem(at: control)
                    if value["command"] == "recall" { app.sendAction(NSSelectorFromString("showLastResult"), to: delegate, from: nil) }
                    if value["command"] == "regular-toggle" {
                        if engine.state == .idle { recordingFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier }
                        app.sendAction(NSSelectorFromString("toggleDictation"), to: delegate, from: nil)
                    }
                    if value["command"] == "segment" {
                        segmentNumber += 1
                        recorder?.onSamples?(Array(repeating: Float(segmentNumber) / 10, count: 1600))
                        segmenter?.flush()
                    }
                    if value["command"] == "pause" { app.sendAction(NSSelectorFromString("togglePauseResume"), to: delegate, from: nil) }
                    if value["command"] == "cancel" { app.sendAction(NSSelectorFromString("cancelDictation"), to: delegate, from: nil) }
                    if value["command"] == "profile" {
                        let item = NSMenuItem(); item.representedObject = Config.load().profiles.last?.id.uuidString
                        app.sendAction(NSSelectorFromString("selectProfile:"), to: delegate, from: item)
                    }
                }
                let timings = engine.phaseTimings
                var data = counts.snapshot
                data["state"] = String(describing: engine.state)
                data["ready"] = wrapped
                data["clipboardUnchanged"] = NSPasteboard.general.changeCount == clipboard
                data["frontUnchanged"] = recordingFrontPID.map { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0 } ?? true
                data["previewText"] = engine.transcriptPreview?.text ?? ""
                data["previewFailed"] = engine.transcriptPreview?.hasFailedSegment ?? false
                data["previewTruncated"] = engine.transcriptPreview?.isTruncated ?? false
                data["preparationSec"] = timings.preparationSec as Any? ?? NSNull()
                data["transcriptionSec"] = timings.transcriptionSec
                data["transcriptionCount"] = timings.transcriptionCount
                data["cleanupSec"] = timings.cleanupSec as Any? ?? NSNull()
                data["recordingSec"] = timings.recordingSec as Any? ?? NSNull()
                data["historyEntries"] = (try? engine.history.list().count) ?? -1
                data["wavFiles"] = (try? FileManager.default.contentsOfDirectory(at: engine.history.recordingsDir,
                    includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }.count) ?? -1
                try! JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted,.sortedKeys])
                    .write(to: root.appendingPathComponent("state.json"), options: .atomic)
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
private enum FixtureFailure: Error { case isolation, device }
private final class FixtureCounts {
    private let lock = NSLock()
    private var recorders = 0, transcriptions = 0, cleanup = 0, warmups = 0, results = 0
    private var rawFallback = false
    func recorder() { lock.withLock { recorders += 1 } }
    func transcribed() { lock.withLock { transcriptions += 1 } }
    func cleaned() { lock.withLock { cleanup += 1 } }
    func warmed() { lock.withLock { warmups += 1 } }
    func delivered(_ result: DictationResult) { lock.withLock { results += 1; rawFallback = result.entry?.cleanupFellBack == true } }
    var snapshot: [String: Any] {
        lock.withLock { ["recorders":recorders,"transcriptions":transcriptions,"cleanupCalls":cleanup,
                        "warmups":warmups,"results":results,"rawFallback":rawFallback] }
    }
}
private final class FixtureRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    private let counts: FixtureCounts
    private let fails: Bool
    private let automatic: Bool
    private var timer: Timer?
    init(counts: FixtureCounts, fails: Bool, automatic: Bool) { self.counts = counts; self.fails = fails; self.automatic = automatic }
    func start() throws {
        counts.recorder()
        if fails { throw FixtureFailure.device }
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.onSamples?(Array(repeating: 0.1, count: 800))
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}
private final class FixtureSegmenter: DictationSegmenter {
    var onSegment: ((VadSegmenter.Segment) -> Void)?, onAutoStop: (() -> Void)?
    var currentLevelDb: Double { -20 }
    private var samples: [Float] = []
    func process(_ values: [Float]) { samples += values }
    func flush() {
        guard !samples.isEmpty else { return }
        onSegment?(.init(samples: samples, hadSpeech: true, reason: .flush)); samples = []
    }
}
private final class FixtureTranscriber: DictationTranscriber {
    let counts: FixtureCounts
    let language: String
    let scenario: String
    init(counts: FixtureCounts, language: String, scenario: String) { self.counts = counts; self.language = language; self.scenario = scenario }
    func isReachable() async -> Bool { true }
    func transcribe(samples: [Float]) async throws -> String {
        counts.transcribed()
        if scenario.hasPrefix("preview") {
            let number = Int(((samples.first ?? 0) * 10).rounded())
            try await Task.sleep(nanoseconds: number == 1 ? 600_000_000 : 100_000_000)
            if scenario == "preview-failure", number == 2 { throw FixtureFailure.device }
            return language == "en" ? "Segment \(number): do not restart." : "Abschnitt \(number): nicht neu starten."
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return language == "en" ? "Synthetic microphone test: 128, not 256." : "Künstlicher Mikrofontest: 128, nicht 256."
    }
    func transcribe(wavFile: URL) async throws -> String { try await transcribe(samples: [0.1]) }
}
private final class FixtureServer: DictationServer {
    func ensureRunning(reachability: any DictationTranscriber) async throws { try await Task.sleep(nanoseconds: 150_000_000) }
    func stop() {}
}
private final class FixtureCleanup: DictationCleanup {
    let counts: FixtureCounts
    let fallback: Bool
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    init(counts: FixtureCounts, fallback: Bool) { self.counts = counts; self.fallback = fallback }
    func warmUp() { counts.warmed() }
    func clean(_ rawText: String) async -> CleanupService.Result {
        counts.cleaned()
        try? await Task.sleep(nanoseconds: 100_000_000)
        return .init(text: rawText, usedFallback: fallback,
                     fallbackReason: fallback ? L10n.text("test_dictation.raw") : nil, endpoint: nil)
    }
}
