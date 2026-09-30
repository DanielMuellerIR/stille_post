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
    private var running = false
    private var stoppingListener: NWListener?
    private var stopCallbacks: [@Sendable () -> Void] = []
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var startCallbacks: [@Sendable (Result<Void, Error>) -> Void] = []
    private var startTimeout: DispatchWorkItem?
    private let queueKey = DispatchSpecificKey<Bool>()
    /// Gleichzeitig offene Verbindungen. Mehr als eine Handvoll braucht ein
    /// Heimnetz nie; die Grenze verhindert, dass ein fehlerhafter Client den Mac
    /// mit halboffenen Verbindungen zusetzt.
    private var openConnections = 0
    private let maxOpenConnections = 8
    /// Summe aller gerade gepufferten Anfrage-Bytes über ALLE Verbindungen.
    private var bufferedBytes = 0
    /// So lange darf eine Anfrage zum Übertragen brauchen. Die Verarbeitungszeit
    /// danach (Whisper, Bereinigung) zählt nicht mit.
    private let readTimeoutSeconds: TimeInterval = 30
    /// Frist, in der die Gegenseite die Antwort abholen und die Verbindung
    /// schließen darf, bevor die Brücke sie selbst abbricht.
    private let closeGraceSeconds: TimeInterval = 10

    /// Protokollzeilen für stderr oder die App. Enthalten nie Diktattext und nie
    /// das Token — nur Methode, Pfad, Status, Größe und Dauer.
    public var onLog: (@Sendable (String) -> Void)?
    /// Nur für Regressionstests: meldet, dass eine vollständige Anfrage samt
    /// reserviertem Byte-Budget an den Router übergeben wurde.
    var onRequestAcceptedForTesting: (@Sendable () -> Void)?
    /// Nur für den Grenzwerttest: meldet die konkrete Ablehnung am gemeinsamen
    /// Byte-Budget, unabhängig von TCP-Paketgrenzen der Antwort.
    var onBufferBudgetRejectedForTesting: (@Sendable () -> Void)?

    /// Woher der Grund kommt, wenn kein gültiges Token vorliegt. Nur für Tests
    /// einspeisbar; produktiv liest es denselben Schlüsselbund wie der Router.
    private let tokenStatus: @Sendable () -> BridgeToken.LoadOutcome

    public init(config: Config.Bridge, router: BridgeRouter,
                tokenStatus: @escaping @Sendable () -> BridgeToken.LoadOutcome
                    = { BridgeToken.loadOutcome() }) {
        self.config = config
        self.router = router
        self.tokenStatus = tokenStatus
        queue.setSpecific(key: queueKey, value: true)
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
        let cleanup = {
            self.listener?.newConnectionHandler = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel()
            self.finishStart(.failure(CancellationError()))
            for session in Array(self.sessions.values) {
                session.connection.cancel()
                self.finish(session)
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cleanup()
        } else {
            queue.sync(execute: cleanup)
        }
    }

    /// Öffnet den Port ohne den Aufrufer zu blockieren. Auch die Token-Prüfung
    /// läuft auf der Server-Queue, damit ein gesperrter Schlüsselbund die GUI
    /// nicht anhält. Erst `.ready` bestätigt den Erfolg.
    public func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            if running { completion(.success(())); return }
            startCallbacks.append(completion)
            guard listener == nil, stoppingListener == nil else { return }
            beginStartOnQueue()
        }
    }

    private func beginStartOnQueue() {
        do {
            if !router.hasToken {
                if case .failed(let status) = tokenStatus() {
                    throw ServeError.keychainUnavailable(status)
                }
                throw ServeError.noToken
            }
            guard (1...65535).contains(config.port),
                  let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
                throw ServeError.badPort(config.port)
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = false
            let created = try NWListener(using: parameters, on: port)
            listener = created
            created.newConnectionHandler = { [weak self, weak created] connection in
                guard let self, self.listener === created, self.running else {
                    connection.cancel(); return
                }
                self.accept(connection)
            }
            created.stateUpdateHandler = { [weak self, weak created] state in
                guard let self, self.listener === created else { return }
                switch state {
                case .ready:
                    self.running = true
                    self.log(L10n.format("core.bridge.listening", String(self.config.port)))
                    self.finishStart(.success(()))
                case .failed(let error):
                    self.log(L10n.format("core.bridge.listen_failed", error.localizedDescription))
                    self.stopOnQueue(startError: ServeError.listenFailed(
                        self.config.port, error.localizedDescription))
                default: break
                }
            }
            let timeout = DispatchWorkItem { [weak self, weak created] in
                guard let self, self.listener === created, !self.running else { return }
                self.stopOnQueue(startError: ServeError.listenFailed(
                    self.config.port, L10n.text("core.bridge.start_timeout")))
            }
            startTimeout = timeout
            queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            created.start(queue: queue)
        } catch {
            stopOnQueue(startError: error)
        }
    }

    /// Synchroner CLI-/Test-Einstieg. Die App nutzt ausschließlich den Callback.
    public func start() throws {
        precondition(DispatchQueue.getSpecific(key: queueKey) == nil)
        let outcome = StartOutcome()
        start { outcome.finish($0) }
        try outcome.wait().get()
    }

    private final class StartOutcome: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<Void, Error> = .failure(CancellationError())
        func finish(_ result: Result<Void, Error>) {
            self.result = result
            semaphore.signal()
        }
        func wait() -> Result<Void, Error> {
            semaphore.wait()
            return result
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        startTimeout?.cancel()
        startTimeout = nil
        let callbacks = startCallbacks
        startCallbacks = []
        callbacks.forEach { $0(result) }
    }

    /// Auch Abschalten wartet in der GUI nicht auf laufende Schlüsselbundarbeit.
    /// Die Queue erhält die Reihenfolge von Start, Stop und erneutem Start.
    public func stop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            stopOnQueue(startError: CancellationError(), completion: completion)
        }
    }

    private func stopOnQueue(startError: Error,
                             completion: (@Sendable () -> Void)? = nil) {
        if let completion { stopCallbacks.append(completion) }
        if let stopped = listener {
            listener = nil
            stoppingListener = stopped
            stopped.newConnectionHandler = nil
            // Bis `.cancelled` bleibt der Listener separat erhalten. Weitere
            // Stop-Callbacks und neue Starts warten ebenfalls auf die Portfreigabe.
            stopped.stateUpdateHandler = { [self, weak stopped] state in
                guard stoppingListener === stopped else { return }
                if case .cancelled = state {
                    stopped?.stateUpdateHandler = nil
                    stoppingListener = nil
                    finishStop()
                    if !startCallbacks.isEmpty { beginStartOnQueue() }
                }
            }
            stopped.cancel()
        }
        running = false
        finishStart(.failure(startError))
        for session in Array(sessions.values) {
            session.connection.cancel()
            finish(session)
        }
        if stoppingListener == nil { finishStop() }
    }

    private func finishStop() {
        let callbacks = stopCallbacks
        stopCallbacks = []
        callbacks.forEach { $0() }
    }

    public var isRunning: Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return running }
        return queue.sync { running }
    }

    // MARK: - Verbindungen

    private func accept(_ connection: NWConnection) {
        // Erste Hürde, noch vor dem Token: Kommt die Verbindung überhaupt aus dem
        // eigenen Netz? Eine versehentliche Portweiterleitung im Router soll die
        // Brücke nicht ins Internet stellen.
        let peer = Self.peerAddress(connection)
        guard let address = peer, BridgePeer.isLocalNetwork(address) else {
            // Wie in der Anfragezeile einzeilig maskieren: Die Adresse kommt von
            // außen, und eine abgewiesene Gegenstelle darf `bridge.log` genauso
            // wenig verbiegen wie eine angenommene.
            log(L10n.format("core.bridge.rejected_peer",
                            Self.singleLineLogField(peer ?? "?")))
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
        sessions[ObjectIdentifier(session)] = session
        // Wer eine Verbindung öffnet und dann schweigt, belegt sie nicht endlos.
        let timeout = DispatchWorkItem { [weak self] in
            self?.log(L10n.format("core.bridge.read_timeout",
                                  Self.singleLineLogField(address)))
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
                self.bufferedBytes += data.count
                // Harte Obergrenze: Kopf plus erlaubter Inhalt. Ein Gegenüber, das
                // mehr schickt als angekündigt, wird hier gestoppt.
                if session.buffer.count > self.maxBufferBytes {
                    self.send(.error(status: 413, message: L10n.format(
                        "core.bridge.too_large",
                        ByteSize.megabytes(Int64(self.maxBodyBytes))
                    )), on: session)
                    return
                }
                // Zweite Grenze, diesmal über alle Verbindungen zusammen: Die
                // Größe je Anfrage sagt nichts über ihre ANZAHL. Acht offene
                // Verbindungen könnten sonst acht volle Bodys gleichzeitig im
                // Speicher halten, obwohl der Router höchstens drei schwere
                // Anfragen annimmt und den Rest mit 503 abweist. Überlast also
                // ablehnen, bevor sie gepuffert ist.
                if self.bufferedBytes > self.maxBufferedBytesTotal {
                    self.onBufferBudgetRejectedForTesting?()
                    self.send(.error(status: 503, message: L10n.text("core.bridge.busy")),
                              on: session)
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
                    if let failure = self.router.authorizationFailure(bearerToken: bearer) {
                        self.log(L10n.format("core.bridge.request_log",
                                             Self.singleLineLogField(method),
                                             Self.singleLineLogField(path),
                                             401, "0", 0.0,
                                             Self.singleLineLogField(session.address))
                                 + " — " + failure.logDescription)
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
                // Der Body steckt jetzt in `request`; der Rohpuffer daneben wird
                // nicht mehr gebraucht und hielte den Inhalt sonst ein zweites
                // Mal im Speicher fest. Das gemeinsame BYTE-BUDGET bleibt aber
                // bis zum Ende der Router-Arbeit reserviert: `request.body` hält
                // dieselben Nutzdaten weiterhin im Speicher.
                self.transferBufferToRequestReservation(session)
                self.onRequestAcceptedForTesting?()
                // Empfangs-EOF beendet nur die Senderichtung des Clients.
                // Der vollständige Request darf weiterhin beantwortet werden.
                session.receivedEOF = isComplete
                self.handle(request, on: session)
            }
        }
    }

    private func handle(_ request: BridgeRequest, on session: Session) {
        let started = Date()
        let bodyBytes = request.body.count
        // Grund einer Abweisung schon hier festhalten: Die frühe Prüfung oben
        // greift nur, wenn der Inhalt noch nicht vollständig da war. Kleine
        // Anfragen kommen oft in einem Rutsch an und landen direkt hier — ohne
        // diese Zeile stünde für sie wieder nur ein nacktes „401“ im Protokoll.
        let authFailure = router.authorizationFailure(bearerToken: request.bearerToken)
        // Die Task an die Verbindung hängen. Legt die Gegenstelle auf, storniert
        // `finish` sie, und der Router nimmt eine noch wartende Anfrage dann gar
        // nicht erst aus der Warteschlange.
        session.work = Task { [router] in
            let response = await router.respond(to: request)
            var line = L10n.format(
                "core.bridge.request_log",
                Self.singleLineLogField(request.method),
                Self.singleLineLogField(request.path), response.status,
                String(bodyBytes / 1024), Date().timeIntervalSince(started),
                Self.singleLineLogField(session.address)
            )
            if response.status == 401, let authFailure {
                line += " — " + authFailure.logDescription
            }
            self.log(line)
            self.queue.async {
                // Die Task hat ihre Antwort gebaut und gibt gleich auch den
                // erfassten Request frei. Erst jetzt darf die nächste Verbindung
                // dessen Byte-Budget verwenden.
                self.releaseRequestReservation(session)
                guard !session.finished else { return }
                self.send(response, on: session)
            }
        }
        monitorDisconnect(session)
    }

    private func send(_ response: BridgeResponse, on session: Session) {
        guard !session.finished else { return }
        // Fehlerantworten entstehen teilweise ohne `handle`; auch dann braucht
        // das geordnete Schließen genau einen laufenden EOF-Empfang.
        monitorDisconnect(session)
        // Sobald eine Antwort rausgeht, hat der Lese-Timeout seine Aufgabe
        // erledigt — zentral hier und nicht an jeder Antwortstelle einzeln.
        // Ohne das Stornieren bliebe sein WorkItem die volle Frist in der Queue
        // liegen, hielte die Verbindung fest (er erfasst sie stark) und
        // protokollierte am Ende einen Lese-Timeout, den es nie gab. Sichtbar
        // wurde das bei der frühen 401-Antwort: `closeGracefully` überschreibt
        // `session.timeout` gleich darauf mit seinem eigenen WorkItem, der alte
        // war danach nicht mehr erreichbar.
        session.timeout?.cancel()
        session.timeout = nil
        // `.finalMessage` schließt die Senderichtung ordentlich (TCP-FIN), sobald die
        // Antwort draußen ist — genau das verspricht `Connection: close`.
        session.connection.send(
            content: response.httpData(), contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, !session.finished else { return }
                if error != nil {
                    session.connection.cancel()
                    self.finish(session)
                } else {
                    self.closeGracefully(session)
                }
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
        guard !session.finished else { return }
        session.responseSent = true
        let connection = session.connection
        let overdue = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + closeGraceSeconds, execute: overdue)
        if session.receivedEOF {
            // Logisch beendet, aber der Transport behält seine Abholfrist:
            // contentProcessed bestätigt auch nach Client-FIN keinen Empfang.
            finish(session)
        } else {
            session.timeout = overdue
        }
        // `monitorDisconnect` liest bereits seit Beginn der Arbeit weiter. Ein
        // zweiter paralleler receive wäre nicht nur unnötig, sondern könnte das
        // EOF dem falschen Callback überlassen.
    }

    /// Überwacht nach dem vollständigen Request weiter die Empfangsrichtung.
    /// EOF beendet nur die Empfangsrichtung. Echte Fehler stornieren die Arbeit;
    /// ein Client darf nach seinem FIN weiterhin auf die Antwort warten.
    private func monitorDisconnect(_ session: Session) {
        guard !session.monitoringDisconnect, !session.receivedEOF else { return }
        session.monitoringDisconnect = true
        receiveDisconnect(session)
    }

    private func receiveDisconnect(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
            [weak self] _, _, isComplete, error in
            guard let self, !session.finished else { return }
            if error != nil {
                session.timeout?.cancel()
                session.connection.cancel()
                return
            }
            if isComplete {
                session.receivedEOF = true
                // Nach dem Antwort-FIN ist auch diese Richtung geschlossen;
                // während der Arbeit bedeutet EOF dagegen keinen Abbruch.
                if session.responseSent {
                    // Den bereits geplanten Transport-Timeout weiterlaufen
                    // lassen, ohne die logische Session dafür festzuhalten.
                    session.timeout = nil
                    self.finish(session)
                }
                return
            }
            // Zusätzliche Bytes sind für `Connection: close` bedeutungslos; bis
            // zum EOF weiterlesen, damit ein Client die Arbeit abbrechen kann.
            self.receiveDisconnect(session)
        }
    }

    private func finish(_ session: Session) {
        guard !session.finished else { return }
        session.finished = true
        // Puffer sofort freigeben: Bis zur Deallokation der Session hielte er
        // sonst noch einen kompletten Request-Body fest.
        // Eine stornierte Task hält den Request bis zu ihrem tatsächlichen Ende.
        // Ihre Reservierung bleibt deshalb trotz Verbindungsende bestehen.
        bufferedBytes = max(0, bufferedBytes - session.buffer.count)
        session.buffer = Data()
        if session.work == nil { releaseRequestReservation(session) }
        session.timeout?.cancel()
        session.timeout = nil
        session.connection.stateUpdateHandler = nil
        sessions.removeValue(forKey: ObjectIdentifier(session))
        // Angefangene Arbeit stornieren. Nach einer normal ausgelieferten
        // Antwort ist die Task längst fertig und das bleibt folgenlos; bei einem
        // echten Verbindungsabbruch gibt es dagegen den Arbeitsplatz der Brücke
        // sofort frei, statt für niemanden weiterzurechnen.
        session.work?.cancel()
        session.work = nil
        openConnections = max(0, openConnections - 1)
    }

    /// Gibt die zweite Rohpuffer-Kopie frei, ohne das gemeinsame Budget zu
    /// verkleinern. Die Buchung wandert auf den daraus erzeugten Request.
    private func transferBufferToRequestReservation(_ session: Session) {
        session.requestReservationBytes += session.buffer.count
        session.buffer = Data()
    }

    /// Router-Arbeit beendet: Jetzt ist die Reservierung nicht mehr nötig.
    /// `finish` kann zuvor schon alles ausgebucht haben; deshalb idempotent.
    private func releaseRequestReservation(_ session: Session) {
        bufferedBytes = max(0, bufferedBytes - session.requestReservationBytes)
        session.requestReservationBytes = 0
    }

    // Intern (statt private) für die Grenzwert-Tests.
    var maxBodyBytes: Int { config.maxRequestMegabytes * 1_048_576 }
    /// Wie viele Anfrage-Bytes die Brücke insgesamt gleichzeitig puffern darf.
    /// Mehr, als die Warteschlange des Routers annimmt, muss sie nie halten.
    var maxBufferedBytesTotal: Int { maxBufferBytes * BridgeRouter.maxPipelineDepth }
    /// Kopf, Trennzeile und erlaubter Inhalt: Der Parser akzeptiert zwischen
    /// Kopf und Body zusätzlich die vier Bytes `\r\n\r\n` — die zählen hier mit,
    /// sonst würde eine exakt maximale gültige Anfrage fälschlich abgewiesen.
    var maxBufferBytes: Int {
        maxBodyBytes + BridgeHTTP.maxHeaderBytes + BridgeHTTP.headerSeparatorBytes
    }
    /// Synchroner Schnappschuss nur für Byte-Budget-Regressionstests.
    func bufferedBytesForTesting() -> Int { queue.sync { bufferedBytes } }

    private func log(_ message: String) {
        onLog?(message)
    }

    /// Macht ein fremdes Feld für genau eine Protokollzeile sicher. Der Parser
    /// lehnt Steuerzeichen bereits ab; diese zweite Schranke schützt auch
    /// direkt konstruierte Requests und künftige Aufrufwege.
    static func singleLineLogField(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let category = scalar.properties.generalCategory
            if category == .control || category == .lineSeparator
                || category == .paragraphSeparator {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
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
        /// Bytes des bereits geparsten Requests, die dessen Task noch festhält.
        var requestReservationBytes = 0
        var timeout: DispatchWorkItem?
        var finished = false
        /// Wurde das Token schon nach dem Kopf geprüft? (Nur einmal nötig.)
        var earlyAuthChecked = false
        /// Die laufende Verarbeitung dieser Anfrage — damit `finish` sie bei
        /// einem Verbindungsabbruch stornieren kann.
        var work: Task<Void, Never>?
        /// Genau ein EOF-Empfang bleibt während Arbeit und Antwort aktiv.
        var monitoringDisconnect = false
        var receivedEOF = false
        var responseSent = false

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
        case keychainUnavailable(OSStatus)
        case badPort(Int)
        case listenFailed(Int, String)

        public var errorDescription: String? {
            switch self {
            case .noToken:
                return L10n.text("core.bridge.no_token")
            case .keychainUnavailable(let status):
                return L10n.format("core.bridge.keychain_read_error", String(status))
            case .badPort(let port):
                return L10n.format("core.bridge.bad_port", String(port))
            case .listenFailed(let port, let detail):
                return L10n.format("core.bridge.listen_port_failed", String(port), detail)
            }
        }
    }
}
