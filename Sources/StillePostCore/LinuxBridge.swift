#if os(Linux)
import Foundation
import Glibc
import LinuxNative

struct LinuxBridgeIdentity: Codable {
    var certificate: String
    var privateKey: String
    static let service = "io.github.danielmuellerir.stillepost.bridge.tls.v1"
    static func loadOrCreate() throws -> Self {
        if let stored = try LinuxSecretStore.loadChecked(service: service) {
            let value = try JSONDecoder().decode(Self.self, from: Data(stored.utf8))
            guard let context = value.context() else { throw LinuxFailure.secret }
            sp_tls_context_free(context)
            return value
        }
        var certificate: UnsafeMutablePointer<CChar>?
        var key: UnsafeMutablePointer<CChar>?
        guard sp_identity_create(&certificate, &key) == 1, let certificate, let key else {
            throw LinuxFailure.secret
        }
        defer {
            sp_free(certificate)
            sp_free(key)
        }
        let value = Self(
            certificate: String(cString: certificate), privateKey: String(cString: key))
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw LinuxFailure.secret }
        try LinuxSecretStore.store(text, service: service)
        return value
    }
    func context() -> OpaquePointer? {
        certificate.withCString { cert in privateKey.withCString { sp_tls_context_new(cert, $0) } }
    }
    static func renew() throws -> Self {
        guard let text = try LinuxSecretStore.loadChecked(service: service) else {
            throw LinuxFailure.secret
        }
        var value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        var renewed: UnsafeMutablePointer<CChar>?
        guard
            value.certificate.withCString({ cert in
                value.privateKey.withCString { sp_identity_renew(cert, $0, &renewed) }
            }) == 1, let renewed
        else { throw LinuxFailure.secret }
        defer { sp_free(renewed) }
        value.certificate = String(cString: renewed)
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw LinuxFailure.secret }
        try LinuxSecretStore.store(text, service: service)
        return value
    }
    var fingerprint: String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard certificate.withCString({ sp_certificate_fingerprint($0, &bytes) }) == 1 else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension BridgeToken {
    static func rotate() throws -> String {
        if let token = ProcessInfo.processInfo.environment["STILLEPOST_BRIDGE_TOKEN"], !token.isEmpty {
            throw LinuxFailure.environmentToken
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard sp_random(&bytes, bytes.count) == 1 else { throw LinuxFailure.secret }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try LinuxSecretStore.store(token, service: keychainService)
        return token
    }
    static func createIfMissing() throws -> String {
        switch loadOutcome() {
        case .token(let token): return token
        case .failed: throw LinuxFailure.secret
        case .missing:
            var bytes = [UInt8](repeating: 0, count: 32)
            guard sp_random(&bytes, bytes.count) == 1 else { throw LinuxFailure.secret }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            try LinuxSecretStore.store(token, service: keychainService)
            return token
        }
    }
}

/// Empfangsadapter; Routing, Tokenvergleich, Netzgrenze und serielle Pipeline
/// bleiben im gemeinsamen Kern. Sämtliche Socket-/TLS-Zustände gehören queue.
final class LinuxBridgeService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stillepost.linux-bridge")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let identityProvider: @Sendable () throws -> LinuxBridgeIdentity
    private let tokenProvider: @Sendable () -> String?
    private let handlersProvider: @Sendable (Config) -> BridgeHandlers
    private var listener: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var context: OpaquePointer?
    private var sessions: [UUID: Session] = [:]
    private var bufferedBytes = 0
    private var maxBody = 25 * 1024 * 1024
    private var router: BridgeRouter?
    private var handlers: BridgeHandlers?
    private var options: Config.Bridge?
    var onStatus: (@Sendable (Bool, String) -> Void)?
    init(
        identityProvider: @escaping @Sendable () throws -> LinuxBridgeIdentity = {
            try LinuxBridgeIdentity.loadOrCreate()
        },
        tokenProvider: @escaping @Sendable () -> String? = { BridgeToken.load() },
        handlersProvider: @escaping @Sendable (Config) -> BridgeHandlers = {
            BridgeHandlers.live(config: $0, version: LinuxBridgeService.version)
        }
    ) {
        self.identityProvider = identityProvider
        self.tokenProvider = tokenProvider
        self.handlersProvider = handlersProvider
        queue.setSpecific(key: queueKey, value: true)
    }
    private final class Session {
        let id = UUID(), fd: Int32, tls: OpaquePointer
        var phase = 0, data = Data(), response = Data(), written = 0, reservation = 0
        var deadline = ProcessInfo.processInfo.systemUptime + 30
        var timer: DispatchSourceTimer?
        var task: Task<Void, Never>?
        init(fd: Int32, tls: OpaquePointer) {
            self.fd = fd
            self.tls = tls
        }
    }
    func configure(_ config: Config, forceRestart: Bool = false) {
        queue.async { [self] in
            if !forceRestart, listener != nil, options == config.bridge {
                handlers?.updateConfiguration?(config)
                return
            }
            stopOnQueue()
            guard config.bridge.enabled else {
                onStatus?(false, L10n.text("linux.bridge.disabled"))
                return
            }
            do {
                guard let token = tokenProvider(), !token.isEmpty,
                    (1...65535).contains(config.bridge.port),
                    (1...100).contains(config.bridge.maxRequestMegabytes)
                else { throw LinuxFailure.secret }
                let identity = try identityProvider()
                guard let ctx = identity.context() else { throw LinuxFailure.secret }
                context = ctx
                maxBody = config.bridge.maxRequestMegabytes * 1024 * 1024
                let live = handlersProvider(config)
                handlers = live
                router = BridgeRouter(
                    handlers: live, maxBodyBytes: maxBody, tokenProvider: { token })
                let fd = Glibc.socket(AF_INET6, Int32(SOCK_STREAM.rawValue), 0)
                guard fd >= 0 else { throw LinuxFailure.protocolFailure }
                socketFD = fd
                var one: Int32 = 1
                var zero: Int32 = 0
                _ = setsockopt(
                    fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                _ = setsockopt(
                    fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size)
                )
                var address = sockaddr_in6()
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = UInt16(config.bridge.port).bigEndian
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                guard bound == 0, listen(fd, 8) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                    throw LinuxFailure.protocolFailure
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptConnections() }
                listener = source
                source.resume()
                options = config.bridge
                onStatus?(true, L10n.text("linux.bridge.ready"))
            } catch {
                stopOnQueue()
                onStatus?(
                    false,
                    L10n.text("linux.bridge.failed")
                )
            }
        }
    }
    func updateConfiguration(_ config: Config) { configure(config) }
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }
    deinit { stop() }
    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        if socketFD >= 0 {
            _ = Glibc.close(socketFD)
            socketFD = -1
        }
        for session in Array(sessions.values) { finish(session) }
        if let context { sp_tls_context_free(context) }
        context = nil
        router = nil
        handlers = nil
        options = nil
        bufferedBytes = 0
    }
    private func acceptConnections() {
        guard socketFD >= 0, let context else { return }
        for _ in 0..<16 {
            var address = sockaddr_storage()
            var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let fd = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Glibc.accept(socketFD, $0, &size)
                }
            }
            if fd < 0 { break }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let named = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard sessions.count < 8, named == 0, BridgePeer.isLocalNetwork(String(cString: host)),
                fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                let tls = sp_tls_connection_new(context, fd)
            else {
                _ = Glibc.close(fd)
                continue
            }
            let session = Session(fd: fd, tls: tls)
            sessions[session.id] = session
            let timer = DispatchSource.makeTimerSource(queue: queue)
            session.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self, weak session] in
                if let self, let session { self.advance(session) }
            }
            timer.resume()
        }
    }
    private func advance(_ session: Session) {
        guard sessions[session.id] != nil else { return }
        if ProcessInfo.processInfo.systemUptime > session.deadline {
            finish(session)
            return
        }
        if session.phase == 0 {
            let status = sp_tls_accept(session.tls)
            if status == 1 { session.phase = 1 } else if status == -1 { finish(session) }
            return
        }
        if session.phase == 3 {
            let remaining = session.response.count - session.written
            let count = session.response.withUnsafeBytes { raw in
                sp_tls_write(
                    session.tls, raw.baseAddress!.advanced(by: session.written),
                    Int32(min(remaining, 65536)))
            }
            if count > 0 {
                session.written += Int(count)
                if session.written == session.response.count { finish(session) }
            } else if count == -1 {
                finish(session)
            }
            return
        }
        var bytes = [UInt8](repeating: 0, count: session.phase == 2 ? 1 : 16384)
        let count = sp_tls_read(session.tls, &bytes, Int32(bytes.count))
        if count == -1 {
            finish(session)
            return
        }
        guard count > 0 else { return }
        if session.phase == 2 {
            finish(session)
            return
        }
        let added = Int(count)
        guard
            bufferedBytes + added <= maxBody * BridgeRouter.maxPipelineDepth + 8
                * (BridgeHTTP.maxHeaderBytes + 4),
            session.reservation + added <= maxBody + BridgeHTTP.maxHeaderBytes + 4
        else {
            respond(.error(status: 413, message: "Anfrage ist zu groß."), session)
            return
        }
        bufferedBytes += added
        session.reservation += added
        session.data.append(contentsOf: bytes.prefix(added))
        if case .complete(_, _, let token) = BridgeHTTP.probeHeader(session.data),
            router?.isAuthorized(bearerToken: token) != true
        {
            respond(.error(status: 401, message: "Nicht autorisiert."), session)
            return
        }
        switch BridgeHTTP.parse(session.data, maxBodyBytes: maxBody) {
        case .incomplete: return
        case .failure(let response): respond(response, session)
        case .complete(let request):
            guard let router else {
                finish(session)
                return
            }
            session.data.removeAll(keepingCapacity: false)
            session.phase = 2
            session.deadline = ProcessInfo.processInfo.systemUptime + 1800
            session.task = Task { [weak self, weak session] in
                let response = await router.respond(to: request)
                guard let self, let session else { return }
                self.queue.async { [weak self, weak session] in
                    guard let self, let session, self.sessions[session.id] != nil else { return }
                    self.respond(response, session)
                }
            }
        }
    }
    private func respond(_ response: BridgeResponse, _ session: Session) {
        session.data.removeAll(keepingCapacity: false)
        session.response = response.httpData()
        session.written = 0
        session.phase = 3
        session.deadline = ProcessInfo.processInfo.systemUptime + 10
    }
    private func finish(_ session: Session) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        session.timer?.cancel()
        session.timer = nil
        session.task?.cancel()
        session.task = nil
        bufferedBytes -= session.reservation
        session.reservation = 0
        sp_tls_connection_free(session.tls)
        _ = Glibc.close(session.fd)
    }
    static var version: String {
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VERSION")
        return
            (try? String(contentsOf: path, encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines)) ?? "development"
    }
    static func pairing(port: Int) throws -> [String: Any] {
        let token = try BridgeToken.createIfMissing()
        let identity = try LinuxBridgeIdentity.loadOrCreate()
        guard let pin = identity.fingerprint else { throw LinuxFailure.secret }
        var bytes = [CChar](repeating: 0, count: 256)
        guard gethostname(&bytes, bytes.count - 1) == 0 else { throw LinuxFailure.protocolFailure }
        let name = String(cString: bytes).split(separator: ".").first.map(String.init) ?? "linux"
        return ["v": 1, "url": "https://\(name).local:\(port)", "pin": pin, "token": token]
    }
}
#endif
