import AppKit
import StillePostCore

/// Bietet beim Start an, das Whisper-Modell zu laden, wenn keines da ist.
///
/// Hintergrund: Bisher lief die App nur, weil vorher ein anderes Programm das Modell
/// installiert hatte. Wer nur die `.app` installiert — der normale Weg —, stand ohne
/// Modell da und bekam erst beim ersten Diktat einen Fehler zu sehen.
///
/// Bewusst als FRAGE und nicht als automatischer Download: 1,6 GB zieht man niemandem
/// ungefragt übers Netz, schon gar nicht unterwegs im Mobilfunk.
///
/// `@MainActor`, weil hier nur AppKit angefasst wird. Der Fortschritt kommt aus einem
/// Netzwerk-Task und muss deshalb sichtbar hierher zurückspringen — genau das macht
/// die Isolation zur Compiler-Prüfung statt zur Laufzeit-Hoffnung.
@MainActor
final class ModelDownloadController {

    /// `nonisolated`, damit der AppDelegate den Controller als normales Feld anlegen
    /// kann. Der Initialisierer rührt keinen isolierten Zustand an.
    nonisolated init() {}

    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?

    /// Prüft den Modellzustand und fragt, falls nötig. Tut nichts, wenn alles da ist.
    /// `onFinished` läuft nur nach einem erfolgreichen Download (die App kann dann
    /// z. B. den whisper-server neu starten).
    func offerIfNeeded(whisper: Config.Whisper, onFinished: @escaping () -> Void) {
        // In automatisierten Läufen darf hier kein Dialog aufpoppen.
        guard ProcessInfo.processInfo.environment["STILLEPOST_NO_MODEL_PROMPT"] == nil else { return }

        let model = ModelCatalog.turbo
        let megabytes = model.approximateMegabytes

        let alert = NSAlert()
        switch ModelInstaller.state(atPath: whisper.modelPath) {
        case .installed:
            return  // alles gut, nichts zu tun

        case .missing:
            alert.messageText = L10n.text("model.alert.missing.title")
            alert.informativeText = L10n.format("model.alert.missing.message", megabytes)

        case .borrowed(_, let target):
            alert.messageText = L10n.text("model.alert.borrowed.title")
            alert.informativeText = L10n.format("model.alert.borrowed.message", target, megabytes)
        }

        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text("model.alert.download"))
        alert.addButton(withTitle: L10n.text("model.alert.later"))
        // Menüleisten-App: ohne das läge der Dialog hinter anderen Fenstern.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        start(model: model, path: whisper.modelPath, onFinished: onFinished)
    }

    private func start(model: WhisperModel, path: String, onFinished: @escaping () -> Void) {
        showProgressWindow(model: model)
        let installer = ModelInstaller()

        Task { [weak self] in
            do {
                try await installer.install(model, to: path) { progress in
                    // Der Fortschritt kommt aus dem Netzwerk-Task; der Sprung auf den
                    // Main-Actor ist Pflicht, bevor die Oberfläche angefasst wird.
                    Task { @MainActor in self?.update(progress: progress) }
                }
                // Kein `await` nötig: Der Task erbt den Main-Actor von dieser Methode.
                self?.finish(onFinished: onFinished)
            } catch {
                self?.failed(with: error)
            }
        }
    }

    private func showProgressWindow(model: WhisperModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L10n.text("model.progress.title")
        window.center()

        let label = NSTextField(labelWithString: L10n.format("model.progress.loading", model.name))
        label.frame = NSRect(x: 20, y: 50, width: 340, height: 18)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 340, height: 20))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(bar)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.progressBar = bar
        self.statusLabel = label
    }

    private func update(progress: ModelInstaller.Progress) {
        guard let fraction = progress.fraction, let percent = progress.percent else { return }
        progressBar?.doubleValue = fraction
        statusLabel?.stringValue = L10n.format(
            "model.progress.status",
            percent,
            progress.receivedMegabytes,
            progress.totalMegabytes
        )
    }

    private func finish(onFinished: () -> Void) {
        closeProgressWindow()
        onFinished()
        report(title: L10n.text("model.success.title"),
               text: L10n.text("model.success.message"),
               style: .informational)
    }

    private func failed(with error: Error) {
        closeProgressWindow()
        // Ehrlich bleiben: Die Teildatei bleibt liegen, ein neuer Versuch setzt dort
        // fort — das steht so in der Fehlermeldung des Installers.
        report(title: L10n.text("model.failure.title"),
               text: error.localizedDescription,
               style: .warning)
    }

    private func closeProgressWindow() {
        window?.close()
        window = nil
        progressBar = nil
        statusLabel = nil
    }

    private func report(title: String, text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: L10n.text("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
