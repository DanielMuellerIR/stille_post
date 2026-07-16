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
