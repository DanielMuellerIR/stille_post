import Combine
import Foundation
import StillePostClientCore
import UIKit
import UniformTypeIdentifiers

@MainActor final class MobileModel: ObservableObject {
    enum ConnectionState: Equatable { case unchecked, checking, ready(String), failed(ClientFailure) }
    @Published private(set) var state: MobileState
    @Published private(set) var configuration: BridgeConfiguration
    @Published private(set) var hasToken = false
    @Published private(set) var connection: ConnectionState = .unchecked
    @Published private(set) var setupFailure: ClientFailure?
    @Published private(set) var pendingAction = false
    @Published var copied = false
    private let session: DictationSession
    private let bridge: any BridgeAccess
    private let keychain = BridgeKeychain()
    private var connectionTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var actionGeneration = UUID()
    private let configurationKey = "bridge.configuration"

    var busy: Bool { pendingAction || [.permission, .recording, .sending].contains(state.phase) }
    var canSend: Bool { !busy && state.recording != nil && state.reply == nil && hasToken && (try? configuration.endpoint()) != nil }

    init(capture: any AudioCapture, files: any RecordingFiles, bridge: any BridgeAccess = BridgeClient()) {
        self.bridge = bridge
        session = DictationSession(capture: capture, files: files, bridge: bridge)
        state = session.state
        configuration = UserDefaults.standard.data(forKey: configurationKey)
            .flatMap { try? JSONDecoder().decode(BridgeConfiguration.self, from: $0) } ?? BridgeConfiguration()
        session.onChange = { [weak self] state in self?.state = state; self?.copied = false }
    }

    func load() async {
        do {
            if let credentials = try await keychain.load() {
                configuration = credentials.configuration; hasToken = true
            }
        } catch { setupFailure = error as? ClientFailure ?? .storageFailed }
        #if DEBUG
        if ProcessInfo.processInfo.environment["STILLEPOST_MOBILE_IMPORT_TEST_CONNECTION"] == "1" {
            await importDevelopmentConnection()
        }
        #endif
    }

    func save(configuration: BridgeConfiguration, token: String) async -> Bool {
        guard !busy else { return false }
        connectionTask?.cancel()
        pendingAction = true; defer { pendingAction = false }
        do {
            _ = try configuration.endpoint()
            let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let stored = try? await keychain.load()
            let chosenToken = newToken.isEmpty ? stored?.token ?? "" : newToken
            guard !chosenToken.isEmpty, chosenToken.utf8.count <= 256,
                  chosenToken.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else { throw ClientFailure.missingToken }
            try await keychain.save(BridgeCredentials(configuration: configuration, token: chosenToken))
            hasToken = true
            UserDefaults.standard.removeObject(forKey: configurationKey)
            self.configuration = configuration; setupFailure = nil; connection = .unchecked
            return true
        } catch { setupFailure = error as? ClientFailure ?? .storageFailed; return false }
    }

    func forgetConnection() async {
        guard !busy else { return }
        connectionTask?.cancel(); pendingAction = true; defer { pendingAction = false }
        do {
            try await keychain.delete(); hasToken = false; configuration = BridgeConfiguration()
            UserDefaults.standard.removeObject(forKey: configurationKey)
            connection = .unchecked; setupFailure = nil
        } catch { setupFailure = .storageFailed }
    }

    func checkConnection() {
        guard !busy else { return }
        connectionTask?.cancel()
        connection = .checking
        let config = configuration
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await credentials(config)
                try Task.checkCancellation()
                let health = try await bridge.health(credentials)
                try Task.checkCancellation()
                connection = .ready(health.version)
            } catch is CancellationError { }
            catch { connection = .failed(error as? ClientFailure ?? .unavailable) }
        }
    }

    func record() { connectionTask?.cancel(); connection = .unchecked; setupFailure = nil; session.record() }
    func stop() { session.stop() }
    func cancel() { session.cancel() }
    func discard() { session.discard() }
    func interrupt() {
        connectionTask?.cancel(); actionTask?.cancel(); pendingAction = false
        actionGeneration = UUID()
        if connection == .checking { connection = .unchecked }
        session.interrupt()
    }

    func send() {
        guard canSend else { return }
        pendingAction = true
        actionGeneration = UUID(); let current = actionGeneration
        let config = configuration, recording = state.recording
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await credentials(config)
                try Task.checkCancellation()
                guard actionGeneration == current else { return }
                pendingAction = false
                guard state.recording == recording else { return }
                session.send(credentials: credentials)
            } catch is CancellationError { if actionGeneration == current { pendingAction = false } }
            catch {
                guard actionGeneration == current else { return }
                pendingAction = false; setupFailure = error as? ClientFailure ?? .storageFailed
            }
        }
    }

    func copyResult() {
        guard let text = state.reply?.text, !text.isEmpty else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copied = true
    }

    private func credentials(_ configuration: BridgeConfiguration) async throws -> BridgeCredentials {
        guard let credentials = try await keychain.load() else { throw ClientFailure.missingToken }
        guard credentials.configuration == configuration else { throw ClientFailure.pairingRequired }
        return credentials
    }

    #if DEBUG
    private func importDevelopmentConnection() async {
        struct Fixture: Decodable { let address: String; let token: String; let fingerprint: String }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("development-connection.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
              let data = try? Data(contentsOf: url), let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else { return }
        if await save(configuration: BridgeConfiguration(address: fixture.address, fingerprint: fixture.fingerprint), token: fixture.token) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    #endif
}
