import Foundation
import Network

/// Produktversion zur Anzeige. Im App-Bundle steht sie in der Info.plist; die
/// eingebettete CLI hat keine und meldet deshalb „dev“.
public enum AppVersion {
    public static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

/// Adresse, unter der die Brücke im Heimnetz erreichbar ist.
public enum BridgeAddress {
    /// Genau das, was auf dem iPhone in den Kurzbefehl gehört. Bewusst der
    /// `.local`-Name des Macs und nicht seine IP-Adresse: Der Name bleibt gleich,
    /// wenn der Router eine neue Adresse vergibt.
    ///
    /// `STILLEPOST_HOSTNAME` ist ein reproduzierbarer Testweg für Screenshots und
    /// Dokumentation — damit gerät kein echter Rechnername in öffentliche Bilder.
    public static func baseURL(port: Int) -> String {
        let host = ProcessInfo.processInfo.environment["STILLEPOST_HOSTNAME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.hostName
        return "http://\(host.isEmpty ? "mac.local" : host):\(port)"
    }
}

/// Nimmt Diktate von eigenen Geräten im Heimnetz an (iPhone-Kurzbefehl, `curl`).
///
/// Wichtig für das Verständnis der Datenschutzgrenze: Dieser Baustein ist reiner
/// EMPFÄNGER. Eingehendes Audio wird auf diesem Mac verarbeitet — die
/// Spracherkennung läuft weiter ausschließlich über den lokalen whisper-server,
/// dessen Loopback-Zwang unangetastet bleibt. Stille Post sendet selbst nie Audio
/// über das Netz.
///
/// Der Zugang hängt an einem Token aus dem Schlüsselbund. Ohne Token ist die
/// Brücke gesperrt, und ohne `bridge.enabled` lauscht überhaupt kein Port.
///
/// `@unchecked Sendable` ist hier belegbar und nicht bloß behauptet: Jeder
/// veränderliche Zustand (`listener`, `openConnections`, die Puffer der
/// Verbindungen) wird ausschließlich auf `queue` angefasst. Network.framework
/// ruft alle Handler auf genau dieser Queue auf; der einzige Sprung heraus ist
/// der `Task` in `handle`, und der kehrt vor jedem Zugriff wieder auf die Queue
/// zurück.
public final class BridgeServer: @unchecked Sendable {

    private let config: Config.Bridge
    private let router: BridgeRouter
    private let queue = DispatchQueue(label: "de.stillepost.bridge")
    private var listener: NWListener?
    /// Gleichzeitig offene Verbindungen. Mehr als eine Handvoll braucht ein
    /// Heimnetz nie; die Grenze verhindert, dass ein fehlerhafter Client den Mac
    /// mit halboffenen Verbindungen zusetzt.
    private var openConnections = 0
    private let maxOpenConnections = 8
    /// So lange darf eine Anfrage zum Übertragen brauchen. Die Verarbeitungszeit
    /// danach (Whisper, Bereinigung) zählt nicht mit.
    private let readTimeoutSeconds: TimeInterval = 30
    /// Frist, in der die Gegenseite die Antwort abholen und die Verbindung
    /// schließen darf, bevor die Brücke sie selbst abbricht.
    private let closeGraceSeconds: TimeInterval = 10

    /// Protokollzeilen für stderr oder die App. Enthalten nie Diktattext und nie
    /// das Token — nur Methode, Pfad, Status, Größe und Dauer.
    public var onLog: (@Sendable (String) -> Void)?

    public init(config: Config.Bridge, router: BridgeRouter) {
        self.config = config
        self.router = router
    }

    public convenience init(config: Config, version: String = AppVersion.current) {
        self.init(
            config: config.bridge,
            router: BridgeRouter(
                handlers: .live(config: config, version: version),
                maxBodyBytes: config.bridge.maxRequestMegabytes * 1_048_576
            )
        )
    }

    deinit {
        stop()
    }

    /// Öffnet den Port. Wirft, wenn er schon belegt ist oder kein Token existiert —
    /// ein lauschender Port ohne Token wäre eine Falle, die nur Fehler produziert.
    ///
    /// Erst `.ready` bestätigt den Start: `listener.start` meldet Bindefehler
    /// (z. B. Port schon belegt) asynchron als `.failed`. Ohne dieses Warten
    /// meldete `start()` Erfolg, obwohl kein Port lauscht — die CLI lief dann
    /// dauerhaft in `dispatchMain()`, ohne je erreichbar zu sein. Nicht von
    /// `queue` aus aufrufen (blockiert kurz bis `.ready`/`.failed`).
    public func start() throws {
        guard self.listener == nil else { return }
        guard router.hasToken else { throw ServeError.noToken }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) else {
            throw ServeError.badPort(config.port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw ServeError.listenFailed(config.port, error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let outcome = StartOutcome()
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log(L10n.format("core.bridge.listening", String(self.config.port)))
                outcome.finish(failure: nil)
            case .failed(let error):
                self.log(L10n.format("core.bridge.listen_failed", error.localizedDescription))
                // Während des Starts geht der Fehler an start() zurück; ein
                // späterer Laufzeitfehler bleibt wie bisher eine Protokollzeile.
                outcome.finish(failure: error.localizedDescription)
            default:
                break
            }
        }
        listener.start(queue: queue)
        switch outcome.wait(seconds: 5) {
        case .ready:
            self.listener = listener
        case .failed(let detail):
            listener.cancel()
            throw ServeError.listenFailed(config.port, detail)
        case .timedOut:
            listener.cancel()
            throw ServeError.listenFailed(config.port, L10n.text("core.bridge.start_timeout"))
        }
    }

    /// Übergibt das erste Start-Ergebnis (`.ready` oder `.failed`) vom
    /// Listener-Callback (läuft auf `queue`) an den wartenden `start()`-Aufrufer.
    private final class StartOutcome: @unchecked Sendable {
        enum Result {
            case ready
            case failed(String)
            case timedOut
        }

        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var failure: String?
        private var finished = false

        /// Nur das ERSTE Ergebnis zählt; spätere Zustandswechsel ignorieren.
        func finish(failure: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            self.failure = failure
            semaphore.signal()
        }

        func wait(seconds: TimeInterval) -> Result {
            guard semaphore.wait(timeout: .now() + seconds) == .success else { return .timedOut }
            lock.lock()
            defer { lock.unlock() }
            if let failure { return .failed(failure) }
            return .ready
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public var isRunning: Bool { listener != nil }

    // MARK: - Verbindungen

    private func accept(_ connection: NWConnection) {
        // Erste Hürde, noch vor dem Token: Kommt die Verbindung überhaupt aus dem
        // eigenen Netz? Eine versehentliche Portweiterleitung im Router soll die
        // Brücke nicht ins Internet stellen.
        guard let address = Self.peerAddress(connection),
              BridgePeer.isLocalNetwork(address) else {
            log(L10n.format("core.bridge.rejected_peer", Self.peerAddress(connection) ?? "?"))
            connection.cancel()
            return
        }
        guard openConnections < maxOpenConnections else {
            log(L10n.text("core.bridge.too_many"))
            connection.cancel()
            return
        }
        openConnections += 1

        let session = Session(connection: connection, address: address)
        // Wer eine Verbindung öffnet und dann schweigt, belegt sie nicht endlos.
        let timeout = DispatchWorkItem { [weak self] in
            self?.log(L10n.format("core.bridge.read_timeout", address))
            connection.cancel()
        }
        session.timeout = timeout
        queue.asyncAfter(deadline: .now() + readTimeoutSeconds, execute: timeout)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                session.timeout?.cancel()
                // Referenzzyklus lösen: Dieser Handler hält `session`, die Session
                // hält die Verbindung, und die Verbindung hält ihren Handler.
                // Ohne das Aufräumen bliebe jede beendete Verbindung samt
                // gepuffertem Request-Body dauerhaft im Speicher.
                session.connection.stateUpdateHandler = nil
                self?.finish(session)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(session)
    }

    /// Liest weiter, bis eine vollständige Anfrage im Puffer liegt.
    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.log(L10n.format("core.bridge.read_failed", error.localizedDescription))
                session.connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                session.buffer.append(data)
                // Harte Obergrenze: Kopf plus erlaubter Inhalt. Ein Gegenüber, das
                // mehr schickt als angekündigt, wird hier gestoppt.
                if session.buffer.count > self.maxBufferBytes {
                    self.send(.error(status: 413, message: L10n.format(
                        "core.bridge.too_large",
                        ByteSize.megabytes(Int64(self.maxBodyBytes))
                    )), on: session)
                    return
                }
            }

            switch BridgeHTTP.parse(session.buffer, maxBodyBytes: self.maxBodyBytes) {
            case .incomplete:
                if isComplete {
                    // Gegenseite hat zugemacht, ohne fertig zu werden.
                    session.connection.cancel()
                    return
                }
                // Frühe Token-Prüfung, sobald der Kopf vollständig ist: Ein Gerät
                // ohne gültiges Token darf nicht erst megabyteweise Body puffern —
                // sonst könnte es die Brücke VOR der Authentifizierung unter
                // Speicherdruck setzen. Für gültige Anfragen ändert sich nichts;
                // der Router prüft das Token wie bisher noch einmal.
                if !session.earlyAuthChecked,
                   case .complete(let method, let path, let bearer)
                       = BridgeHTTP.probeHeader(session.buffer) {
                    session.earlyAuthChecked = true
                    guard self.router.isAuthorized(bearerToken: bearer) else {
                        self.log(L10n.format("core.bridge.request_log",
                                             method, path, 401, "0", 0.0, session.address))
                        self.send(.error(status: 401,
                                         message: L10n.text("core.bridge.unauthorized")),
                                  on: session)
                        return
                    }
                }
                self.receive(session)
            case .failure(let response):
                self.send(response, on: session)
            case .complete(let request):
                session.timeout?.cancel()
                self.handle(request, on: session)
            }
        }
    }

    private func handle(_ request: BridgeRequest, on session: Session) {
        let started = Date()
        let bodyBytes = request.body.count
        Task { [router] in
            let response = await router.respond(to: request)
            self.log(L10n.format(
                "core.bridge.request_log",
                request.method, request.path, response.status,
                String(bodyBytes / 1024), Date().timeIntervalSince(started), session.address
            ))
            self.queue.async { self.send(response, on: session) }
        }
    }

    private func send(_ response: BridgeResponse, on session: Session) {
        // `.finalMessage` schließt die Senderichtung ordentlich (TCP-FIN), sobald die
        // Antwort draußen ist — genau das verspricht `Connection: close`.
        session.connection.send(
            content: response.httpData(), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.closeGracefully(session)
            }
        )
    }

    /// Wartet mit dem Abbrechen, bis die Gegenseite die Verbindung zumacht.
    ///
    /// Das ist kein Feinschliff, sondern nötig: `contentProcessed` bedeutet nur
    /// „an die Transportschicht übergeben“, nicht „beim Client angekommen“. Ein
    /// sofortiges `cancel()` reißt die Verbindung ab, und das Gegenüber sieht eine
    /// leere Antwort. Über Loopback fällt das kaum auf, über WLAN sehr wohl.
    private func closeGracefully(_ session: Session) {
        // Bewusst nur die Verbindung erfassen, nicht die Session: Der WorkItem
        // liegt bis zu `closeGraceSeconds` in der Queue — er soll die Session
        // (und deren Puffer) nicht so lange am Leben halten.
        let connection = session.connection
        let overdue = DispatchWorkItem { connection.cancel() }
        session.timeout = overdue
        queue.asyncAfter(deadline: .now() + closeGraceSeconds, execute: overdue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
            _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            overdue.cancel()
            connection.cancel()
        }
    }

    private func finish(_ session: Session) {
        guard !session.finished else { return }
        session.finished = true
        // Puffer sofort freigeben: Bis zur Deallokation der Session hielte er
        // sonst noch einen kompletten Request-Body fest.
        session.buffer = Data()
        session.timeout = nil
        openConnections = max(0, openConnections - 1)
    }

    // Intern (statt private) für die Grenzwert-Tests.
    var maxBodyBytes: Int { config.maxRequestMegabytes * 1_048_576 }
    /// Kopf, Trennzeile und erlaubter Inhalt: Der Parser akzeptiert zwischen
    /// Kopf und Body zusätzlich die vier Bytes `\r\n\r\n` — die zählen hier mit,
    /// sonst würde eine exakt maximale gültige Anfrage fälschlich abgewiesen.
    var maxBufferBytes: Int {
        maxBodyBytes + BridgeHTTP.maxHeaderBytes + BridgeHTTP.headerSeparatorBytes
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    /// Textuelle Gegenstellen-Adresse einer Verbindung.
    static func peerAddress(_ connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Nur für Tests: meldet die Deallokation einer Session — der Beweis, dass
    /// der frühere Referenzzyklus (Handler → Session → Verbindung → Handler)
    /// gelöst ist und beendete Verbindungen wirklich freigegeben werden.
    static var sessionDeinitHook: (@Sendable () -> Void)?

    /// Zustand einer einzelnen Verbindung. Wie beim Server gilt: alles wird nur
    /// auf `queue` gelesen und geschrieben.
    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        let address: String
        var buffer = Data()
        var timeout: DispatchWorkItem?
        var finished = false
        /// Wurde das Token schon nach dem Kopf geprüft? (Nur einmal nötig.)
        var earlyAuthChecked = false

        init(connection: NWConnection, address: String) {
            self.connection = connection
            self.address = address
        }

        deinit {
            BridgeServer.sessionDeinitHook?()
        }
    }

    public enum ServeError: Error, LocalizedError {
        case noToken
        case badPort(Int)
        case listenFailed(Int, String)

        public var errorDescription: String? {
            switch self {
            case .noToken:
                return L10n.text("core.bridge.no_token")
            case .badPort(let port):
                return L10n.format("core.bridge.bad_port", String(port))
            case .listenFailed(let port, let detail):
                return L10n.format("core.bridge.listen_port_failed", String(port), detail)
            }
        }
    }
}
