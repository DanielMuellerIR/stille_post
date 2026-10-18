import Foundation

public struct DiagnosticFinding: Identifiable, Equatable, Sendable {
    public enum Level: String, Sendable { case ready, information, warning, problem, unknown }
    public enum Category: String, CaseIterable, Sendable { case microphone, whisper, model, cleanup, accessibility, bridge }
    public enum Action: String, Sendable { case none, recordingSettings, speechSettings, cleanupSettings, generalSettings, microphonePrivacy, accessibilityPrivacy }
    public let id: String
    public let category: Category
    public let level: Level
    public let code: String
    public let action: Action
    public var message: String {
        let body = L10n.text("diagnosis.finding." + code)
        guard category == .cleanup, let position = Int(id.split(separator: ".").last ?? "") else { return body }
        let name = position == 0 ? L10n.text("cli.doctor.primary") : L10n.format("settings.cleanup.fallback_number", position)
        return name + ": " + body
    }
}

public struct DiagnosticReport: Sendable {
    public let date: Date
    public let findings: [DiagnosticFinding]
    public var problemCount: Int { findings.filter { $0.level == .problem }.count }
    public var hasUnknowns: Bool { findings.contains { $0.level == .unknown } }

    /// Nur feste Befundcodes; Konfiguration, Pfade und fremde Fehlertexte bleiben
    /// außerhalb des kopierbaren Berichts, auch wenn sie Geheimnisse enthalten.
    public func export(version: String) -> String {
        let safeVersion = version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil ? version : "unknown"
        let stamp = ISO8601DateFormatter().string(from: date)
        return (["Stille Post " + safeVersion, stamp] + findings.map {
            "\($0.id): \($0.level.rawValue) / \($0.code)"
        }).joined(separator: "\n")
    }
}

public struct DiagnosticContext: Sendable {
    public enum Permission: Sendable { case authorized, notDetermined, denied, restricted, unknown }
    public enum BridgeState: Sendable { case running, stopped, unknown }
    public var microphone: Permission = .unknown
    public var selectedInputAvailable: Bool? = nil
    public var accessibility: Bool? = nil
    public var keyboardReadable: Bool? = nil
    public var bridge: BridgeState = .unknown
    public init() {}
}

public final class DiagnosticsService {
    struct Dependencies {
        var whisper: (Config.Whisper) async -> WhisperClient.Health
        var executable: (String) -> Bool
        var model: (String) -> ModelInstaller.InstallState
        var cleanup: (Config.Cleanup, Config.Cleanup.Endpoint) async -> CleanupService.EndpointCheck
        var hasRemoteKey: (String) -> Bool
        var bridgeToken: () -> TokenState
        static let live = Self(
            whisper: { await WhisperClient(config: $0).health() },
            executable: { FileManager.default.isExecutableFile(atPath: Config.expandPath($0)) },
            model: { ModelInstaller.state(atPath: $0) },
            cleanup: { await CleanupService(config: $0).checkOllamaEndpoint($1) },
            hasRemoteKey: { CleanupService.remoteAPIKey(envVar: $0) != nil },
            bridgeToken: {
                switch BridgeToken.loadOutcome() {
                case .token: return .present
                case .missing: return .missing
                case .failed: return .failed
                }
            })
    }
    enum TokenState { case present, missing, failed }
    private let dependencies: Dependencies
    public convenience init() { self.init(dependencies: .live) }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    public func scan(configuration config: Config, context: DiagnosticContext = .init()) async throws -> DiagnosticReport {
        try Task.checkCancellation()
        var findings: [DiagnosticFinding] = []
        func add(_ id: String, _ category: DiagnosticFinding.Category, _ level: DiagnosticFinding.Level,
                 _ code: String, _ action: DiagnosticFinding.Action = .none) {
            findings.append(.init(id: id, category: category, level: level, code: code, action: action))
        }
        switch context.microphone {
        case .authorized: add("microphone.permission", .microphone, .ready, "microphone_ready")
        case .notDetermined: add("microphone.permission", .microphone, .warning, "microphone_unasked", .microphonePrivacy)
        case .denied, .restricted: add("microphone.permission", .microphone, .problem, "microphone_denied", .microphonePrivacy)
        case .unknown: add("microphone.permission", .microphone, .unknown, "microphone_unknown")
        }
        if let available = context.selectedInputAvailable {
            add("microphone.device", .microphone, available ? .ready : .problem,
                available ? "device_ready" : "device_missing", .recordingSettings)
        }
        if let trusted = context.accessibility {
            add("accessibility", .accessibility, trusted ? .ready : .warning,
                trusted ? "accessibility_ready" : "accessibility_missing", trusted ? .none : .accessibilityPrivacy)
        } else { add("accessibility", .accessibility, .unknown, "accessibility_unknown") }

        if config.hotkeyMode == .hold, let readable = context.keyboardReadable {
            add("keyboard.state", .accessibility, readable ? .ready : .problem,
                readable ? "keyboard_ready" : "keyboard_missing", readable ? .none : .accessibilityPrivacy)
        }

        let health: WhisperClient.Health
        if (try? WhisperEndpoint(serverURL: config.whisper.serverURL)) == nil {
            health = .unavailable
            add("whisper.endpoint", .whisper, .problem, "whisper_invalid", .speechSettings)
        } else {
            health = await dependencies.whisper(config.whisper)
            try Task.checkCancellation()
            switch health {
            case .ready: add("whisper.health", .whisper, .ready, "whisper_ready")
            case .loading: add("whisper.health", .whisper, .warning, "whisper_loading")
            case .unexpectedResponse: add("whisper.health", .whisper, .problem, "whisper_unexpected", .speechSettings)
            case .unavailable:
                add("whisper.health", .whisper, config.whisper.autostart ? .warning : .problem,
                    config.whisper.autostart ? "whisper_will_start" : "whisper_no_autostart", .speechSettings)
            }
        }
        if config.whisper.autostart || health == .ready || health == .loading {
            let needed = health == .unavailable
            let binaryPresent = dependencies.executable(config.whisper.binaryPath)
            add("whisper.binary", .whisper, binaryPresent ? .ready : (needed ? .problem : .warning),
                binaryPresent ? "binary_ready" : (needed ? "binary_missing" : "binary_cold_start"), .speechSettings)
            switch dependencies.model(config.whisper.modelPath) {
            case .installed: add("whisper.model", .model, .ready, "model_ready")
            case .borrowed: add("whisper.model", .model, needed ? .problem : .warning, "model_borrowed", .speechSettings)
            case .missing: add("whisper.model", .model, needed ? .problem : .warning,
                               needed ? "model_missing" : "model_cold_start", .speechSettings)
            }
        }
        if config.whisper.language == "auto" { add("whisper.language", .whisper, .warning, "language_auto", .speechSettings) }

        if !config.cleanup.enabled { add("cleanup", .cleanup, .information, "cleanup_disabled") }
        else {
            var usable = 0
            for (index, endpoint) in config.cleanup.chain.enumerated() {
                try Task.checkCancellation()
                let id = "cleanup.\(index)"
                guard CleanupService.endpointAllowed(endpoint, localOnly: config.cleanup.localOnly) else {
                    add(id, .cleanup, .warning, "cleanup_blocked_local", .cleanupSettings); continue
                }
                if endpoint.provider == "openai" {
                    guard CleanupService.remoteChatURL(endpoint.remote) != nil else {
                        add(id, .cleanup, .warning, "cleanup_invalid", .cleanupSettings); continue
                    }
                    guard config.cleanup.localOnly || dependencies.hasRemoteKey(endpoint.remote.apiKeyEnvVar) else {
                        add(id, .cleanup, .warning, "cleanup_key_missing", .cleanupSettings); continue
                    }
                    usable += 1
                    add(id, .cleanup, .unknown, "cleanup_remote_unverified", .cleanupSettings)
                } else {
                    let checked = await dependencies.cleanup(config.cleanup, endpoint)
                    try Task.checkCancellation()
                    switch checked {
                    case .ready: usable += 1; add(id, .cleanup, .ready, index == 0 ? "cleanup_ready" : "cleanup_fallback_ready")
                    case .modelMissing: add(id, .cleanup, .warning, "cleanup_model_missing", .cleanupSettings)
                    case .unreachable: add(id, .cleanup, .warning, "cleanup_unreachable", .cleanupSettings)
                    }
                }
            }
            if usable == 0 { add("cleanup.chain", .cleanup, .problem, "cleanup_none", .cleanupSettings) }
        }
        try Task.checkCancellation()
        if !config.bridge.enabled { add("bridge", .bridge, .information, "bridge_disabled") }
        else {
            switch dependencies.bridgeToken() {
            case .missing: add("bridge.token", .bridge, .problem, "bridge_token_missing", .generalSettings)
            case .failed: add("bridge.token", .bridge, .problem, "bridge_token_failed", .generalSettings)
            case .present: add("bridge.token", .bridge, .ready, "bridge_token_ready")
            }
            switch context.bridge {
            case .running: add("bridge.listener", .bridge, .ready, "bridge_running")
            case .stopped: add("bridge.listener", .bridge, .problem, "bridge_stopped", .generalSettings)
            case .unknown: add("bridge.listener", .bridge, .unknown, "bridge_unknown", .generalSettings)
            }
        }
        try Task.checkCancellation()
        return DiagnosticReport(date: Date(), findings: findings)
    }
}
