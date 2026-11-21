import AppKit
import StillePostCore

// Diese lokalen Starteinstiege sind Teil der Bundle-Abnahme, auch beim Release-Build.
@MainActor
struct AppLaunchHarness {
    enum SettingsDestination {
        case settings
        case diagnostics, testDictation, audioImport
    }

    private enum SyntheticResult: String {
        case seed, success, raw, empty, failed, long
        case concurrentPrivate = "concurrent-private"
        case localPolicy = "local-policy"
    }

    let opensStatusMenu: Bool
    let opensHistory: Bool
    let settingsDestination: SettingsDestination?
    let settingsTab: SettingsWindowController.Tab?
    private let overlayPreview: String?
    private let isolatedPaths: Bool
    private let syntheticResult: SyntheticResult?
    private let seedsPreviousResult: Bool
    private let tracesHistory: Bool

    var hasSyntheticResult: Bool { syntheticResult != nil }

    init(environment: [String: String]) {
        opensStatusMenu = environment["STILLEPOST_OPEN_MENU"] != nil
        opensHistory = environment["STILLEPOST_OPEN_HISTORY"] != nil
        let tab = environment["STILLEPOST_OPEN_SETTINGS"]
        settingsTab = tab.flatMap(SettingsWindowController.Tab.init(rawValue:))
        switch tab {
        case "diagnose": settingsDestination = .diagnostics
        case "testdiktat": settingsDestination = .testDictation
        case "audioimport": settingsDestination = .audioImport
        case .some: settingsDestination = .settings
        case nil: settingsDestination = nil
        }
        overlayPreview = environment["STILLEPOST_OVERLAY_PREVIEW"]
        isolatedPaths = Self.hasIsolatedPaths(environment)
        syntheticResult = isolatedPaths ? environment["STILLEPOST_RESULT_TEST"].flatMap(SyntheticResult.init(rawValue:)) : nil
        seedsPreviousResult = environment["STILLEPOST_RESULT_TEST_PREVIOUS"] == "1"
        tracesHistory = isolatedPaths && environment["STILLEPOST_HISTORY_TRACE"] == "1"
    }

    private static func hasIsolatedPaths(_ environment: [String: String]) -> Bool {
        guard let support = environment["STILLEPOST_APP_SUPPORT"], !support.isEmpty,
              let configuration = environment["STILLEPOST_CONFIG"], !configuration.isEmpty,
              let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return false }
        let regularSupport = applicationSupport.appendingPathComponent("StillePost").resolvingSymlinksInPath()
        let regularConfiguration = regularSupport.appendingPathComponent("config.json").resolvingSymlinksInPath()
        let supportOverride = URL(fileURLWithPath: Config.expandPath(support)).resolvingSymlinksInPath()
        let configurationOverride = URL(fileURLWithPath: Config.expandPath(configuration)).resolvingSymlinksInPath()
        return supportOverride.path != regularSupport.path && configurationOverride.path != regularConfiguration.path
    }

    func tracePrivateHistory(storesText: Bool) {
        guard tracesHistory else { return }
        FileHandle.standardError.write(Data("history-policy: storesText=\(storesText)\n".utf8))
    }

    func presentOverlay(_ overlay: OverlayController, engine: DictationEngine, configuration: Config,
                        hotkeyMode: Config.HotkeyMode) {
        guard let overlayPreview else { return }
        let hold = hotkeyMode == .hold
        let context = L10n.format("profiles.recording", configuration.profileLabel, configuration.whisper.language)
        if isolatedPaths, overlayPreview.hasPrefix("raw-preview") {
            let sample = L10n.text("overlay.live_preview.sample")
            overlay.liveTranscriptPreview = configuration.ui.liveTranscriptPreview
            overlay.recordingContext = context
            switch overlayPreview {
            case "raw-preview-waiting":
                break
            case "raw-preview-empty-failed":
                overlay.transcriptPreview = DictationTranscriptPreview(text: "", hasFailedSegment: true)
            case "raw-preview-long":
                let long = String(repeating: sample + " ", count: 60) + L10n.text("overlay.live_preview.sample_end")
                overlay.transcriptPreview = DictationTranscriptPreview(text: long, hasFailedSegment: false)
            default:
                overlay.transcriptPreview = DictationTranscriptPreview(
                    text: sample, hasFailedSegment: overlayPreview.hasSuffix("failed"))
            }
            switch overlayPreview {
            case "raw-preview-paused": overlay.show(.paused)
            case "raw-preview-resuming": overlay.show(.starting(hold: false, resuming: true))
            default: overlay.show(.recording)
            }
        }
        if isolatedPaths, configuration.vad.detector == .silero {
            let vad = configuration.vad
            Task { [weak overlay, weak engine] in
                let detector = await VadSegmenter.prepared(config: vad)
                guard engine?.hasInFlightRequests == false else { return }
                overlay?.recordingVad = detector.fallbackReason.map {
                    L10n.format("vad.fallback_status", $0)
                } ?? L10n.text("vad.active")
            }
        }

        switch overlayPreview {
        case "recording", "paused":
            overlay.recordingContext = context
            overlay.recordingReason = configuration.requestProfileSelection?.label ?? ""
            overlay.recordingInstruction = hold ? L10n.text("hotkey.hold.release") : ""
            overlay.show(overlayPreview == "paused" ? .paused : .recording)
        case "resuming":
            overlay.show(.starting(hold: hold, resuming: true))
        case "hold-unavailable":
            overlay.show(.failure(L10n.text("hotkey.hold.unavailable")))
        case "starting":
            overlay.show(.starting(hold: hold))
        case "processing-fallback":
            overlay.show(.processing(detail: L10n.format("app.cleanup_fallback", "gemma4:e4b-it-qat @ http://127.0.0.1:11434")))
        case "success-raw":
            overlay.show(.success(note: L10n.text("app.raw_fallback_note")))
        case "clipboard-target-changed":
            overlay.show(.clipboard(note: L10n.text("app.paste_target_changed")))
        case "clipboard-target-unavailable":
            overlay.show(.clipboard(note: L10n.text("app.paste_target_unavailable")))
        case "clipboard-changed":
            overlay.show(.failure(L10n.text("app.paste_clipboard_changed")))
        default:
            break
        }
    }

    func exerciseResultDelivery(engine: DictationEngine, configuration: Config, remember: (String) -> Void) {
        guard let syntheticResult else { return }
        if seedsPreviousResult { remember("Zuvor bestätigter Testtext.") }
        let sample = "Dies ist ein künstlicher Ergebnistext. Zahlen: 128 Euro."
        switch syntheticResult {
        case .seed:
            remember(sample)
        case .localPolicy:
            let cleanup = configuration.cleanup
            Task { [weak engine] in
                let raw = "Die Zahl bleibt 128 und Version 2.4 wird nicht geändert."
                let result = await CleanupService(config: cleanup).clean(raw)
                var entry = HistoryStore.Entry(rawText: raw, cleanText: result.text, status: "ok", durationSec: 1,
                    cleanupFellBack: result.usedFallback, cleanupFallbackReason: result.fallbackReason)
                entry.storesText = false
                engine?.onResult?(DictationResult(text: result.text, entry: entry))
            }
        case .success, .raw, .empty, .failed, .long, .concurrentPrivate:
            engine.onStateChange?(.starting)
            engine.onStateChange?(.idle)
            let text: String
            switch syntheticResult {
            case .empty, .failed: text = ""
            case .long: text = (1...80).map { "Absatz \($0): \(sample)" }.joined(separator: "\n\n")
            default: text = sample
            }
            let entry = HistoryStore.Entry(rawText: text, cleanText: text,
                status: syntheticResult == .failed ? "failed" : "ok", durationSec: 1,
                cleanupFellBack: syntheticResult == .raw)
            engine.onResult?(DictationResult(text: text, entry: entry))
            if syntheticResult == .concurrentPrivate {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak engine] in
                    var retry = HistoryStore.Entry(rawText: "", cleanText: "Älteres privates Wiederholungsergebnis 256.",
                        status: "ok", durationSec: 1)
                    retry.storesText = false
                    engine?.onPrivateRetryResult?(retry)
                }
            }
        }
    }
}
