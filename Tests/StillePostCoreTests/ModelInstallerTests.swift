import XCTest
@testable import StillePostCore

/// Tests für die Modellbeschaffung. Bewusst ohne Netz: geprüft wird die Logik, die
/// im Fehlerfall wehtut — vor allem die Frage "liegt hier eine eigene Kopie oder nur
/// ein geliehener Verweis?". Der Download selbst hängt an Hugging Face und gehört
/// nicht in die Testsuite.
final class ModelInstallerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("modelinstaller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingModelIsReported() {
        let path = directory.appendingPathComponent("ggml-large-v3-turbo.bin").path
        guard case .missing = ModelInstaller.state(atPath: path) else {
            return XCTFail("Ohne Datei muss der Zustand .missing sein")
        }
    }

    func testRealCopyIsReportedAsInstalled() throws {
        let path = directory.appendingPathComponent("ggml-large-v3-turbo.bin").path
        try Data(repeating: 0, count: 4242).write(to: URL(fileURLWithPath: path))

        guard case .installed(_, let bytes) = ModelInstaller.state(atPath: path) else {
            return XCTFail("Eine echte Datei muss .installed sein")
        }
        XCTAssertEqual(bytes, 4242, "Die Größe muss gemeldet werden")
    }

    /// Ein Verzeichnis am Modellpfad ist kein installiertes Modell. Würde es als
    /// `.installed` durchgehen, bieten App und CLI keinen Download an; der lokale
    /// whisper-server scheitert erst später mit dem irreführenden Verzeichnispfad.
    func testDirectoryAtModelPathIsNotReportedAsInstalled() throws {
        let path = directory.appendingPathComponent("ggml-large-v3-turbo.bin").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        guard case .missing(let reportedPath) = ModelInstaller.state(atPath: path) else {
            return XCTFail("Ein Verzeichnis darf nicht als installiertes Modell durchgehen")
        }
        XCTAssertEqual(reportedPath, path)
    }

    /// Der eigentliche Bug: `fileExists` und `[ -f ]` folgen Symlinks und melden für
    /// einen geliehenen Verweis "ist da". Auf dem Entwicklungsrechner zeigte der Modellpfad in den
    /// OpenWhispr-Cache — Stille Post hätte sein Modell verloren, sobald OpenWhispr
    /// aufräumt.
    func testSymlinkIsReportedAsBorrowedNotInstalled() throws {
        let foreign = directory.appendingPathComponent("fremder-cache.bin")
        try Data(repeating: 1, count: 100).write(to: foreign)
        let path = directory.appendingPathComponent("ggml-large-v3-turbo.bin").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: foreign.path)

        // Gegenprobe, dass der naive Weg hier tatsächlich danebenliegt:
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "fileExists folgt dem Symlink — genau deshalb taugt es hier nicht")

        guard case .borrowed(_, let target) = ModelInstaller.state(atPath: path) else {
            return XCTFail("Ein Symlink darf nicht als eigene Kopie durchgehen")
        }
        XCTAssertEqual(target, foreign.path, "Das Ziel des Verweises muss benannt werden")
    }

    /// Ein Symlink ins Leere ist auch kein Modell.
    func testDanglingSymlinkIsBorrowedNotMissing() throws {
        let path = directory.appendingPathComponent("ggml-large-v3-turbo.bin").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/gibt/es/nicht.bin")

        guard case .borrowed = ModelInstaller.state(atPath: path) else {
            return XCTFail("Ein toter Verweis ist ein Verweis, kein fehlendes Modell")
        }
    }

    func testStateExpandsTilde() {
        // Darf nicht als .installed durchgehen, nur weil die Tilde uninterpretiert bleibt.
        guard case .missing(let path) = ModelInstaller.state(atPath: "~/gibt-es-hoffentlich-nicht-4242.bin") else {
            return XCTFail("Erwartet: .missing")
        }
        XCTAssertFalse(path.hasPrefix("~"), "Die Tilde muss expandiert sein")
    }

    // MARK: - Zielpfad schuetzen

    /// Der Installer darf am Modellpfad nur eine reguläre Datei oder einen Verweis
    /// wegräumen. Alles andere gehört ihm nicht.
    func testTargetKindSeparatesReplaceableFromUntouchable() throws {
        let missing = directory.appendingPathComponent("gibt-es-nicht.bin").path
        XCTAssertEqual(ModelInstaller.targetKind(atPath: missing), .nothing)

        let file = directory.appendingPathComponent("modell.bin").path
        try Data(repeating: 0, count: 8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(ModelInstaller.targetKind(atPath: file), .replaceable)

        let link = directory.appendingPathComponent("verweis.bin").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: file)
        XCTAssertEqual(ModelInstaller.targetKind(atPath: link), .replaceable,
                       "ein Verweis wird ersetzt, sein Ziel bleibt unangetastet")

        let folder = directory.appendingPathComponent("ordner").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ModelInstaller.targetKind(atPath: folder), .unsupported)
    }

    /// Der eigentliche Schaden: Zeigt `whisper.modelPath` durch einen
    /// Konfigurationsfehler auf ein Verzeichnis, löschte `install-model --force`
    /// dessen gesamten Inhalt rekursiv, bevor es die Modelldatei dorthin schob.
    /// Jetzt bricht die Installation ab, ohne irgendetwas anzufassen — und zwar
    /// schon vor dem Download.
    func testInstallRefusesADirectoryAsModelPathWithoutDeletingAnything() async throws {
        let folder = directory.appendingPathComponent("wichtige-daten")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let treasure = folder.appendingPathComponent("nicht-loeschen.txt")
        try Data("wichtig".utf8).write(to: treasure)

        do {
            _ = try await ModelInstaller().install(ModelCatalog.turbo, to: folder.path)
            XCTFail("ein Verzeichnis am Modellpfad darf keine Installation erlauben")
        } catch let error as ModelInstaller.InstallError {
            XCTAssertEqual(error, .targetNotReplaceable(folder.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: treasure.path),
                      "der Inhalt des Verzeichnisses muss unangetastet bleiben")
    }

    /// Bei einer 206-Antwort muss der Server GENAU den angeforderten Bereich
    /// derselben Datei liefern. Ohne diese Prüfung hängt jeder beliebige
    /// Teilbereich an die vorhandene Teildatei an.
    func testContentRangeIsParsedStrictly() {
        let parsed = ModelInstaller.contentRange("bytes 100-199/1234")
        XCTAssertEqual(parsed?.start, 100)
        XCTAssertEqual(parsed?.total, 1234)

        XCTAssertNil(ModelInstaller.contentRange(nil))
        XCTAssertNil(ModelInstaller.contentRange("100-199/1234"), "ohne Einheit unbrauchbar")
        XCTAssertNil(ModelInstaller.contentRange("bytes */1234"), "ohne Bereich unbrauchbar")
        XCTAssertNil(ModelInstaller.contentRange("bytes 100-199/*"),
                     "ohne bekannte Gesamtgröße lässt sich nichts vergleichen")
    }

    // MARK: - Katalog

    func testCatalogOffersOnlyTurboAndLargeV3() {
        XCTAssertEqual(ModelCatalog.offered.map(\.name), ["large-v3-turbo", "large-v3"],
                       "Bewusste Entscheidung: nur diese zwei, Turbo zuerst")
    }

    func testModelLookupByName() {
        XCTAssertEqual(ModelCatalog.model(named: "large-v3-turbo"), ModelCatalog.turbo)
        XCTAssertNil(ModelCatalog.model(named: "tiny"), "Kleine Modelle bieten wir absichtlich nicht an")
    }

    func testFileNameAndURLFollowWhisperConvention() {
        XCTAssertEqual(ModelCatalog.turbo.fileName, "ggml-large-v3-turbo.bin")
        XCTAssertEqual(ModelCatalog.turbo.downloadURL.absoluteString,
                       "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
    }

    /// Der Default-Modellpfad der Config und der Dateiname des Standardmodells müssen
    /// zusammenpassen — sonst lädt die App an der Stelle vorbei, an der sie sucht.
    func testDefaultConfigPathMatchesDefaultModel() {
        XCTAssertTrue(Config.Whisper().modelPath.hasSuffix(ModelCatalog.turbo.fileName),
                      "Default-Modellpfad und Standardmodell dürfen nicht auseinanderlaufen")
    }

    /// Beide Modelle landen im selben Zielpfad — der steht als `whisper.modelPath`
    /// in der Konfiguration und ändert sich beim Modellwechsel nicht. Teilten sie
    /// sich deshalb auch die Teildatei, dann setzte ein Wechsel den abgebrochenen
    /// Download des anderen Modells fort: Die Bereichsanfrage holte den Rest der
    /// ANDEREN Datei, die Gesamtgröße stimmte am Ende, und die
    /// Vollständigkeitsprüfung ließ eine aus zwei Modellen zusammengesetzte Datei
    /// durch.
    func testPartialDownloadBelongsToExactlyOneModel() {
        let target = directory.appendingPathComponent("ggml-large-v3-turbo.bin").path
        let turbo = ModelInstaller.partialPath(for: ModelCatalog.turbo, at: target)
        let large = ModelInstaller.partialPath(for: ModelCatalog.largeV3, at: target)

        XCTAssertNotEqual(turbo, large,
                          "Zwei Modelle dürfen sich am selben Zielpfad keine Teildatei teilen")
        for partial in [turbo, large] {
            XCTAssertTrue(partial.hasPrefix(target), "Die Teildatei liegt neben dem Ziel")
            XCTAssertTrue(partial.hasSuffix(".partial"), "… und bleibt als Teildatei erkennbar")
            XCTAssertNotEqual(partial, target, "… überschreibt das Ziel aber nie")
        }
        XCTAssertTrue(turbo.contains(ModelCatalog.turbo.name),
                      "Der Modellname macht die Teildatei unterscheidbar")
    }

    func testResumeOnlyFromAUsableStart() {
        // Kuerzere Teildatei: fortsetzen, wo sie aufhoert.
        XCTAssertEqual(ModelInstaller.resumeOffset(existing: 0, expected: 100), 0)
        XCTAssertEqual(ModelInstaller.resumeOffset(existing: 40, expected: 100), 40)
        // Genau vollstaendig: nichts mehr zu holen.
        XCTAssertEqual(ModelInstaller.resumeOffset(existing: 100, expected: 100), 100)
        // Laenger als das Ziel — das kann kein Anfang der erwarteten Datei sein.
        // Ohne die 0 laedt hier nichts mehr, und jeder Versuch meldet dieselbe
        // unvollstaendige Datei.
        XCTAssertEqual(ModelInstaller.resumeOffset(existing: 140, expected: 100), 0)
    }

    func testPartialWriterNeverFollowsASymlink() throws {
        let foreign = directory.appendingPathComponent("fremd.bin")
        try Data("nicht anfassen".utf8).write(to: foreign)
        let partial = directory.appendingPathComponent("modell.partial")
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: foreign)

        XCTAssertThrowsError(try ModelInstaller.openPartialFile(
            atPath: partial.path, append: false, requestedOffset: 0
        )) { error in
            XCTAssertEqual(error as? ModelInstaller.InstallError,
                           .partialNotReplaceable(partial.path))
        }
        XCTAssertEqual(try Data(contentsOf: foreign), Data("nicht anfassen".utf8),
                       "der Symlink darf die fremde Datei weder kürzen noch beschreiben")
    }

    func testPartialWriterChecksAndUsesTheSameRegularFileDescriptor() throws {
        let partial = directory.appendingPathComponent("modell.partial")
        try Data("anfang".utf8).write(to: partial)

        let appending = try ModelInstaller.openPartialFile(
            atPath: partial.path, append: true, requestedOffset: 6
        )
        try appending.write(contentsOf: Data("-ende".utf8))
        try appending.close()
        XCTAssertEqual(String(decoding: try Data(contentsOf: partial), as: UTF8.self),
                       "anfang-ende")

        XCTAssertThrowsError(try ModelInstaller.openPartialFile(
            atPath: partial.path, append: true, requestedOffset: 2
        ), "ein inzwischen geänderter Versatz darf nicht an dieselbe Datei schreiben")

        let truncating = try ModelInstaller.openPartialFile(
            atPath: partial.path, append: false, requestedOffset: 0
        )
        try truncating.write(contentsOf: Data("neu".utf8))
        try truncating.close()
        XCTAssertEqual(String(decoding: try Data(contentsOf: partial), as: UTF8.self), "neu")
    }

    func testProgressFraction() {
        XCTAssertEqual(ModelInstaller.Progress(receivedBytes: 50, totalBytes: 200).fraction, 0.25)
        XCTAssertNil(ModelInstaller.Progress(receivedBytes: 50, totalBytes: 0).fraction,
                     "Ohne bekannte Gesamtgröße gibt es keinen Bruchteil")
    }

    /// Prozent und MB sind das, was App und CLI dem Nutzer zeigen. Beide steigen an
    /// derselben Stelle aus, wenn die Gesamtgröße noch unbekannt ist.
    func testProgressDisplayValues() {
        let progress = ModelInstaller.Progress(receivedBytes: 52_428_800, totalBytes: 104_857_600)
        XCTAssertEqual(progress.percent, 50)
        XCTAssertEqual(progress.receivedMegabytes, 50)
        XCTAssertEqual(progress.totalMegabytes, 100)
        XCTAssertNil(ModelInstaller.Progress(receivedBytes: 50, totalBytes: 0).percent,
                     "Ohne Gesamtgröße gibt es auch keine Prozentzahl")
    }

    /// MB werden in Mebibyte gerechnet (1 MB = 1024 KiB), nicht in Millionen Bytes —
    /// sonst nennt die App eine andere Zahl als der Finder.
    func testByteSizeUsesMebibytes() {
        XCTAssertEqual(ByteSize.megabytes(1_048_576), 1)
        XCTAssertEqual(ByteSize.megabytes(1_000_000), 0, "Abgerundet, kein Dezimal-Megabyte")
        XCTAssertEqual(ModelCatalog.turbo.approximateMegabytes, 1549)
    }
}
