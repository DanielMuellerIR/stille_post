import XCTest
@testable import StillePostCore

final class BridgeRouterTests: XCTestCase {
    private func object(_ response: BridgeResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testWrongOrMissingTokenIsRejectedEverywhere() async throws {
        let router = makeBridgeRouter()
        for request in [
            BridgeRequest(method: "GET", path: "/v1/health"),
            BridgeRequest(method: "GET", path: "/v1/health", bearerToken: "falsch"),
            BridgeRequest(method: "POST", path: "/v1/dictate", bearerToken: "richtig2",
                          body: Data("audio".utf8)),
        ] {
            let response = await router.respond(to: request)
            XCTAssertEqual(response.status, 401, "\(request.path) ohne gültiges Token")
        }
    }

    func testMissingTokenOnTheMacBlocksEvenACorrectRequest() async {
        // Solange kein Token angelegt ist, ist die Brücke zu — auch für jemanden,
        // der zufällig einen leeren Token schickt.
        let router = makeBridgeRouter(token: nil)
        let response = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/health", bearerToken: ""
        ))
        XCTAssertEqual(response.status, 401)
    }

    func testHealthReportsVersionAndCleanupState() async throws {
        let router = makeBridgeRouter(cleanupEnabled: false)
        let response = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/health", bearerToken: "richtig"
        ))
        XCTAssertEqual(response.status, 200)
        let json = try object(response)
        XCTAssertEqual(json["version"] as? String, "test")
        XCTAssertEqual(json["cleanup"] as? Bool, false)
    }

    func testDictateRunsTranscriptionThenExactlyOneCleanup() async throws {
        let counter = BridgeCleanupCounter()
        let router = makeBridgeRouter(cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        let json = try object(response)
        XCTAssertEqual(json["text"] as? String, "Sauberer Text.")
        XCTAssertEqual(json["raw"] as? String, "roher text")
        // Die Architekturregel „genau eine Bereinigung über den ganzen Text“ gilt
        // auch auf diesem Weg.
        XCTAssertEqual(counter.count, 1)
    }

    func testRawParameterSkipsCleanup() async throws {
        let counter = BridgeCleanupCounter()
        let router = makeBridgeRouter(cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", query: ["raw": "1"],
            bearerToken: "richtig", body: Data("audio".utf8)
        ))
        let json = try object(response)
        XCTAssertEqual(json["text"] as? String, "roher text")
        XCTAssertEqual(counter.count, 0)
    }

    func testSilenceYieldsEmptyTextWithoutCleanup() async throws {
        let counter = BridgeCleanupCounter()
        let router = makeBridgeRouter(transcribe: { _ in "   " }, cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try object(response)["text"] as? String, "")
        XCTAssertEqual(counter.count, 0, "Auf Stille wird kein Modell bemüht")
    }

    func testTranscriptionFailureBecomesServerError() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "whisper-server nicht erreichbar" }
        }
        let router = makeBridgeRouter(transcribe: { _ in throw Boom() })
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(try object(response)["error"] as? String, "whisper-server nicht erreichbar")
    }

    func testCleanupRouteTakesPlainTextAndReturnsCleanText() async throws {
        let counter = BridgeCleanupCounter()
        let router = makeBridgeRouter(cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig",
            body: Data("äh also so".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try object(response)["text"] as? String, "Sauberer Text.")
        XCTAssertEqual(counter.count, 1)
    }

    func testCleanupRouteRejectsEmptyAndNonUTF8Input() async throws {
        let router = makeBridgeRouter()
        let empty = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig", body: Data("  ".utf8)
        ))
        XCTAssertEqual(empty.status, 400)

        // 0xFF ist in UTF-8 nie gültig.
        let broken = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig",
            body: Data([0xFF, 0xFE, 0xFF])
        ))
        XCTAssertEqual(broken.status, 415)
    }

    func testRouterEnforcesTheBodyLimitItself() async throws {
        // Zweite Schutzschicht: Auch ein direkt erzeugter (nicht über
        // BridgeHTTP.parse gelaufener) Request unterliegt der Größengrenze.
        let router = makeBridgeRouter()  // maxBodyBytes: 1024
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig",
            body: Data(repeating: 65, count: 2048)
        ))
        XCTAssertEqual(response.status, 413)
    }

    func testHeavyRoutesNeverOverlap() async throws {
        // Der Actor allein serialisiert NICHT: Jedes await auf die Handler gibt
        // seine Isolation frei. Zwei gleichzeitige Diktate müssen trotzdem
        // nacheinander laufen — sonst streiten sie sich um whisper-server und
        // Bereinigungsmodell.
        final class OverlapProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var active = 0
            private var peak = 0
            func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
            func exit() { lock.lock(); active -= 1; lock.unlock() }
            var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
        }
        let probe = OverlapProbe()
        let router = makeBridgeRouter(transcribe: { _ in
            probe.enter()
            try? await Task.sleep(nanoseconds: 100_000_000)
            probe.exit()
            return "roher text"
        })
        async let first = router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio-eins".utf8)))
        async let second = router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio-zwei".utf8)))
        let responses = await [first, second]
        XCTAssertEqual(responses.map(\.status), [200, 200])
        XCTAssertEqual(probe.maxActive, 1, "Transkriptionen dürfen nie überlappen")
    }

    func testQueueLimitRejectsOverloadInsteadOfBufferingIt() async throws {
        // Die Serialisierung allein reicht nicht: Ohne Obergrenze hält jede
        // wartende Anfrage ihren vollständigen Body im Speicher, und ein
        // authentifizierter Client könnte beliebig viel Arbeit aufstauen (die
        // Größengrenze pro Anfrage sagt nichts über deren ANZAHL). Über der
        // Grenze muss die Brücke klar mit 503 ablehnen statt anzunehmen.
        let router = makeBridgeRouter(transcribe: { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return "roher text"
        })
        @Sendable func dictate() async -> BridgeResponse {
            await router.respond(to: BridgeRequest(
                method: "POST", path: "/v1/dictate", bearerToken: "richtig",
                body: Data("audio".utf8)
            ))
        }
        async let first = dictate()
        async let second = dictate()
        async let third = dictate()
        async let fourth = dictate()
        async let fifth = dictate()
        let statuses = await [first, second, third, fourth, fifth].map(\.status)
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 3,
                       "genau die Warteschlangentiefe darf durchlaufen")
        XCTAssertEqual(statuses.filter { $0 == 503 }.count, 2,
                       "der Rest wird abgelehnt, nicht gepuffert")
    }

    func testAbandonedRequestIsDroppedInsteadOfTranscribedForNobody() async throws {
        // Legt die Gegenstelle auf, während ihre Anfrage noch in der
        // Warteschlange steht, darf die Brücke die teure Arbeit gar nicht erst
        // beginnen — sonst belegt ein Client, der einfach geht, den einzigen
        // Arbeitsplatz weiter, und niemand holt das Ergebnis je ab.
        let started = BridgeCleanupCounter()
        let router = makeBridgeRouter(transcribe: { _ in
            started.increment()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return "roher text"
        })
        @Sendable func dictate() async -> BridgeResponse {
            await router.respond(to: BridgeRequest(
                method: "POST", path: "/v1/dictate", bearerToken: "richtig",
                body: Data("audio".utf8)
            ))
        }
        // Die erste Anfrage belegt den Arbeitsplatz …
        let first = Task { await dictate() }
        try await Task.sleep(nanoseconds: 50_000_000)
        // … die zweite stellt sich an und wird dann abgebrochen.
        let second = Task { await dictate() }
        try await Task.sleep(nanoseconds: 20_000_000)
        second.cancel()

        let abandoned = await second.value
        let delivered = await first.value
        XCTAssertEqual(delivered.status, 200, "die laufende Anfrage läuft normal zu Ende")
        XCTAssertEqual(abandoned.status, 503)
        // 503 allein wäre mehrdeutig — „ausgelastet“ hat denselben Status. Die
        // Meldung belegt, dass die Anfrage wirklich am Abbruch scheiterte und
        // nicht schon an der Warteschlangengrenze.
        XCTAssertEqual(try object(abandoned)["error"] as? String,
                       L10n.text("core.bridge.abandoned"))
        XCTAssertEqual(started.count, 1,
                       "die abgebrochene Anfrage darf nicht mehr transkribiert werden")
    }

    func testFinishedRequestLeavesNoDictationInTheQueue() async throws {
        // Eine fertige Task hält ihr Ergebnis fest, und das ist hier die
        // vollständige Antwort samt diktiertem Text. Bliebe sie als Kettenende
        // stehen, stünde das letzte Diktat bis zur nächsten Anfrage im Speicher.
        let router = makeBridgeRouter(transcribe: { _ in "streng vertrauliches diktat" })
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        let tail = await router.pipelineTail
        XCTAssertNil(tail, "nach getaner Arbeit darf am Kettenende nichts liegen bleiben")
    }

    func testUnknownPathAndWrongMethod() async {
        let router = makeBridgeRouter()
        let unknown = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/alles", bearerToken: "richtig"
        ))
        XCTAssertEqual(unknown.status, 404)

        let wrongMethod = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/dictate", bearerToken: "richtig"
        ))
        XCTAssertEqual(wrongMethod.status, 405)
    }
}
