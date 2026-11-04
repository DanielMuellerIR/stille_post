import Foundation
import StillePostCore
import Glibc

if CommandLine.arguments.contains("--cleanup") {
    Task {
        do { try await LinuxWorker.cleanStandardInput(); exit(0) }
        catch { FileHandle.standardError.write(Data("Bereinigung fehlgeschlagen.\n".utf8)); exit(1) }
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--version") {
    let versionURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VERSION")
    let version = (try? String(contentsOf: versionURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "development"
    print("Stille Post Linux \(version) (protocol 1)")
} else {
    do { try LinuxWorker().run() }
    catch { FileHandle.standardError.write(Data("Konfiguration konnte nicht geladen werden.\n".utf8)); exit(1) }
}
