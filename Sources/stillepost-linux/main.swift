import Foundation
import StillePostCore
import Glibc

if CommandLine.arguments.contains("--cleanup") {
    Task {
        do {
            try await LinuxWorker.cleanStandardInput()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Bereinigung fehlgeschlagen.\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--version") {
    print("Stille Post Linux \(AppVersion.current) (protocol 1)")
} else {
    Task { @MainActor in
        do {
            try LinuxWorker().run()
        } catch {
            FileHandle.standardError.write(Data("Konfiguration konnte nicht geladen werden.\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}
