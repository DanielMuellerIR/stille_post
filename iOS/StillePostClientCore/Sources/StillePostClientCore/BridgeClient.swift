import Foundation

public struct HTTPReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol BridgeTransport: Sendable {
    func perform(_ request: URLRequest, file: URL?, fingerprint: String?,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPReply
}

public protocol BridgeAccess: Sendable {
    func health(_ credentials: BridgeCredentials) async throws -> BridgeHealth
    func dictate(_ recording: Recording, credentials: BridgeCredentials,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> DictationReply
    func cleanup(_ text: String, credentials: BridgeCredentials) async throws -> DictationReply
}

public extension BridgeAccess {
    func cleanup(_ text: String, credentials: BridgeCredentials) async throws -> DictationReply { throw ClientFailure.unavailable }
}

public struct BridgeClient: BridgeAccess {
    public static let maxAudioBytes = 5_000_000
    public static let maxResponseBytes = 1_048_576
    public static let maxTextBytes = 65_536
    public static let maxRecordingSeconds: TimeInterval = 180
    private let transport: any BridgeTransport

    public init(transport: any BridgeTransport = LocalHTTPTransport()) { self.transport = transport }

    public func health(_ credentials: BridgeCredentials) async throws -> BridgeHealth {
        let request = try request(credentials, route: "health", method: "GET", timeout: 10)
        let reply: BridgeHealth = try await decode { try await transport.perform(request, file: nil, fingerprint: credentials.configuration.fingerprint, progress: { _ in }) }
        guard reply.ok else { throw ClientFailure.invalidResponse }
        return reply
    }

    public func dictate(_ recording: Recording, credentials: BridgeCredentials,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> DictationReply {
        let attributes = try FileManager.default.attributesOfItem(atPath: recording.url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0, recording.duration > 0 else { throw ClientFailure.noAudio }
        guard bytes.intValue <= Self.maxAudioBytes, recording.duration <= Self.maxRecordingSeconds + 1 else {
            throw ClientFailure.recordingTooLarge
        }
        var request = try request(credentials, route: "dictate", method: "POST", timeout: 180)
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(bytes.intValue), forHTTPHeaderField: "Content-Length")
        return try await decode { try await transport.perform(request, file: recording.url, fingerprint: credentials.configuration.fingerprint, progress: progress) }
    }

    public func cleanup(_ text: String, credentials: BridgeCredentials) async throws -> DictationReply {
        let data = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure.noSpeech }
        guard data.count <= Self.maxTextBytes else { throw ClientFailure.textTooLarge }
        var request = try request(credentials, route: "cleanup", method: "POST", timeout: 180)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        return try await decode { try await transport.perform(request, file: nil,
            fingerprint: credentials.configuration.fingerprint, progress: { _ in }) }
    }

    private func request(_ credentials: BridgeCredentials, route: String, method: String,
                         timeout: TimeInterval) throws -> URLRequest {
        let token = credentials.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
            throw ClientFailure.missingToken
        }
        let url = try credentials.configuration.endpoint().appendingPathComponent("v1/\(route)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.allowsCellularAccess = false
        return request
    }

    private func decode<T: Decodable>(_ operation: () async throws -> HTTPReply) async throws -> T {
        let response: HTTPReply
        do { response = try await operation() }
        catch is CancellationError { throw CancellationError() }
        catch let error as ClientFailure { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ClientFailure.unavailable }
        guard response.body.count <= Self.maxResponseBytes else { throw ClientFailure.responseTooLarge }
        switch response.status {
        case 200: break
        case 300..<400: throw ClientFailure.redirected
        case 401, 403: throw ClientFailure.unauthorized
        case 413: throw ClientFailure.recordingTooLarge
        case 503: throw ClientFailure.busy
        default: throw ClientFailure.serverFailed
        }
        do { return try JSONDecoder().decode(T.self, from: response.body) }
        catch { throw ClientFailure.invalidResponse }
    }
}
