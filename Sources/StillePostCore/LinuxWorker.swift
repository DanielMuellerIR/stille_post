#if os(Linux)
import Foundation
import Glibc

/// Privates, begrenztes JSONL-Protokoll zwischen GUI und unverändertem Diktierkern.
/// Audio wird in kleinen Float32-Blöcken über dieselbe vererbte Pipe übertragen.
@MainActor
public final class LinuxWorker {
    nonisolated private static let maximumMessageBytes = 4 * 1024 * 1024
    public nonisolated static var version: String { LinuxInstallation.version }
    private var config: Config
    private let startupWhisper: Config.Whisper
    private let engine: DictationEngine
    private let output = LinuxWorkerOutput()
    private let ollama = LinuxOllamaService()
    private let bridge = LinuxBridgeService()
    private var bridgeReady = false
    private var pendingPreviews: [UUID: TransientResultStore.Result] = [:]
    private var meter: DispatchSourceTimer?
    private var maintenanceTask: Task<Void, Never>?
    private var nextMaintenance: TimeInterval = 0
    private var operation: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var holdActive = false
    private var holdState = DictationHotkeyState()
    private var holdStarted: TimeInterval?
    private var temporaryPrivateHistory = false
    private var activeApplication: String?
    private var lastResult = TransientResultStore()
    private var recleanCandidates: [UUID: HistoryRecleanup.Candidate] = [:]
    private var testSession: TestDictationSession?
    private var importSession: AudioImportSession?
    private let messageImportEvent = "importResult"

    public init() throws {
        LinuxNetworkBootstrap.prepare()
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
        umask(0o077)
        config = try ConfigFile().loadSnapshot()
        startupWhisper = config.whisper
        engine = DictationEngine(config: config)
        AudioRecorder.capture = { [weak self] active, device in
            self?.send(["event": "capture", "active": active, "device": device])
        }
        engine.onStateChange = { [weak self] state in
            let value: String
            switch state {
            case .idle: value = "idle"
            case .starting: value = "starting"
            case .recording: value = "recording"
            case .paused: value = "paused"
            case .resuming: value = "starting"
            case .processing: value = "processing"
            case .error: value = "error"
            }
            self?.holdState.didChangeState(state)
            if self?.holdState.ownsHold != true {
                self?.holdActive = false
                self?.holdStarted = nil
            }
            self?.testSession?.receiveState(state)
            self?.importSession?.receiveState(state)
            self?.send([
                "event": "state", "state": value,
                "duration": self?.engine.recordingDuration ?? 0,
                "sessionKind": self.map { $0.testSession?.owns($0.engine) == true ? "test" : $0.importSession?.owns($0.engine) == true ? "import" : "dictation" } ?? "dictation",
                "profile": self?.engine.sessionConfiguration.profileLabel ?? "",
                "storesText": self?.engine.sessionConfiguration.history.storeText ?? false,
                "context": self.map { L10n.format("profiles.recording", $0.engine.sessionConfiguration.profileLabel, $0.engine.sessionConfiguration.whisper.language) } ?? "",
                "reason": self?.engine.sessionConfiguration.requestProfileSelection?.label ?? "",
                "instruction": self?.engine.sessionConfiguration.hotkeyMode == .hold ? L10n.text("hotkey.hold.release") : "",
            ])

            if case .error(let message) = state {
                self?.send(["event": "error", "message": DiagnosticText.shortened(message)])
            }
        }
        engine.requestAppBundleID = { [weak self] in self?.activeApplication }
        engine.onTranscriptPreview = { [weak self] preview in
            self?.send([
                "event": "transcriptPreview", "text": preview?.text ?? "",
                "failed": preview?.hasFailedSegment ?? false,
            ])
        }
        engine.onAudioImportStage = { [weak self] stage in self?.importSession?.receiveStage(stage)
        }
        engine.onAudioImportProgress = { [weak self] progress in
            self?.importSession?.receiveProgress(progress)
            self?.send([
                "event": "importProgress", "seconds": progress.audioSeconds,
                "total": progress.totalSeconds ?? 0, "segments": progress.completedSegments,
                "fraction": progress.fraction ?? -1,
            ])
        }
        engine.onResult = { [weak self] result in
            guard let self else { return }
            if self.testSession?.owns(self.engine) == true {
                self.testSession?.receiveResult(result)
                self.sendResult(result, kind: "testResult")
            } else if self.importSession?.owns(self.engine) == true {
                self.importSession?.receiveResult(result)
                self.sendResult(result, kind: messageImportEvent)
            } else {
                let usable = TransientResultStore.Result(
                    text: result.text, rawFallback: result.entry?.cleanupFellBack ?? false,
                    failed: result.entry?.isFailed == true,
                    note: result.entry?.cleanupFallbackReason, origin: result.entry?.resultOrigin)
                if let usable,
                    self.engine.sessionConfiguration.ui.previewBeforePaste || !self.pendingPreviews.isEmpty {
                    let id = UUID()
                    self.pendingPreviews[id] = usable
                    self.sendResult(result, candidate: id)
                } else {
                    if let usable { self.remember(usable) }
                    self.sendResult(result)
                }
            }
        }
        engine.onCleanupFallback = { [weak self] label in
            self?.send(["event": "notice", "message": L10n.format("app.cleanup_fallback", label)])
        }
        engine.onCleanupPrimaryRetry = { [weak self] in
            self?.send(["event": "notice", "message": L10n.text("app.cleanup_primary_retry")])
        }
        engine.onVadFallback = { [weak self] reason in
            self?.send(["event": "notice", "message": L10n.format("vad.fallback_status", reason)])
        }
        engine.onPrivateRetryResult = { [weak self] entry in
            guard let self, let value = TransientResultStore.Result(text: entry.cleanText,
                rawFallback: entry.cleanupFellBack == true, note: entry.cleanupFallbackReason,
                origin: entry.resultOrigin) else { return }
            let id = UUID()
            self.pendingPreviews[id] = value
            self.send(["event": "privateRetryPreview", "candidate":id.uuidString,
                       "text":value.text, "rawFallback":value.rawFallback,
                       "note":value.note ?? "", "origin":value.origin.rawValue])
        }
        bridge.onStatus = { [weak self] ready, message in
            DispatchQueue.main.async { [weak self] in
                self?.bridgeReady = ready
                self?.send(["event": "bridgeStatus", "ready": ready, "message": message])
            }
        }
    }

    public func run() {
        send(["event": "ready", "protocol": 1])
        Task { await ollama.startIfNeeded(configuration: config) }
        bridge.configure(requestConfiguration)
        nextMaintenance = ProcessInfo.processInfo.systemUptime + 60
        maintainHistory()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.shutdownTask == nil else { return }
            // POLLERR meldet die geschlossene Ausgabepipe auch ohne Pegelmeldungen.
            var pipe = pollfd(fd: STDOUT_FILENO, events: 0, revents: 0)
            if Glibc.poll(&pipe, 1, 0) > 0 {
                self.requestShutdown()
                return
            }
            self.testSession?.pulse()
            if let started = self.holdStarted, self.holdActive,
                ProcessInfo.processInfo.systemUptime - started >= DictationHotkeyState.maximumHoldDuration {
                self.handleHold(.deadline)
            }
            if ProcessInfo.processInfo.systemUptime >= self.nextMaintenance {
                self.nextMaintenance = ProcessInfo.processInfo.systemUptime + 60
                self.maintainHistory()
            }
            if self.engine.state == .recording {
                self.send([
                    "event": "meter", "levelDb": self.engine.currentLevelDb,
                    "duration": self.engine.recordingDuration,
                ])
            }
        }
        timer.resume()
        meter = timer
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 32768)
                while true {
                    let count = Glibc.read(STDIN_FILENO, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw LinuxFailure.protocolFailure
                    }
                    pending.append(contentsOf: buffer.prefix(count))
                    guard pending.count <= Self.maximumMessageBytes + buffer.count else { throw LinuxFailure.protocolFailure }
                    while let index = pending.firstIndex(of: 10) {
                        let line = Data(pending.prefix(upTo: index))
                        pending.removeSubrange(...index)
                        guard line.count <= Self.maximumMessageBytes else {
                            throw LinuxFailure.protocolFailure
                        }
                        // Der Leser hält genau einen Auftrag am MainActor ausstehend.
                        // Weitere Audioblöcke warten in der begrenzten Elternprozess-Pipe.
                        try DispatchQueue.main.sync {
                            try handle(JSONDecoder().decode(LinuxWorkerRequest.self, from: line))
                        }
                    }
                }
            } catch {
                send([
                    "event": "error",
                    "message": L10n.text("linux.worker.disconnected"),
                ])
            }
            DispatchQueue.main.async { [self] in requestShutdown() }
        }
    }
    private nonisolated func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        else { return }
        sendFrame(data)
    }

    private func sendEvent<Event: Encodable>(_ event: Event) {
        do { sendFrame(try JSONEncoder().encode(event)) }
        catch { failure(error) }
    }

    private nonisolated func sendFrame(_ data: Data) {
        guard data.count < Self.maximumMessageBytes else { return }
        if !output.write(data) {
            DispatchQueue.main.async { [weak self] in self?.requestShutdown() }
        }
    }

    private func handle(_ message: LinuxWorkerRequest) {
        guard shutdownTask == nil else { return }
        if let operation = message.operation {
            perform(operation, request: message)
            return
        }
        guard let command = message.command else { return }
        switch command {
        case .application:
            guard let id = message.id, id.utf8.count <= 128, id.hasPrefix("linux."),
                id != activeApplication
            else { return }
            activeApplication = id
            sendConfiguration()
        case .start:
            guard operation == nil else {
                send(["event": "error", "message": L10n.text("selection.error.busy")])
                return
            }
            prepareRegular(message)
            engine.start()
        case .holdStart:
            guard operation == nil else {
                send(["event": "error", "message": L10n.text("selection.error.busy")])
                return
            }
            guard holdState.handle(.pressed, mode: .hold, state: engine.state) == .start else { return }
            prepareRegular(message)
            holdActive = true
            holdStarted = ProcessInfo.processInfo.systemUptime
            engine.start(onlyWhile: { [weak self] in self?.holdActive == true })
        case .holdEnd: handleHold(.released)
        case .holdInterrupted: handleHold(.interrupted)
        case .recall:
            if let value = lastResult.last {
                send(["event": "recall", "text": value.text, "rawFallback": value.rawFallback, "note": value.note ?? "", "origin": value.origin.rawValue])
            } else {
                send(["event": "notice", "message": L10n.text("result.none")])
            }
        case .completePreview:
            guard let id = message.candidate.flatMap(UUID.init),
                let value = pendingPreviews.removeValue(forKey: id) else { return }
            if message.accepted == true { remember(value) }
            send(["event":"previewCompleted", "candidate":id.uuidString])
        case .profile:
            guard !engine.hasInFlightRequests else { return }
            do {
                config = try ConfigFile().selectProfile(
                    message.id.flatMap(UUID.init))
                engine.configure(requestConfiguration)
                bridge.updateConfiguration(requestConfiguration)
                sendConfiguration()
            } catch { failure(error) }
        case .privateHistory:
            guard config.resolvedForRequest().history.storeText else { return }
            temporaryPrivateHistory = message.enabled ?? !temporaryPrivateHistory
            engine.suppressTranscriptPreview()
            engine.configure(requestConfiguration)
            bridge.updateConfiguration(requestConfiguration)
            sendHistoryPolicy()
        case .startTest:
            guard operation == nil, !engine.hasInFlightRequests, pendingPreviews.isEmpty else {
                send(["event": "testStatus", "state": "failed", "active": false,
                      "message": L10n.text("test_dictation.failed"), "error": L10n.text("selection.error.busy")])
                return
            }
            do {
                let reviewed = try message.reviewed?.get() ?? requestConfiguration
                _ = importSession?.releaseForRegularStart()
                importSession = nil
                testSession = TestDictationSession(engine: engine)
                testSession?.onChange = { [weak self] in self?.sendTestStatus() }
                testSession?.start(
                    configuration: reviewed, currentConfiguration: requestConfiguration,
                    nextRequestConfiguration: requestConfiguration,
                    inputAvailable: message.inputAvailable ?? true, allowed: true)
            } catch { failure(error) }
        case .stopTest: testSession?.stop()
        case .cancelTest: testSession?.cancel()
        case .closeTest:
            _ = testSession?.close()
            testSession = nil
        case .testReport:
            send([
                "event": "testReport",
                "text": testSession?.exportReport(
                    version: message.version ?? "unknown")
                    ?? "",
            ])
        case .stop: engine.stop()
        case .toggle:
            guard operation == nil else {
                send(["event": "error", "message": L10n.text("selection.error.busy")])
                return
            }
            switch engine.state {
            case .idle, .error: prepareRegular(message)
            default: break
            }
            engine.toggle()
        case .pause: engine.pause()
        case .resume: engine.resume()
        case .cancel: engine.cancel()
        case .captureError: AudioRecorder.active?.onFailure?(LinuxFailure.capture)
        case .samples:
            guard let encoded = message.data, let data = Data(base64Encoded: encoded),
                data.count <= 65536, data.count % 4 == 0
            else {
                AudioRecorder.active?.onFailure?(LinuxFailure.protocolFailure)
                return
            }
            let values: [Float] = data.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map {
                    Float(
                        bitPattern: UInt32(
                            littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
            }
            guard values.allSatisfy({ $0.isFinite }) else {
                AudioRecorder.active?.onFailure?(LinuxFailure.capture)
                return
            }
            AudioRecorder.active?.onSamples?(values)
        case .reviewImport, .reviewTest:
            if command == .reviewTest { testSession?.reset() }
            else { importSession?.reset() }
            let configuration = requestConfiguration
            let resolved = configuration.resolvedForRequest()
            sendEvent(LinuxWorkerEvent.Review(
                event: command == .reviewImport ? "importReview" : "testReview",
                configuration: configuration, profile: resolved.profileLabel,
                language: resolved.whisper.language,
                reason: resolved.requestProfileSelection?.label ?? "",
                history: resolved.history, localOnly: resolved.cleanup.localOnly,
                cleanupEnabled: resolved.cleanup.enabled))
        case .cancelImport: importSession?.cancel()
        case .closeImport: importSession?.close()
        case .importAudio:
            guard operation == nil, let path = message.path, path.hasPrefix("/"),
                !engine.hasInFlightRequests, pendingPreviews.isEmpty
            else {
                send(["event": "importStatus", "active": false, "finished": true,
                      "message": L10n.text("audio_import.failed"), "error": L10n.text("selection.error.busy")])
                return
            }
            do {
                let reviewed = try message.reviewed?.get() ?? requestConfiguration
                _ = testSession?.releaseForRegularStart()
                importSession = AudioImportSession(engine: engine)
                importSession?.onChange = { [weak self] in self?.sendImportStatus() }
                importSession?.start(
                    file: URL(fileURLWithPath: path), configuration: reviewed,
                    currentConfiguration: requestConfiguration,
                    nextRequestConfiguration: requestConfiguration, allowed: true)
            } catch { failure(error) }
        case .history:
            Task { [self] in
                do {
                    let entries = try await engine.history.listAsync()
                    var query = HistoryQuery()
                    query.text = message.text ?? ""
                    query.status =
                        HistoryQuery.Status(rawValue: message.status ?? "all") ?? .all
                    query.period =
                        HistoryQuery.Period(rawValue: message.period ?? "all") ?? .all
                    let filtered = query.filter(entries)
                    let offset = max(0, message.offset ?? 0)
                    let page = Array(filtered.dropFirst(offset).prefix(100))
                    sendEvent(LinuxWorkerEvent.History(
                        entries: page.map(LinuxWorkerHistoryEntry.init),
                        total: filtered.count, queryId: message.queryId ?? 0))
                } catch { failure(error) }
            }
        case .deleteHistory:
            guard let value = message.id, let id = UUID(uuidString: value) else {
                return
            }
            Task { [self] in
                do {
                    try await engine.history.deleteAsync(id: id)
                    send(["event": "historyDeleted", "id": id.uuidString])
                } catch {
                    send(["event": "error", "message": L10n.text("linux.history.delete_failed")])
                }
            }
        case .sileroStatus:
            Task { @MainActor [self] in
                let reason = await SileroModel.availability()
                send([
                    "event": "sileroStatus", "ready": reason == nil,
                    "message": reason ?? L10n.text("vad.ready"),
                ])
            }
        case .config:
            sendConfiguration()
        case .saveConfig:
            guard let replacement = message.config else { return }
            do {
                let replacement = try replacement.get()
                _ = try WhisperEndpoint(serverURL: replacement.whisper.serverURL)
                let expected = try message.expectedConfig?.get() ?? config
                try replacement.save(expected: expected)
                config = replacement
                engine.configure(requestConfiguration)
                bridge.updateConfiguration(requestConfiguration)
                sendConfiguration()
                send([
                    "event": "configSaved",
                    "whisperRestartRequired": config.whisper != runningWhisper,
                ])
            } catch {
                send([
                    "event": "error", "message": L10n.text("linux.config.save_failed"),
                ])
            }
        case .quit: requestShutdown()
        case .cancelOperation, .cancelSelection: operation?.cancel()
        case .discardRecleanup:
            if let id = message.candidate.flatMap(UUID.init) {
                recleanCandidates.removeValue(forKey: id)
            }
        case .clearLastResult: lastResult = TransientResultStore()
        case .difference: sendDifference(message)
        }
    }

    private func handleHold(_ input: DictationHotkeyState.Input) {
        let action = holdState.handle(input, mode: .hold, state: engine.state)
        holdActive = false
        holdStarted = nil
        switch action {
        case .stop, .stopAtLimit: engine.stop()
        case .cancel, .cancelAtLimit: engine.cancel()
        default: break
        }
        if action == .stopAtLimit || action == .cancelAtLimit {
            send(["event":"notice", "message":L10n.text("hotkey.hold.limit")])
        }
        if input == .interrupted { holdState = DictationHotkeyState() }
    }
    private func prepareRegular(_ message: LinuxWorkerRequest) {
        _ = testSession?.releaseForRegularStart()
        _ = importSession?.releaseForRegularStart()
        importSession = nil
        activeApplication = message.application
    }
    private func failure(_ error: Error) {
        send(["event": "error", "message": DiagnosticText.shortened(error.localizedDescription)])
    }
    private func maintainHistory() {
        guard shutdownTask == nil, maintenanceTask == nil else { return }
        maintenanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.maintenanceTask = nil }
            do {
                try await self.engine.history.applyRetentionAsync()
                self.send(["event": "historyChanged"])
            } catch { self.failure(error) }
        }
    }
    private func requestShutdown() {
        // Die GUI sendet quit und schließt direkt die Pipe. Beide Signale
        // müssen denselben Abschluss verwenden, auch bei einem GUI-Absturz.
        guard shutdownTask == nil else { return }
        shutdownTask = Task { @MainActor [self] in
            await shutdown()
            exit(0)
        }
    }
    @MainActor private func shutdown() async {
        meter?.cancel()
        meter = nil
        operation?.cancel()
        await operation?.value
        maintenanceTask?.cancel()
        await maintenanceTask?.value
        bridge.stop()
        ollama.stop()
        await engine.shutdown().value
    }
    private func sendConfiguration() {
        let resolved = config.resolvedForRequest(appBundleID: activeApplication)
        sendEvent(LinuxWorkerEvent.Configuration(
            config: config,
            vocabularyProfileID: resolved.vocabularyProfileID?.uuidString ?? "",
            vocabularyLabel: resolved.vocabularyProfileID == nil
                ? L10n.text("profiles.global") : resolved.profileLabel))
        sendHistoryPolicy()
    }
    private var runningWhisper: Config.Whisper {
        // Transkription, Bridge und der laufende Kindprozess verwenden dieselbe
        // Serverkonfiguration bis zum nächsten Programmstart.
        var active = startupWhisper
        active.language = config.whisper.language
        return active
    }

    private var requestConfiguration: Config {
        var result = config
        result.whisper = runningWhisper
        if temporaryPrivateHistory {
            result.history.storeText = false
            for index in result.profiles.indices where result.profiles[index].history != nil {
                result.profiles[index].history?.storeText = false
            }
        }
        return result
    }
    private func sendTestStatus() {
        guard let session = testSession else { return }
        let code: String
        let key: String
        var error = ""
        switch session.state {
        case .ready: code = "ready"; key = "test_dictation.ready"
        case .preparing: code = "preparing"; key = "test_dictation.preparing"
        case .recording: code = "recording"; key = "test_dictation.recording_status"
        case .paused: code = "paused"; key = "overlay.paused"
        case .processing: code = "processing"; key = "test_dictation.processing"
        case .completed: code = "completed"; key = "test_dictation.completed"
        case .silence: code = "silence"; key = "test_dictation.silence"
        case .cancelled: code = "cancelled"; key = "test_dictation.cancelled"
        case .failed(let message): code = "failed"; key = "test_dictation.failed"; error = message
        }
        let times = session.timings
        var phases: [String: Double] = ["transcription": times.transcriptionSec]
        if let value = times.preparationSec { phases["preparation"] = value }
        if let value = times.recordingSec { phases["recording"] = value }
        if let value = times.cleanupSec { phases["cleanup"] = value }
        send(["event": "testStatus", "state": code, "active": session.isActive,
              "message": L10n.text(key), "error": error, "levelDb": session.levelDb,
              "recordings": session.configuration == nil ? "" : session.recordingsDirectory.path,
              "timings": phases])
    }
    private func sendImportStatus() {
        guard let session = importSession else { return }
        let key: String
        var error = ""
        var finished = false
        switch session.state {
        case .ready: key = "audio_import.ready"
        case .processing(let stage):
            switch stage {
            case .decoding: key = "audio_import.decoding"
            case .transcribing: key = "audio_import.transcribing"
            case .cleaning: key = "audio_import.finishing"
            }
        case .cancelling: key = "audio_import.cancelling"
        case .completed: key = "audio_import.completed"; finished = true
        case .silence: key = "audio_import.silence"; finished = true
        case .cancelled: key = "audio_import.cancelled"; finished = true
        case .failed(let message): key = "audio_import.failed"; error = message; finished = true
        }
        send(["event": "importStatus", "active": session.isActive, "finished": finished,
              "message": L10n.text(key), "error": error,
              "recordings": session.configuration == nil ? "" : session.recordingsDirectory.path])
    }
    private func sendHistoryPolicy() {
        send([
            "event": "historyPolicy", "temporaryPrivate": temporaryPrivateHistory,
            "storesText": requestConfiguration.resolvedForRequest().history.storeText,
            "canToggle": config.resolvedForRequest().history.storeText,
        ])
    }
    private func remember(_ result: TransientResultStore.Result) {
        lastResult.accept(text: result.text, rawFallback: result.rawFallback,
                          note: result.note, origin: result.origin)
    }
    private func sendResult(_ result: DictationResult, kind: String = "result", candidate: UUID? = nil) {
        let times = engine.phaseTimings
        let phases: [String: Double] = [
            "preparation": times.preparationSec ?? 0, "recording": times.recordingSec ?? 0,
            "transcription": times.transcriptionSec, "cleanup": times.cleanupSec ?? 0,
            "segments": Double(times.transcriptionCount),
        ]
        sendEvent(LinuxWorkerEvent.Result(
            event: kind, text: result.text,
            rawFallback: result.entry?.cleanupFellBack ?? false,
            localFallback: result.entry?.cleanupEndpoint?.contains("127.0.0.1") ?? false,
            preview: candidate != nil, failed: result.entry?.isFailed == true,
            origin: result.entry?.resultOrigin.rawValue ?? "raw",
            note: result.entry?.cleanupFallbackReason ?? "", candidate: candidate,
            entry: result.entry.map(LinuxWorkerHistoryEntry.init), timings: phases))
    }
    private func sendDifference(_ message: LinuxWorkerRequest) {
        do {
            let result = try TextDifference.compare(message.before ?? "", message.after ?? "")
            send([
                "event": "difference", "entryID": message.entryID ?? "",
                "summarized": result.isSummarized,
                "segments": result.segments.map {
                    ["kind": String(describing: $0.kind), "text": $0.text]
                },
            ])
        } catch { failure(error) }
    }

    private func perform(_ command: LinuxWorkerRequest.Operation, request message: LinuxWorkerRequest) {
        guard operation == nil, !engine.hasInFlightRequests else {
            send(["event": "error", "message": L10n.text("selection.error.busy")])
            return
        }
        operation = Task { @MainActor [self] in
            send(["event": "operation", "active": true, "kind": command.rawValue])
            defer {
                operation = nil
                send(["event": "operation", "active": false, "kind": command.rawValue])
            }
            do {
                switch command {
                case .installSilero:
                    try await SileroModel.install()
                    send(["event": "sileroInstalled"])
                case .bridgeRenewIdentity, .bridgeRotateToken:
                    try await Task.detached {
                        if command == .bridgeRenewIdentity {
                            _ = try LinuxBridgeIdentity.renew()
                        } else {
                            _ = try BridgeToken.rotate()
                        }
                    }.value
                    bridge.configure(requestConfiguration, forceRestart: true)
                    send(["event": "bridgeCredentialsChanged"])
                case .bridgePair:
                    let value = try await Task.detached { [config] in
                        try LinuxBridgeService.pairing(port: config.bridge.port)
                    }.value
                    sendEvent(LinuxWorkerEvent.BridgePairing(pairing: value))
                    bridge.configure(requestConfiguration)
                case .editHistory:
                    let entry = try await engine.history.saveCorrectionAsync(
                        message.text ?? "", expected: message.historyEntry())
                    sendEvent(LinuxWorkerEvent.HistorySaved(entry: LinuxWorkerHistoryEntry(entry: entry)))
                case .retryHistory:
                    let expected = try message.historyEntry()
                    guard
                        let current = try await engine.history.listAsync().first(where: {
                            $0.id == expected.id
                        }), current == expected, current.canRetry
                    else { throw HistoryStore.PersistenceError.correctionConflict }
                    let entry = try await engine.retry(entry: expected)
                    sendEvent(LinuxWorkerEvent.HistorySaved(entry: LinuxWorkerHistoryEntry(entry: entry)))
                case .recleanHistory:
                    let candidate = try await HistoryRecleanup.run(
                        expected: message.historyEntry(), history: engine.history,
                        appBundleID: activeApplication)
                    let id = UUID()
                    recleanCandidates.removeAll()
                    recleanCandidates[id] = candidate
                    send([
                        "event": "recleanupPreview", "candidate": id.uuidString,
                        "before": candidate.expected.cleanText, "text": candidate.result.text,
                    ])
                case .acceptRecleanup:
                    guard let id = message.candidate.flatMap(UUID.init),
                        let candidate = recleanCandidates.removeValue(forKey: id)
                    else { throw LinuxFailure.protocolFailure }
                    let entry = try await engine.history.saveRecleanupAsync(
                        candidate.result, durationSec: candidate.durationSec,
                        expected: candidate.expected)
                    sendEvent(LinuxWorkerEvent.HistorySaved(entry: LinuxWorkerHistoryEntry(entry: entry)))
                case .addVocabulary:
                    let expected = try message.historyEntry()
                    let term = message.term ?? ""
                    let variant = message.variant
                    let profile: UUID?
                    if let reviewed = message.vocabularyProfileID {
                        if reviewed.isEmpty {
                            profile = nil
                        } else {
                            guard let id = UUID(uuidString: reviewed) else {
                                throw LinuxFailure.protocolFailure
                            }
                            profile = id
                        }
                    } else {
                        profile =
                            config.resolvedForRequest(appBundleID: activeApplication)
                            .vocabularyProfileID
                    }
                    let updated = try await engine.history.withEditableSnapshotAsync(
                        expected: expected
                    ) {
                        try ConfigFile().addVocabulary(
                            term: term, variant: variant, profileID: profile)
                    }
                    config = updated
                    engine.configure(requestConfiguration)
                    bridge.updateConfiguration(requestConfiguration)
                    sendConfiguration()
                    send(["event": "vocabularySaved"])
                case .deleteAllHistory:
                    try engine.history.deleteAll()
                    send(["event": "historyChanged"])
                case .applyRetention:
                    try await engine.history.applyRetentionAsync()
                    send(["event": "historyChanged"])
                case .diagnostics:
                    var context = DiagnosticContext()
                    context.microphone = .unknown
                    context.selectedInputAvailable = message.microphone
                    context.accessibility = message.accessibility
                    context.keyboardReadable = message.keyboard
                    context.bridge = bridgeReady ? .running : .stopped
                    let report = try await DiagnosticsService().scan(
                        configuration: requestConfiguration.resolvedForRequest(
                            appBundleID: activeApplication),
                        context: context)
                    send([
                        "event": "diagnostics",
                        "findings": report.findings.map {
                            [
                                "id": $0.id, "category": $0.category.rawValue,
                                "level": $0.level.rawValue,
                                "message": $0.message, "action": $0.action.rawValue,
                            ]
                        },
                        "report": report.export(
                            version: message.version ?? "unknown"),
                    ])
                case .checkEndpoint:
                    let endpoint = try message.endpoint?.get() ?? Config.Cleanup.Endpoint()
                    let state = await CleanupService(config: config.cleanup).checkOllamaEndpoint(
                        endpoint)
                    send(["event": "endpointCheck", "state": String(describing: state)])
                case .installModel:
                    guard let name = message.model,
                        let model = ModelCatalog.model(named: name)
                    else { throw LinuxFailure.protocolFailure }
                    let path = try await ModelInstaller().install(
                        model, to: config.whisper.modelPath
                    ) {
                        [weak self] progress in
                        self?.send([
                            "event": "modelProgress", "received": progress.receivedBytes,
                            "total": progress.totalBytes,
                        ])
                    }
                    send(["event": "modelInstalled", "path": path])
                case .cleanupSelection:
                    let text = message.text ?? ""
                    try TextSelectionSnapshot.validate(text)
                    let snapshot = config.resolvedForRequest(
                        appBundleID: message.application)
                    let result = await CleanupService(config: snapshot.cleanup).clean(text)
                    try Task.checkCancellation()
                    send([
                        "event": "selectionPreview", "before": text, "text": result.text,
                        "rawFallback": result.usedFallback,
                    ])
                case .setCleanupKey:
                    guard let key = message.key, key.utf8.count <= 8192 else {
                        throw LinuxFailure.protocolFailure
                    }
                    try CleanupService.storeRemoteAPIKey(key)
                    send(["event": "keyStored"])
                }
            } catch { if !Task.isCancelled { failure(error) } }
        }
    }
    public nonisolated static func cleanStandardInput() async throws {
        // Auch bei verzögerten Pipe-Blöcken liest Foundation bis zur angefragten Länge oder EOF.
        let input = try FileHandle.standardInput.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard input.count <= 1024 * 1024, let raw = String(data: input, encoding: .utf8) else {
            throw LinuxFailure.protocolFailure
        }
        let config = try ConfigFile().loadSnapshot()
        let result = await CleanupService(config: config.cleanup).clean(raw)
        let output: [String: Any] = [
            "text": result.text, "rawFallback": result.usedFallback,
            "endpoint": result.endpoint ?? "",
        ]
        try FileHandle.standardOutput.write(
            contentsOf: JSONSerialization.data(withJSONObject: output))
    }
}

private final class LinuxWorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    func write(_ data: Data) -> Bool {
        lock.withLock {
            guard !closed else { return true }
            do {
                try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                return true
            } catch {
                closed = true
                return false
            }
        }
    }
}
#endif
