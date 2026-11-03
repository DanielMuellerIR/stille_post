import AppKit
import SwiftUI
import StillePostCore

/// Das unübersehbare Aufnahme-Overlay.
///
/// Design-Ziel: Es darf NIE passieren, dass man denkt, die Aufnahme läuft, obwohl
/// sie nicht läuft (oder umgekehrt). Deshalb:
///  - Großes, kräftig rotes Panel statt Mini-Fensterchen in der Ecke.
///  - Erscheint an der MAUSPOSITION: Wer die Bildschirm-Zoom-Funktion nutzt, hat
///    den vergrößerten Ausschnitt immer beim Cursor — dort ist auch das Overlay.
///  - Zeigt den LIVE-Mikrofonpegel: Man sieht, dass wirklich Ton ankommt.
///  - Schwebt über allen Fenstern und auf allen Spaces/Vollbild-Apps.
///  - Ein Klick auf das Overlay stoppt die Aufnahme (zusätzlich zum Hotkey).
final class OverlayController {

    /// Anzeige-Zustände des Overlays.
    enum Display {
        case starting(hold: Bool, resuming: Bool = false)
        case paused
        case recording                       // rot, pulsierend, Pegel + Uhr
        case processing(detail: String? = nil)  // orange, "Transkribiere …" (+ Zusatzzeile, z. B. Fallback-Hinweis)
        case success(note: String? = nil)    // grün, kurz "Eingefügt ✓" (+ Hinweis, z. B. "Rohtext"), blendet selbst aus
        case clipboard(note: String)        // blau, Text bleibt zum manuellen Einfügen bereit
        case silence                         // grau, kurz "Nur Stille erkannt"
        case failure(String)                 // rot, Fehlermeldung, blendet nach ein paar Sekunden aus
    }

    private var panel: NSPanel?
    private let model = OverlayModel()
    private var levelTimer: Timer?
    private var hideTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private let config: Config.UI
    var recordingContext: String = "" { didSet { model.recordingContext = recordingContext } }
    var recordingVad: String = "" {
        didSet {
            model.recordingVad = recordingVad
            if panel != nil {
                panel?.setContentSize(NSSize(width: 340, height: model.panelHeight))
                positionPanel()
            }
        }
    }
    var recordingReason: String = "" { didSet { model.recordingReason = recordingReason } }
    var recordingInstruction: String = "" { didSet { model.recordingInstruction = recordingInstruction } }
    var liveTranscriptPreview: Bool = false { didSet { model.liveTranscriptPreview = liveTranscriptPreview } }
    var transcriptPreview: DictationTranscriptPreview? {
        didSet { model.transcriptPreview = transcriptPreview }
    }
    var onClickStop: (() -> Void)?
    var onPauseResume: (() -> Void)?

    init(config: Config.UI) {
        self.config = config
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel != nil else { return }
            // Ein laufendes Overlay darf nach Abstecken oder Neuordnen der
            // Monitore nicht auf einer nicht mehr sichtbaren Fläche bleiben.
            self.presentPanel()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        levelTimer?.invalidate()
        hideTimer?.invalidate()
    }

    /// Liefert den aktuellen Pegel/die Dauer für die Live-Anzeige.
    var levelProvider: (() -> (levelDb: Double, duration: TimeInterval))?

    // MARK: - Anzeigen / Verstecken

    func show(_ display: Display) {
        hideTimer?.invalidate()
        hideTimer = nil

        switch display {
        case .starting(let hold, let resuming):
            model.mode = .starting(hold: hold, resuming: resuming)
            stopLevelUpdates()
            presentPanel()
        case .paused:
            stopLevelUpdates()
            model.duration = levelProvider?().duration ?? model.duration
            model.mode = .paused
            presentPanel()
        case .recording:
            model.mode = .recording
            startLevelUpdates()
            presentPanel()
        case .processing(let detail):
            model.mode = .processing(detail: detail)
            stopLevelUpdates()
            presentPanel()
        case .success(let note):
            model.mode = .success(note: note)
            stopLevelUpdates()
            presentPanel()
            // Mit Hinweis (z. B. "Rohtext eingefügt") länger stehen lassen — der
            // Nutzer soll die Abweichung vom Normalfall wirklich mitbekommen.
            scheduleHide(after: note == nil ? 0.9 : 3)
        case .clipboard(let note):
            model.mode = .clipboard(note: note)
            stopLevelUpdates()
            presentPanel()
            scheduleHide(after: 4)
        case .silence:
            model.mode = .silence
            stopLevelUpdates()
            presentPanel()
            scheduleHide(after: 1.6)
        case .failure(let message):
            model.mode = .failure(message)
            stopLevelUpdates()
            presentPanel()
            scheduleHide(after: 4)
        }
    }

    func hide() {
        stopLevelUpdates()
        hideTimer?.invalidate()
        hideTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func hidePreparation() {
        if case .starting = model.mode { hide() }
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    // MARK: - Panel-Aufbau

    private func presentPanel() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.setContentSize(NSSize(width: 340, height: model.panelHeight))
        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 340, height: model.panelHeight)
        // .nonactivatingPanel: Das Overlay stiehlt der Ziel-App NIE den Fokus —
        // sonst würde der diktierte Text am Ende ins Leere eingefügt.
        let panel = ClickThroughPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Ausblenden der Menüleisten-App darf die laufende Aufnahme nicht
        // unsichtbar machen. Das Panel bleibt dabei weiterhin ohne Fokus.
        panel.canHide = false
        // Über allem schweben, auch über Vollbild-Apps und auf jedem Space.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.onClick = { [weak self] in self?.onClickStop?() }

        let view = OverlayHostingView(rootView: OverlayView(model: model,
            pauseResume: { [weak self] in self?.onPauseResume?() },
            stop: { [weak self] in self?.onClickStop?() }))
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
        return panel
    }

    /// Platziert das Overlay: an der Maus (Default) oder unten mittig.
    private func positionPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        var origin: NSPoint
        if config.overlayPosition == "bottomCenter" {
            origin = NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                             y: screen.visibleFrame.minY + 80)
        } else {
            // An der Maus, leicht versetzt, damit der Cursor nichts verdeckt.
            origin = NSPoint(x: mouse.x + 24, y: mouse.y - panel.frame.height - 24)
        }
        // Auf den sichtbaren Bereich begrenzen (nicht aus dem Bildschirm ragen).
        let visible = screen.visibleFrame
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - panel.frame.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - panel.frame.height - 8))
        panel.setFrameOrigin(origin)
    }

    // MARK: - Live-Pegel

    private func startLevelUpdates() {
        stopLevelUpdates()
        // 20 Hz reichen für eine flüssige Pegel-Anzeige und kosten praktisch nichts.
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let provider = self.levelProvider else { return }
            let (levelDb, duration) = provider()
            self.model.levelDb = levelDb
            self.model.duration = duration
        }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

/// NSPanel-Unterklasse, die Klicks meldet (Klick aufs Overlay = Aufnahme stoppen)
/// und keine Tastatur-Fokusansprüche stellt.
final class ClickThroughPanel: NSPanel {
    var onClick: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - SwiftUI-Inhalt des Overlays

/// Beobachtbares Modell, das der Controller mit Live-Daten füttert.
final class OverlayModel: ObservableObject {
    enum Mode {
        case starting(hold: Bool, resuming: Bool = false)
        case recording, paused, silence
        case processing(detail: String?)
        case success(note: String?)
        case clipboard(note: String)
        case failure(String)
    }
    @Published var mode: Mode = .recording
    @Published var levelDb: Double = -120
    @Published var recordingContext = ""
    @Published var recordingVad = ""
    @Published var recordingReason = ""
    @Published var recordingInstruction = ""
    @Published var duration: TimeInterval = 0
    @Published var liveTranscriptPreview = false
    @Published var transcriptPreview: DictationTranscriptPreview?
    var showsTranscriptPreview: Bool {
        guard liveTranscriptPreview else { return false }
        switch mode {
        case .recording, .paused, .starting(_, resuming: true): return true
        default: return false
        }
    }
    var panelHeight: CGFloat {
        let previewHeight: CGFloat = showsTranscriptPreview ? 150 : 0
        switch mode {
        case .recording, .paused:
            // Der Rückfallgrund kann in DE drei Zeilen benötigen. Auch im
            // Hold-Modus müssen Hinweis und beide Schaltflächen Platz behalten.
            return (recordingVad.isEmpty ? 180 : 210) + previewHeight
        default: break
        }
        return 110 + previewHeight
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    var pauseResume: () -> Void = {}
    var stop: () -> Void = {}
    /// Steuert das Pulsieren des Aufnahme-Punkts.
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(background)
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(borderColor, lineWidth: 4)

            VStack(spacing: 0) {
                stateContent
                .frame(height: model.panelHeight - (model.showsTranscriptPreview ? 150 : 0))
                if model.showsTranscriptPreview {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("overlay.live_preview.title"))
                            .font(.system(size: 11, weight: .semibold))
                        Text(previewText).font(.system(size: 13))
                            .lineLimit(model.transcriptPreview?.hasFailedSegment == true ? 3 : 5).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("liveTranscriptText")
                        if model.transcriptPreview?.hasFailedSegment == true {
                            Text(L10n.text("overlay.live_preview.failed")).font(.system(size: 10))
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.white).padding(12)
                    .frame(height: 134)
                    .background(Color.black.opacity(0.22)).cornerRadius(10)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: 340, height: model.panelHeight)
    }

    @ViewBuilder private var stateContent: some View {
        switch model.mode {
        case .starting(let hold, let resuming):
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(L10n.text(resuming ? "overlay.resuming" : "overlay.starting")).font(.system(size: 19, weight: .bold)).foregroundColor(.white)
                }
                if hold {
                    Text(L10n.text(resuming ? "hotkey.hold.release" : "hotkey.hold.release_start")).font(.system(size: 11)).foregroundColor(.white.opacity(0.9))
                }
                if resuming { overlayButton("recording.finish", identifier: "finishRecording", action: stop) }
            }
            .padding(.horizontal, 20)
        case .recording:
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    // Großer pulsierender Punkt: DAS Signal "es läuft wirklich".
                    Circle()
                        .fill(Color.red)
                        .frame(width: 26, height: 26)
                        .scaleEffect(pulse ? 1.0 : 0.6)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("overlay.recording"))
                            .font(.system(size: 21, weight: .heavy))
                            .foregroundColor(.white)
                        Text(model.recordingContext)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier("recordingProfile")
                        if !model.recordingReason.isEmpty {
                            Text(model.recordingReason).font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                                .accessibilityIdentifier("recordingProfileReason")
                        }
                        if !model.recordingVad.isEmpty {
                            Text(model.recordingVad).font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundColor(.white.opacity(0.95))
                                .accessibilityIdentifier("recordingVad")
                        }
                        Text(L10n.format("recording.audio_time", timeString))
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundColor(.white.opacity(0.85))
                        if !model.recordingInstruction.isEmpty {
                            Text(model.recordingInstruction).font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white).accessibilityIdentifier("recordingHoldInstruction")
                        }
                    }
                    Spacer(minLength: 4)
                    LevelMeter(levelDb: model.levelDb)
                }
                HStack(spacing: 10) {
                    overlayButton("recording.pause", identifier: "pauseResumeRecording", action: pauseResume)
                    overlayButton("recording.finish", identifier: "finishRecording", action: stop)
                }
            }
            .padding(.horizontal, 20)
        case .paused:
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("overlay.paused")).font(.system(size: 21, weight: .heavy))
                        Text(model.recordingContext).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            .accessibilityIdentifier("recordingProfile")
                        if !model.recordingReason.isEmpty {
                            Text(model.recordingReason).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                        }
                        if !model.recordingVad.isEmpty {
                            Text(model.recordingVad).font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundColor(.white.opacity(0.95))
                                .accessibilityIdentifier("recordingVad")
                        }
                        Text(L10n.format("recording.audio_time", timeString)).font(.system(size: 14).monospacedDigit())
                        Text(L10n.text("recording.microphone_off")).font(.system(size: 11, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                if !model.recordingInstruction.isEmpty {
                    Text(model.recordingInstruction).font(.system(size: 11))
                }
                HStack(spacing: 10) {
                    overlayButton("recording.resume", identifier: "pauseResumeRecording", action: pauseResume)
                    overlayButton("recording.finish", identifier: "finishRecording", action: stop)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
        case .processing(let detail):
            VStack(spacing: 5) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text(L10n.text("overlay.transcribing"))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                }
                // Transparenz bei Fallbacks: zeigt z. B. "Ausweichweg: <Modell>",
                // damit längeres Warten erklärbar ist statt mysteriös.
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                }
            }
        case .success(let note):
            VStack(spacing: 5) {
                Label(L10n.text("overlay.inserted"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                if let note {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                }
            }
        case .clipboard(let note):
            VStack(spacing: 5) {
                Label(L10n.text("overlay.copied"), systemImage: "doc.on.clipboard")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
        case .silence:
            Label(L10n.text("overlay.silence"), systemImage: "waveform.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
        case .failure(let message):
            VStack(spacing: 6) {
                Label(L10n.text("overlay.failed"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 14)
        }
    }

    private var previewText: String {
        guard let preview = model.transcriptPreview, !preview.text.isEmpty else {
            if model.transcriptPreview?.hasFailedSegment == true { return L10n.text("overlay.live_preview.no_prefix") }
            return L10n.text("overlay.live_preview.waiting")
        }
        return (preview.isTruncated ? "… " : "") + preview.text
    }

    private func overlayButton(_ key: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(key)).font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
                .background(Color.white.opacity(0.16)).cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var background: Color {
        switch model.mode {
        case .recording: return Color(red: 0.55, green: 0.05, blue: 0.05).opacity(0.94)
        case .starting, .paused, .processing: return Color(red: 0.55, green: 0.33, blue: 0).opacity(0.94)
        case .success: return Color(red: 0.05, green: 0.42, blue: 0.1).opacity(0.94)
        case .clipboard: return Color(red: 0.1, green: 0.25, blue: 0.45).opacity(0.94)
        case .silence: return Color(white: 0.22).opacity(0.94)
        case .failure: return Color(red: 0.45, green: 0.07, blue: 0.07).opacity(0.96)
        }
    }

    private var borderColor: Color {
        switch model.mode {
        case .recording: return .red
        case .starting, .paused, .processing: return .orange
        case .success: return .green
        case .clipboard: return .blue
        case .silence: return .gray
        case .failure: return .red
        }
    }

    private var timeString: String {
        let total = Int(model.duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Live-Pegelanzeige: 12 Balken, die mit dem Mikrofonpegel mitgehen.
/// Sichtbarer Beweis, dass das Mikrofon wirklich Ton liefert.
struct LevelMeter: View {
    let levelDb: Double

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < activeBars ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 5, height: 8 + CGFloat(index) * 3)
            }
        }
        .animation(.linear(duration: 0.05), value: activeBars)
    }

    /// Pegel (-60…0 dBFS) auf 0…12 Balken abbilden.
    private var activeBars: Int {
        let clamped = max(-60.0, min(0.0, levelDb))
        return Int(((clamped + 60) / 60 * 12).rounded())
    }
}
