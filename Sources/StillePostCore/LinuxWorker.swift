#if os(Linux)
import Foundation
import Glibc

/// Privates, begrenztes JSONL-Protokoll zwischen GUI und unverändertem Diktierkern.
/// Audio wird in kleinen Float32-Blöcken über dieselbe vererbte Pipe übertragen.
public final class LinuxWorker {
    private static let maximumMessageBytes = 4 * 1024 * 1024
    private var config: Config
    private var engine: DictationEngine
    private let lock = NSLock()
    private var outputClosed = false
    private let ollama = LinuxOllamaService()
    private let bridge = LinuxBridgeService()
    private var bridgeReady = false
    private var pendingPreviews: [UUID: TransientResultStore.Result] = [:]
    private var pendingMessages = 0
    private let flow = NSCondition()
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
            self.testSession?.pulse()
            if let started = self.holdStarted, self.holdActive,
                ProcessInfo.processInfo.systemUptime - started >= DictationHotkeyState.maximumHoldDuration {
                self.handleHold(.deadline)
            }
            if ProcessInfo.processInfo.systemUptime >= self.nextMaintenance {
                self.nextMaintenance = ProcessInfo.processInfo.systemUptime + 60
                self.maintainHistory()
            }
            self.send([
                "event": "meter", "levelDb": self.engine.currentLevelDb,
                "duration": self.engine.recordingDuration,
            ])
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
                        guard line.count <= Self.maximumMessageBytes,
                            let message = try JSONSerialization.jsonObject(with: line)
                                as? [String: Any]
                        else { throw LinuxFailure.protocolFailure }
                        flow.lock()
                        while pendingMessages >= 8 { flow.wait() }
                        pendingMessages += 1
                        flow.unlock()
                        DispatchQueue.main.async { [self] in
                            handle(message)
                            flow.lock()
                            pendingMessages -= 1
                            flow.signal()
                            flow.unlock()
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
        dispatchMain()
    }
    private func send(_ message: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
            data.count < Self.maximumMessageBytes
        else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !outputClosed else { return }
        do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
        catch {
            outputClosed = true
            DispatchQueue.main.async { [weak self] in self?.requestShutdown() }
        }
    }
    private func handle(_ message: [String: Any]) {
        guard shutdownTask == nil, let command = message["command"] as? String else { return }
        switch command {
        case "application":
            guard let id = message["id"] as? String, id.utf8.count <= 128, id.hasPrefix("linux."),
                id != activeApplication
            else { return }
            activeApplication = id
            sendConfiguration()
        case "start":
            guard operation == nil else {
                send(["event": "error", "message": L10n.text("selection.error.busy")])
                return
            }
            prepareRegular(message)
            engine.start()
        case "holdStart":
            guard operation == nil else {
                send(["event": "error", "message": L10n.text("selection.error.busy")])
                return
            }
            guard holdState.handle(.pressed, mode: .hold, state: engine.state) == .start else { return }
            prepareRegular(message)
            holdActive = true
            holdStarted = ProcessInfo.processInfo.systemUptime
            engine.start(onlyWhile: { [weak self] in self?.holdActive == true })
        case "holdEnd": handleHold(.released)
        case "holdInterrupted": handleHold(.interrupted)
        case "recall":
            if let value = lastResult.last {
                send(["event": "recall", "text": value.text, "rawFallback": value.rawFallback, "note": value.note ?? "", "origin": value.origin.rawValue])
            } else {
                send(["event": "notice", "message": L10n.text("result.none")])
            }
        case "completePreview":
            guard let id = (message["candidate"] as? String).flatMap(UUID.init),
                let value = pendingPreviews.removeValue(forKey: id) else { return }
            if message["accepted"] as? Bool == true { remember(value) }
            send(["event":"previewCompleted", "candidate":id.uuidString])
        case "profile":
            guard !engine.hasInFlightRequests else { return }
            do {
                config = try ConfigFile().selectProfile(
                    (message["id"] as? String).flatMap(UUID.init))
                engine.configure(requestConfiguration)
                bridge.updateConfiguration(requestConfiguration)
                sendConfiguration()
            } catch { failure(error) }
        case "privateHistory":
            guard config.resolvedForRequest().history.storeText else { return }
            temporaryPrivateHistory = message["enabled"] as? Bool ?? !temporaryPrivateHistory
            engine.suppressTranscriptPreview()
            engine.configure(requestConfiguration)
            bridge.updateConfiguration(requestConfiguration)
            sendHistoryPolicy()
        case "startTest":
            guard operation == nil, !engine.hasInFlightRequests, pendingPreviews.isEmpty else {
                send(["event": "testStatus", "state": "failed", "active": false,
                      "message": L10n.text("test_dictation.failed"), "error": L10n.text("selection.error.busy")])
                return
            }
            do {
                let reviewed: Config
                if let value = message["reviewed"] {
                    reviewed = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: value))
                } else { reviewed = requestConfiguration }
                _ = importSession?.releaseForRegularStart()
                importSession = nil
                testSession = TestDictationSession(engine: engine)
                testSession?.onChange = { [weak self] in self?.sendTestStatus() }
                testSession?.start(
                    configuration: reviewed, currentConfiguration: requestConfiguration,
                    nextRequestConfiguration: requestConfiguration,
                    inputAvailable: message["inputAvailable"] as? Bool ?? true, allowed: true)
            } catch { failure(error) }
        case "stopTest": testSession?.stop()
        case "cancelTest": testSession?.cancel()
        case "closeTest":
            _ = testSession?.close()
            testSession = nil
        case "testReport":
            send([
                "event": "testReport",
                "text": testSession?.exportReport(
                    version: message["version"] as? String ?? "unknown")
                    ?? "",
            ])
        case "stop": engine.stop()
        case "toggle":
            guard operation == nil else {
                send(["event": "error", "message": L10n.text("selection.error.busy")])
                return
            }
            switch engine.state {
            case .idle, .error: prepareRegular(message)
            default: break
            }
            engine.toggle()
        case "pause": engine.pause()
        case "resume": engine.resume()
        case "cancel": engine.cancel()
        case "captureError": AudioRecorder.active?.onFailure?(LinuxFailure.capture)
        case "samples":
            guard let encoded = message["data"] as? String, let data = Data(base64Encoded: encoded),
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
        case "reviewImport", "reviewTest":
            if command == "reviewTest" { testSession?.reset() }
            else { importSession?.reset() }
            do {
                let resolved = requestConfiguration.resolvedForRequest()
                send([
                    "event": command == "reviewImport" ? "importReview" : "testReview",
                    "configuration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(requestConfiguration)),
                    "profile": resolved.profileLabel, "language": resolved.whisper.language,
                    "reason": resolved.requestProfileSelection?.label ?? "",
                    "history": try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved.history)),
                    "localOnly": resolved.cleanup.localOnly, "cleanupEnabled": resolved.cleanup.enabled,
                ])
            } catch { failure(error) }
        case "cancelImport": importSession?.cancel()
        case "closeImport": importSession?.close()
        case "import":
            guard operation == nil, let path = message["path"] as? String, path.hasPrefix("/"),
                !engine.hasInFlightRequests, pendingPreviews.isEmpty
            else {
                send(["event": "importStatus", "active": false, "finished": true,
                      "message": L10n.text("audio_import.failed"), "error": L10n.text("selection.error.busy")])
                return
            }
            do {
                let reviewed: Config
                if let value = message["reviewed"] {
                    reviewed = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: value))
                } else {
                    reviewed = requestConfiguration
                }
                _ = testSession?.releaseForRegularStart()
                importSession = AudioImportSession(engine: engine)
                importSession?.onChange = { [weak self] in self?.sendImportStatus() }
                importSession?.start(
                    file: URL(fileURLWithPath: path), configuration: reviewed,
                    currentConfiguration: requestConfiguration,
                    nextRequestConfiguration: requestConfiguration, allowed: true)
            } catch { failure(error) }
        case "history":
            Task { [self] in
                do {
                    let entries = try await engine.history.listAsync()
                    var query = HistoryQuery()
                    query.text = message["text"] as? String ?? ""
                    query.status =
                        HistoryQuery.Status(rawValue: message["status"] as? String ?? "all") ?? .all
                    query.period =
                        HistoryQuery.Period(rawValue: message["period"] as? String ?? "all") ?? .all
                    let filtered = query.filter(entries)
                    let offset = max(0, message["offset"] as? Int ?? 0)
                    let page = Array(filtered.dropFirst(offset).prefix(100))
                    send([
                        "event": "history", "entries": try page.map(entryObject),
                        "total": filtered.count,
                        "queryId": message["queryId"] as? Int ?? 0,
                    ])
                } catch { failure(error) }
            }
        case "editHistory", "retryHistory", "recleanHistory", "acceptRecleanup", "addVocabulary",
            "deleteAllHistory", "applyRetention", "difference", "diagnostics", "checkEndpoint",
            "installModel", "cancelOperation", "cleanupSelection", "cancelSelection",
            "setCleanupKey",
            "clearLastResult", "discardRecleanup", "bridgePair", "bridgeRenewIdentity",
            "bridgeRotateToken", "installSilero":
            handleExtended(command, message)
        case "deleteHistory":
            guard let value = message["id"] as? String, let id = UUID(uuidString: value) else {
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
        case "sileroStatus":
            Task { @MainActor [self] in
                let reason = await SileroModel.availability()
                send([
                    "event": "sileroStatus", "ready": reason == nil,
                    "message": reason ?? L10n.text("vad.ready"),
                ])
            }
        case "config":
            sendConfiguration()
        case "saveConfig":
            guard let object = message["config"],
                let data = try? JSONSerialization.data(withJSONObject: object)
            else { return }
            do {
                let replacement = try JSONDecoder().decode(Config.self, from: data)
                _ = try WhisperEndpoint(serverURL: replacement.whisper.serverURL)
                let expected: Config
                if let value = message["expected"] {
                    expected = try JSONDecoder().decode(
                        Config.self, from: JSONSerialization.data(withJSONObject: value))
                } else {
                    expected = config
                }
                try replacement.save(expected: expected)
                config = replacement
                engine.configure(requestConfiguration)
                bridge.updateConfiguration(requestConfiguration)
                sendConfiguration()
                send(["event": "configSaved"])
            } catch {
                send([
                    "event": "error", "message": L10n.text("linux.config.save_failed"),
                ])
            }
        case "quit": requestShutdown()
        default: break
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
    private func prepareRegular(_ message: [String: Any]) {
        _ = testSession?.releaseForRegularStart()
        _ = importSession?.releaseForRegularStart()
        importSession = nil
        activeApplication = message["application"] as? String
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
        do {
            let data = try JSONEncoder().encode(config)
            let resolved = config.resolvedForRequest(appBundleID: activeApplication)
            send([
                "event": "config", "config": try JSONSerialization.jsonObject(with: data),
                "vocabularyProfileID": resolved.vocabularyProfileID?.uuidString ?? "",
                "vocabularyLabel": resolved.vocabularyProfileID == nil
                    ? L10n.text("profiles.global") : resolved.profileLabel,
            ])
            sendHistoryPolicy()
        } catch { failure(error) }
    }
    private var requestConfiguration: Config {
        var result = config
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
    private func entryObject(_ entry: HistoryStore.Entry) throws -> [String: Any] {
        var result =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        result["canRetry"] = entry.canRetry
        result["canEdit"] = entry.canEdit
        result["private"] = entry.isTextPrivate
        result["diagnostic"] = entry.diagnosticMessage ?? ""
        return result
    }
    private func expectedEntry(_ message: [String: Any]) throws -> HistoryStore.Entry {
        guard let value = message["expected"] else { throw LinuxFailure.protocolFailure }
        return try JSONDecoder().decode(
            HistoryStore.Entry.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func remember(_ result: TransientResultStore.Result) {
        lastResult.accept(text: result.text, rawFallback: result.rawFallback,
                          note: result.note, origin: result.origin)
    }
    private func sendResult(_ result: DictationResult, kind: String = "result", candidate: UUID? = nil) {
        var object: [String: Any] = [
            "event": kind, "text": result.text,
            "rawFallback": result.entry?.cleanupFellBack ?? false,
            "localFallback": result.entry?.cleanupEndpoint?.contains("127.0.0.1") ?? false,
            "preview": candidate != nil,
            "failed": result.entry?.isFailed == true,
            "origin": result.entry?.resultOrigin.rawValue ?? "raw",
            "note": result.entry?.cleanupFallbackReason ?? "",
        ]
        if let candidate { object["candidate"] = candidate.uuidString }
        if let entry = result.entry { object["entry"] = try? entryObject(entry) }
        let times = engine.phaseTimings
        let phases: [String: Double] = [
            "preparation": times.preparationSec ?? 0, "recording": times.recordingSec ?? 0,
            "transcription": times.transcriptionSec, "cleanup": times.cleanupSec ?? 0,
            "segments": Double(times.transcriptionCount),
        ]
        object["timings"] = phases
        send(object)
    }
    private func handleExtended(_ command: String, _ message: [String: Any]) {
        if command == "cancelOperation" || command == "cancelSelection" {
            operation?.cancel()
            return
        }
        if command == "discardRecleanup" {
            if let id = (message["candidate"] as? String).flatMap(UUID.init) {
                recleanCandidates.removeValue(forKey: id)
            }
            return
        }
        if command == "clearLastResult" {
            lastResult = TransientResultStore()
            return
        }
        if command == "difference" {
            do {
                let result = try TextDifference.compare(
                    message["before"] as? String ?? "", message["after"] as? String ?? "")
                send([
                    "event": "difference", "entryID": message["entryID"] as? String ?? "",
                    "summarized": result.isSummarized,
                    "segments": result.segments.map {
                        ["kind": String(describing: $0.kind), "text": $0.text]
                    },
                ])
            } catch { failure(error) }
            return
        }
        guard operation == nil, !engine.hasInFlightRequests else {
            send(["event": "error", "message": L10n.text("selection.error.busy")])
            return
        }
        operation = Task { @MainActor [self] in
            send(["event": "operation", "active": true, "kind": command])
            defer {
                operation = nil
                send(["event": "operation", "active": false, "kind": command])
            }
            do {
                switch command {
                case "installSilero":
                    try await SileroModel.install()
                    send(["event": "sileroInstalled"])
                case "bridgeRenewIdentity", "bridgeRotateToken":
                    try await Task.detached {
                        if command == "bridgeRenewIdentity" {
                            _ = try LinuxBridgeIdentity.renew()
                        } else {
                            _ = try BridgeToken.rotate()
                        }
                    }.value
                    bridge.configure(requestConfiguration, forceRestart: true)
                    send(["event": "bridgeCredentialsChanged"])
                case "bridgePair":
                    let value = try await Task.detached { [config] in
                        try LinuxBridgeService.pairing(port: config.bridge.port)
                    }.value
                    send(["event": "bridgePairing", "pairing": value])
                    bridge.configure(requestConfiguration)
                case "editHistory":
                    let entry = try await engine.history.saveCorrectionAsync(
                        message["text"] as? String ?? "", expected: expectedEntry(message))
                    send(["event": "historySaved", "entry": try entryObject(entry)])
                case "retryHistory":
                    let expected = try expectedEntry(message)
                    guard
                        let current = try await engine.history.listAsync().first(where: {
                            $0.id == expected.id
                        }), current == expected, current.canRetry
                    else { throw HistoryStore.PersistenceError.correctionConflict }
                    let entry = try await engine.retry(entry: expected)
                    send(["event": "historySaved", "entry": try entryObject(entry)])
                case "recleanHistory":
                    let candidate = try await HistoryRecleanup.run(
                        expected: expectedEntry(message), history: engine.history,
                        appBundleID: activeApplication)
                    let id = UUID()
                    recleanCandidates.removeAll()
                    recleanCandidates[id] = candidate
                    send([
                        "event": "recleanupPreview", "candidate": id.uuidString,
                        "before": candidate.expected.cleanText, "text": candidate.result.text,
                    ])
                case "acceptRecleanup":
                    guard let id = (message["candidate"] as? String).flatMap(UUID.init),
                        let candidate = recleanCandidates.removeValue(forKey: id)
                    else { throw LinuxFailure.protocolFailure }
                    let entry = try await engine.history.saveRecleanupAsync(
                        candidate.result, durationSec: candidate.durationSec,
                        expected: candidate.expected)
                    send(["event": "historySaved", "entry": try entryObject(entry)])
                case "addVocabulary":
                    let expected = try expectedEntry(message)
                    let term = message["term"] as? String ?? ""
                    let variant = message["variant"] as? String
                    let profile: UUID?
                    if let reviewed = message["vocabularyProfileID"] as? String {
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
                case "deleteAllHistory":
                    try engine.history.deleteAll()
                    send(["event": "historyChanged"])
                case "applyRetention":
                    try await engine.history.applyRetentionAsync()
                    send(["event": "historyChanged"])
                case "diagnostics":
                    var context = DiagnosticContext()
                    context.microphone = .unknown
                    context.selectedInputAvailable = message["microphone"] as? Bool
                    context.accessibility = message["accessibility"] as? Bool
                    context.keyboardReadable = message["keyboard"] as? Bool
                    context.bridge = bridgeReady ? .running : .stopped
                    let report = try await DiagnosticsService().scan(
                        configuration: config.resolvedForRequest(appBundleID: activeApplication),
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
                            version: message["version"] as? String ?? "unknown"),
                    ])
                case "checkEndpoint":
                    let endpoint = try JSONDecoder().decode(
                        Config.Cleanup.Endpoint.self,
                        from: JSONSerialization.data(withJSONObject: message["endpoint"] ?? [:]))
                    let state = await CleanupService(config: config.cleanup).checkOllamaEndpoint(
                        endpoint)
                    send(["event": "endpointCheck", "state": String(describing: state)])
                case "installModel":
                    guard let name = message["model"] as? String,
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
                case "cleanupSelection":
                    let text = message["text"] as? String ?? ""
                    try TextSelectionSnapshot.validate(text)
                    let snapshot = config.resolvedForRequest(
                        appBundleID: message["application"] as? String)
                    let result = await CleanupService(config: snapshot.cleanup).clean(text)
                    try Task.checkCancellation()
                    send([
                        "event": "selectionPreview", "before": text, "text": result.text,
                        "rawFallback": result.usedFallback,
                    ])
                case "setCleanupKey":
                    guard let key = message["key"] as? String, key.utf8.count <= 8192 else {
                        throw LinuxFailure.protocolFailure
                    }
                    try CleanupService.storeRemoteAPIKey(key)
                    send(["event": "keyStored"])
                default: break
                }
            } catch { if !Task.isCancelled { failure(error) } }
        }
    }
    public static func cleanStandardInput() async throws {
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
#endif
