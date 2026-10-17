import XCTest
import Network
@testable import StillePostCore

final class AppProfilePolicyTests: XCTestCase {
    func testLocalRecleanupKeepsPreviousVersionAndDistinguishesModelRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(baseDir: directory)
        let entry = HistoryStore.Entry(rawText: "Unveränderter Rohtext 128.", cleanText: "Bisherige Fassung 128.", status: "ok", durationSec: 1)
        try history.append(entry)
        let snapshot = try XCTUnwrap(history.list().first)
        let file = ConfigFile(url: directory.appendingPathComponent("config.json"))
        var config = Config(); config.cleanup.localOnly = true
        config.cleanup.ollamaURL = "http://192.0.2.1:11434"
        try file.save(config)
        do {
            _ = try await HistoryRecleanup.run(expected: snapshot, history: history, configFile: file)
            XCTFail("Verbotener Dienst darf keine Vorschau erzeugen")
        } catch {
            XCTAssertEqual(error as? HistoryRecleanup.Failure, .localUnavailable)
        }
        do {
            _ = try await HistoryRecleanup.run(expected: snapshot, history: history, configFile: file) { _, _ in
                .init(text: snapshot.rawText, usedFallback: true, fallbackReason: "Plausibilitätsfehler", endpoint: "local fixture")
            }
            XCTFail("Modellablehnung darf keine Vorschau erzeugen")
        } catch {
            XCTAssertEqual(error as? HistoryRecleanup.Failure, .unsuccessful)
        }
        XCTAssertEqual(try history.list().first, snapshot)
    }

    func testPriorityMigrationAndDeletedRules() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"cleanup":{"enabled":false}}"#.utf8))
        XCTAssertTrue(old.appProfiles.isEmpty)
        XCTAssertFalse(old.cleanup.localOnly)
        var config = Config()
        var first = Config.Profile(name: "Deutsch"); first.language = "de"
        var second = Config.Profile(name: "English"); second.language = "en"
        var cleanup = Config.Cleanup(); cleanup.localOnly = true
        second.cleanup = Config.CleanupOptions(cleanup)
        config.profiles = [first, second]; config.defaultProfileID = first.id
        config.appProfiles = ["com.example.Editor": second.id]
        let resolved = config.resolvedForRequest(appBundleID: "com.example.Editor")
        XCTAssertEqual(resolved.whisper.language, "en")
        XCTAssertTrue(resolved.cleanup.localOnly)
        XCTAssertFalse(config.resolvedForRequest().cleanup.localOnly, "Brücke/CLI lösen ohne lokale Ziel-App auf")
        XCTAssertEqual(resolved.requestProfileSelection?.reason, .application)
        XCTAssertEqual(config.profileSelection(appBundleID: "com.example.Unknown").reason, .standard)
        config.selectedProfileID = first.id
        XCTAssertEqual(config.resolvedForRequest(appBundleID: "com.example.Editor").whisper.language, "de")
        XCTAssertEqual(config.profileSelection(appBundleID: "com.example.Editor").reason, .manual)
        config.selectedProfileID = UUID()
        XCTAssertEqual(config.profileSelection(appBundleID: "com.example.Editor").profileID, second.id)
        config.selectedProfileID = nil
        config.appProfiles["com.example.Missing"] = UUID()
        XCTAssertEqual(config.profileSelection(appBundleID: "com.example.Missing").profileID, first.id)
        XCTAssertTrue(config.profileSelection(appBundleID: "com.example.Missing").missingAppProfile)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config)), config)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved)) as? [String: Any])
        XCTAssertNil(encoded["requestProfileSelection"])
        config.removeProfile(id: second.id)
        XCTAssertNil(config.appProfiles["com.example.Editor"])
        config.defaultProfileID = nil
        XCTAssertEqual(config.profileSelection(appBundleID: "com.example.Editor").reason, .global)
        let partial = Data("{\"appProfiles\":{\"com.example.Editor\":\"\(first.id)\",\"com.example.Bad\":42,\"invalid id\":\"\(first.id)\"}}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: partial).appProfiles, ["com.example.Editor":first.id])
    }

    func testOldProfileCleanupAndMalformedPolicyNeverDisableRestriction() throws {
        var value = Config(); var profile = Config.Profile(name: "Lokal")
        profile.cleanup = Config.CleanupOptions(value.cleanup); value.profiles = [profile]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        var profiles = json["profiles"] as! [[String: Any]]; var options = profiles[0]["cleanup"] as! [String: Any]
        options.removeValue(forKey: "localOnly"); profiles[0]["cleanup"] = options; json["profiles"] = profiles
        let restored = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.profiles[0].id, profile.id)
        XCTAssertNil(restored.profiles[0].cleanup?.localOnly)
        var inherited = restored; inherited.cleanup.localOnly = true; inherited.selectedProfileID = profile.id
        XCTAssertTrue(inherited.resolvedForRequest().cleanup.localOnly)
        options["localOnly"] = "invalid"; profiles[0]["cleanup"] = options; json["profiles"] = profiles
        json["cleanup"] = ["localOnly":"invalid"]
        let restricted = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(restricted.cleanup.localOnly)
        XCTAssertEqual(restricted.profiles[0].cleanup?.localOnly, true)
    }

    func testOptimisticRuleSavePreservesConcurrentSelectionAndVocabulary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ConfigFile(url: dir.appendingPathComponent("config.json"))
        var original = Config(); let profile = Config.Profile(name: "Tech"); original.profiles = [profile]
        try file.save(original)
        var edited = original; edited.appProfiles["com.example.Editor"] = profile.id
        try file.save(edited, expected: original)
        _ = try file.selectProfile(profile.id)
        _ = try file.addVocabulary(term: "SwiftUIExtra", variant: nil)
        XCTAssertThrowsError(try file.save(original, expected: original))
        let fresh = try file.load()
        XCTAssertEqual(fresh.appProfiles, edited.appProfiles)
        XCTAssertEqual(fresh.selectedProfileID, profile.id)
        XCTAssertTrue(fresh.cleanup.dictionary.contains("SwiftUIExtra"))
    }

    func testNumericLoopbackValidation() {
        for value in ["http://127.0.0.1:1234/v1", "https://127.42.0.9/v1", "http://[::1]:1234", "http://[0:0:0:0:0:0:0:1]:1234"] {
            XCTAssertTrue(CleanupNetworkPolicy.allows(URL(string:value)), value)
        }
        for value in ["http://localhost:1234", "http://127.0.0.1.example.com", "http://192.0.2.1", "https://example.com", "http://[::ffff:127.0.0.1]", "http://user:password@127.0.0.1", "file:///tmp/test", "http://[fe80::1%25en0]"] {
            XCTAssertFalse(CleanupNetworkPolicy.allows(URL(string:value)), value)
        }
    }

    func testNoAllowedServiceMakesZeroCallsAndPreservesRawWords() async {
        var config = Config.Cleanup(); config.localOnly = true
        config.ollamaURL = "http://192.0.2.1:11434"
        var cloud = Config.Cleanup.Endpoint(); cloud.provider = "openai"; cloud.remote.baseURL = "https://example.com/v1"
        var named = Config.Cleanup.Endpoint(); named.ollamaURL = "http://localhost:11434"
        config.fallbacks = [cloud, named]
        let transport = PolicyTransport(); let service = CleanupService(config: config, transport: transport)
        service.warmUp()
        let check = await service.checkOllamaEndpoint(named)
        XCTAssertEqual(check, .unreachable)
        let result = await service.clean("kein Wechsel 128 Version 2.4")
        XCTAssertTrue(result.usedFallback); XCTAssertNil(result.endpoint)
        XCTAssertEqual(result.text, TranscriptPolish.repairPunctuation("kein Wechsel 128 Version 2.4"))
        XCTAssertEqual(result.fallbackReason, L10n.text("core.cleanup.local_unavailable"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFilteredFallbackWarmupRetryAndLocalOpenAIWithoutKey() async {
        var config = Config.Cleanup(); config.localOnly = true; config.ollamaURL = "http://192.0.2.1:11434"
        var local = Config.Cleanup.Endpoint(); local.ollamaURL = "http://127.0.0.1:11434"; config.fallbacks = [local]
        let transport = PolicyTransport(); let service = CleanupService(config:config,transport:transport)
        service.warmUp()
        let result = await service.clean("Die Zahl bleibt 128.")
        XCTAssertFalse(result.usedFallback)
        for _ in 0..<50 where !transport.requests.contains(where:{$0.url?.path == "/api/generate"}) { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(transport.requests.contains(where:{$0.url?.path == "/api/generate"}))
        XCTAssertTrue(transport.requests.allSatisfy{CleanupNetworkPolicy.allows($0.url)})
        config.ollamaURL = local.ollamaURL; config.fallbacks = []
        for error in [URLError(.networkConnectionLost), URLError(.timedOut)] {
            let retry = PolicyTransport(); retry.streamFailure = error
            let service = CleanupService(config:config,transport:retry); service.notePrimarySuccess()
            let retried = await service.clean("Die Zahl bleibt 128.")
            XCTAssertFalse(retried.usedFallback)
            XCTAssertEqual(retry.streamFresh.first, false)
            if error.code == .timedOut { XCTAssertEqual(retry.streamFresh.count,1); XCTAssertTrue(retry.requests.contains{$0.url?.path == "/api/version"}) }
            else { XCTAssertEqual(retry.streamFresh,[false,true]) }
            XCTAssertTrue(retry.requests.allSatisfy{CleanupNetworkPolicy.allows($0.url)})
        }
        config.provider = "openai"; config.remote.baseURL = "http://127.0.0.1:1234/v1"; config.remote.model = "fixture"
        config.remote.apiKeyEnvVar = "STILLEPOST_AP09_UNSET_KEY"
        let localAPI = PolicyTransport()
        let localResult = await CleanupService(config:config,transport:localAPI).clean("Die Zahl bleibt 128.")
        XCTAssertFalse(localResult.usedFallback)
        XCTAssertEqual(localAPI.requests.count,1)
        XCTAssertTrue(localAPI.requests.allSatisfy{$0.value(forHTTPHeaderField:"Authorization") == nil}, "Lokaler Dienst erhält keinen API-Key")
    }

    func testAdmittedSnapshotKeepsLocalPolicyAcrossReconfiguration() async {
        var config = Config(); config.cleanup.localOnly = true; config.cleanup.ollamaURL = "http://192.0.2.1:11434"
        let transport = PolicyTransport()
        let requests = DictationRequestStore(config: config, transcriber: WhisperClient(config: config.whisper),
            cleanup: CleanupService(config: config.cleanup, transport: transport))
        let admitted = requests.snapshot()
        config.cleanup.localOnly = false
        requests.configure(config)
        let next = requests.snapshot()
        let oldResult = await admitted.cleanup.clean("Die Zahl bleibt 128.")
        XCTAssertTrue(oldResult.usedFallback)
        XCTAssertTrue(transport.requests.isEmpty)
        let newResult = await next.cleanup.clean("Die Zahl bleibt 128.")
        XCTAssertFalse(newResult.usedFallback)
        let count = transport.requests.count
        _ = await admitted.cleanup.clean("Die Zahl bleibt 128.")
        XCTAssertEqual(transport.requests.count,count)
    }

    func testRealTransportBlocksDirectRequestsAndEveryRedirectPath() async throws {
        let destination = try PolicyHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        let redirect = try PolicyHTTPServer(response: "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://localhost:\(destination.port)/target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let transport = URLSessionCleanupTransport(localOnly:true)
        let forbidden = URLRequest(url:URL(string:"http://localhost:\(destination.port)/target")!)
        do { _ = try await transport.data(for:forbidden,probing:false); XCTFail("Verbotenes Ziel angefragt") } catch {}
        transport.sendWarmUp(forbidden)
        do { _ = try await transport.streamLines(for:forbidden,freshConnection:true); XCTFail("Verbotener Stream") } catch {}
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(redirect.port)/redirect")!)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic dictation 128".utf8)
        for probe in [false,true] {
            let (_,response) = try await transport.data(for:request,probing:probe)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,307)
        }
        for fresh in [false,true] {
            let (lines,response) = try await transport.streamLines(for:request,freshConnection:fresh)
            for try await _ in lines {}
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,307)
        }
        let before = redirect.count; transport.sendWarmUp(request)
        for _ in 0..<100 where redirect.count==before { try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertGreaterThan(redirect.count,before)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(destination.count,0,"Verbotenes Redirectziel erhält keinen Request")
        let (_,response) = try await URLSessionCleanupTransport().data(for:request,probing:false)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        XCTAssertEqual(destination.count,1,"Gegenprobe beweist einen tatsächlich erreichbaren Empfänger")
    }
}

private final class PolicyTransport: CleanupTransport {
    let lock = NSLock()
    private var values:[URLRequest] = []
    private var freshValues:[Bool] = []
    var requests:[URLRequest] {lock.withLock{values}}
    var streamFresh:[Bool] {lock.withLock{freshValues}}
    var streamFailure: URLError?
    func sendWarmUp(_ request:URLRequest) {lock.withLock{values.append(request)}}
    func data(for request:URLRequest,probing:Bool) async throws -> (Data,URLResponse) {
        lock.withLock{values.append(request)}
        let body:Data
        if probing {body=Data("{}".utf8)}
        else if request.url!.path.contains("completions") {body=Data(#"{"choices":[{"message":{"content":"Die Zahl bleibt 128."}}]}"#.utf8)}
        else {body=Data(#"{"message":{"content":"Die Zahl bleibt 128."}}"#.utf8)}
        return (body,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    func streamLines(for request:URLRequest,freshConnection:Bool) async throws -> (AsyncThrowingStream<String,Error>,URLResponse) {
        let failure:URLError? = lock.withLock {values.append(request);freshValues.append(freshConnection);let error=streamFailure;streamFailure=nil;return error}
        if let failure {throw failure}
        return (AsyncThrowingStream { $0.yield(#"{"message":{"content":"Die Zahl bleibt 128."},"done":true}"#);$0.finish() },HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}

private final class PolicyHTTPServer: @unchecked Sendable {
    let listener:NWListener
    let queue=DispatchQueue(label:"stillepost.policy-http")
    let lock=NSLock();private var hits=0
    var count:Int {lock.withLock{hits}}
    var port:Int {Int(listener.port!.rawValue)}
    init(response:String) throws {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener=try NWListener(using:parameters)
        let ready=DispatchSemaphore(value:0)
        listener.stateUpdateHandler={state in if case .ready=state {ready.signal()};if case .failed=state {ready.signal()}}
        listener.newConnectionHandler={ [weak self] connection in
            guard let self else {return};connection.start(queue:self.queue)
            connection.receive(minimumIncompleteLength:1,maximumLength:65536) {data,_,_,_ in
                guard data?.isEmpty==false else {connection.cancel();return}
                self.lock.withLock{self.hits+=1}
                connection.send(content:Data(response.utf8),completion:.contentProcessed{_ in connection.cancel()})
            }
        }
        listener.start(queue:queue)
        guard ready.wait(timeout: .now() + 3) == .success,listener.port != nil else {listener.cancel();throw URLError(.timedOut)}
    }
    deinit {listener.cancel()}
}
