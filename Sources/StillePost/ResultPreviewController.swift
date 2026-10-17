import AppKit
import SwiftUI
import StillePostCore

/// Ein nicht aktivierendes Panel kann Tastaturfokus erhalten, ohne die Ziel-App
/// zu aktivieren. Nach dem Schließen prüft PasteService das ursprüngliche Ziel.
final class ResultPreviewController: NSObject, NSWindowDelegate {
    enum Action { case insert, copy, discard }

    private var panel: ResultPanel?
    private var completion: ((Action) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    func show(_ result: TransientResultStore.Result, focus: Bool = false, floating: Bool = true,
              completion: @escaping (Action) -> Void) {
        dismiss()
        if panel == nil {
            let panel = ResultPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.title = L10n.text("result.title")
            panel.isReleasedWhenClosed = false
            panel.contentMinSize = NSSize(width: 480, height: 300)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.center()
            self.panel = panel
        }
        self.completion = completion
        panel?.isFloatingPanel = floating
        panel?.level = floating ? .floating : .normal
        panel?.contentView = ResultHostingView(rootView: ResultPreviewView(result: result) { [weak self] action in
            self?.finish(action)
        })
        panel?.orderFrontRegardless()
        if focus { self.focus() }
    }

    func focus() {
        panel?.allowsKeyboardFocus = true
        panel?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        completion = nil
        panel?.orderOut(nil)
        panel?.allowsKeyboardFocus = false
        panel?.contentView = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.discard)
        return false
    }

    private func finish(_ action: Action) {
        let handler = completion
        dismiss()
        // Erst den vom Panel geliehenen Tastaturfokus zurückgeben, dann das Ziel
        // prüfen. Eine fremde App wird dabei niemals per activate() zurückgeholt.
        DispatchQueue.main.async { handler?(action) }
    }
}

private final class ResultPanel: NSPanel {
    // AppKit kann das erste sichtbare Fenster beim Start zum Key-Fenster machen,
    // selbst wenn es nur per orderFrontRegardless gezeigt wurde. Die automatische
    // Vorschau darf deshalb bis zu einer ausdrücklichen Aktion gar nicht Key sein.
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            allowsKeyboardFocus = true
            makeKey()
        }
        super.sendEvent(event)
    }
}

private final class ResultHostingView: NSHostingView<ResultPreviewView> {
    // Der erste Klick in die noch unfokussierte Vorschau soll bereits den
    // gewählten Knopf ausführen, statt nur das Panel zum Key-Fenster zu machen.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ResultPreviewView: View {
    let result: TransientResultStore.Result
    let action: (ResultPreviewController.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("result.heading"))
                .font(.title3.bold())
            Text(L10n.text("result.help"))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if result.rawFallback {
                Text(result.note ?? L10n.text("app.raw_fallback_note"))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(result.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(L10n.text("result.keyboard_help"))
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button(L10n.text("result.discard")) { action(.discard) }
                    .keyboardShortcut(".", modifiers: .command)
                Spacer()
                Button(L10n.text("result.copy")) { action(.copy) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help(L10n.text("result.copy_shortcut"))
                Button(L10n.text("result.insert")) { action(.insert) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 300)
        .environment(\.locale, Locale(identifier: L10n.languageCode))
    }
}
