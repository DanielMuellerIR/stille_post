#if os(Linux)
import Foundation

struct LinuxWorkerRequest: Decodable {
    enum Command: String {
        case application, start, holdStart, holdEnd, holdInterrupted, recall, completePreview
        case profile, privateHistory, startTest, stopTest, cancelTest, closeTest, testReport
        case stop, toggle, pause, resume, cancel, captureError, samples, reviewImport, reviewTest
        case cancelImport, closeImport, importAudio = "import", history, deleteHistory
        case sileroStatus, config, saveConfig, quit
        case cancelOperation, cancelSelection, discardRecleanup, clearLastResult, difference
    }

    enum Operation: String {
        case editHistory, retryHistory, recleanHistory, acceptRecleanup, addVocabulary
        case deleteAllHistory, applyRetention, diagnostics, checkEndpoint, installModel
        case cleanupSelection, setCleanupKey, bridgePair, bridgeRenewIdentity, bridgeRotateToken
        case installSilero
    }

    private enum CodingKeys: String, CodingKey {
        case command, accepted, accessibility, after, application, before, candidate, config, data
        case enabled, endpoint, entryID, expected, id, inputAvailable, key, keyboard, microphone
        case model, offset, path, period, queryId, reviewed, status, term, text, variant, version
        case vocabularyProfileID
    }

    let command: Command?
    let operation: Operation?
    let accepted: Bool?
    let accessibility: Bool?
    let after: String?
    let application: String?
    let before: String?
    let candidate: String?
    let data: String?
    let enabled: Bool?
    let entryID: String?
    let id: String?
    let inputAvailable: Bool?
    let key: String?
    let keyboard: Bool?
    let microphone: Bool?
    let model: String?
    let offset: Int?
    let path: String?
    let period: String?
    let queryId: Int?
    let status: String?
    let term: String?
    let text: String?
    let variant: String?
    let version: String?
    let vocabularyProfileID: String?
    let config: Result<Config, Error>?
    let reviewed: Result<Config, Error>?
    let expectedConfig: Result<Config, Error>?
    let expectedEntry: Result<HistoryStore.Entry, Error>?
    let endpoint: Result<Config.Cleanup.Endpoint, Error>?

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys) -> Value? {
            try? fields.decodeIfPresent(Value.self, forKey: key)
        }
        // Fachlich ungültige Konfigurationen oder Verlaufseinträge sollen den
        // Auftrag fehlschlagen lassen. Das nächste gültige Frame bleibt lesbar.
        func payload<Value: Decodable>(_ key: CodingKeys) -> Result<Value, Error>? {
            guard fields.contains(key) else { return nil }
            return Result { try fields.decode(Value.self, forKey: key) }
        }

        let name: String? = read(.command)
        command = name.flatMap(Command.init(rawValue:))
        operation = name.flatMap(Operation.init(rawValue:))
        accepted = read(.accepted)
        accessibility = read(.accessibility)
        after = read(.after)
        application = read(.application)
        before = read(.before)
        candidate = read(.candidate)
        data = read(.data)
        enabled = read(.enabled)
        entryID = read(.entryID)
        id = read(.id)
        inputAvailable = read(.inputAvailable)
        key = read(.key)
        keyboard = read(.keyboard)
        microphone = read(.microphone)
        model = read(.model)
        offset = read(.offset)
        path = read(.path)
        period = read(.period)
        queryId = read(.queryId)
        status = read(.status)
        term = read(.term)
        text = read(.text)
        variant = read(.variant)
        version = read(.version)
        vocabularyProfileID = read(.vocabularyProfileID)
        config = command == .saveConfig ? payload(.config) : nil
        reviewed = command == .startTest || command == .importAudio ? payload(.reviewed) : nil
        expectedConfig = command == .saveConfig ? payload(.expected) : nil
        switch operation {
        case .editHistory, .retryHistory, .recleanHistory, .addVocabulary:
            expectedEntry = payload(.expected)
        default:
            expectedEntry = nil
        }
        endpoint = operation == .checkEndpoint ? payload(.endpoint) : nil
    }

    func historyEntry() throws -> HistoryStore.Entry {
        guard let expectedEntry else { throw LinuxFailure.protocolFailure }
        return try expectedEntry.get()
    }
}

struct LinuxWorkerHistoryEntry: Encodable {
    let entry: HistoryStore.Entry

    private enum CodingKeys: String, CodingKey {
        case canRetry, canEdit, `private`, diagnostic
    }

    func encode(to encoder: Encoder) throws {
        try entry.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(entry.canRetry, forKey: .canRetry)
        try fields.encode(entry.canEdit, forKey: .canEdit)
        try fields.encode(entry.isTextPrivate, forKey: .private)
        try fields.encode(entry.diagnosticMessage ?? "", forKey: .diagnostic)
    }
}

enum LinuxWorkerEvent {
    struct BridgePairing: Encodable {
        let event = "bridgePairing"
        let pairing: LinuxBridgePairing
    }

    struct History: Encodable {
        let event = "history"
        let entries: [LinuxWorkerHistoryEntry]
        let total: Int
        let queryId: Int
    }

    struct HistorySaved: Encodable {
        let event = "historySaved"
        let entry: LinuxWorkerHistoryEntry
    }

    struct Configuration: Encodable {
        let event = "config"
        let config: Config
        let vocabularyProfileID: String
        let vocabularyLabel: String
    }

    struct Review: Encodable {
        let event: String
        let configuration: Config
        let profile: String
        let language: String
        let reason: String
        let history: Config.History
        let localOnly: Bool
        let cleanupEnabled: Bool
    }

    struct Result: Encodable {
        let event: String
        let text: String
        let rawFallback: Bool
        let localFallback: Bool
        let preview: Bool
        let failed: Bool
        let origin: String
        let note: String
        let candidate: UUID?
        let entry: LinuxWorkerHistoryEntry?
        let timings: [String: Double]
    }
}
#endif
