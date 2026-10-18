import AppKit
import SwiftUI
import StillePostCore

@MainActor final class SelectionCleanupWindowController: NSObject, NSWindowDelegate {
    private var window: SelectionCleanupPanel?
    private var generation = 0
    private let model = SelectionCleanupViewModel()
    var hasRequest: Bool { model.session.hasRequest }

    func start(_ capture: SelectedTextAccess.Capture, configuration: Config) throws {
        guard !hasRequest else { focus(); throw SelectionCleanupFailure.busy }
        generation += 1
        try model.start(capture, configuration: configuration)
        show()
    }
    func showFailure(_ error: Error) { guard !hasRequest else { focus(); return }; generation += 1; model.showFailure(error); show() }
    private func show() {
        if window == nil {
            let value = SelectionCleanupPanel(contentRect: NSRect(x: 0,y: 0,width: 740,height: 560),
                styleMask: [.titled,.closable,.resizable,.nonactivatingPanel], backing: .buffered,defer:false)
            value.title = L10n.text("selection.title"); value.contentMinSize = NSSize(width:640,height:480)
            value.isFloatingPanel = true; value.hidesOnDeactivate = false; value.isReleasedWhenClosed = false; value.delegate = self; value.center(); window = value
        }
        let token = generation
        window?.contentView = SelectionCleanupHostingView(rootView: SelectionCleanupView(model:model, close:{ [weak self] in
            guard let self, self.generation == token else { return }; self.dismiss()
        }, replace:{ [weak self] in self?.replaceSelection(expected:token) }, copy:{ [weak self] in
            guard let self, self.generation == token else { return }; self.model.copy()
        }))
        window?.orderFrontRegardless()
    }
    func focus() { window?.allowsKeyboardFocus = true; window?.makeKeyAndOrderFront(nil) }
    private func replaceSelection(expected: Int) {
        guard generation == expected, model.canReplace else { return }
        let token = generation
        window?.orderOut(nil); window?.allowsKeyboardFocus = false
        // Wie bei der Diktatvorschau erst den geliehenen Tastaturfokus freigeben.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.hasRequest else { return }
            self.model.replace(); self.window?.orderFrontRegardless()
        }
    }
    func dismiss() { generation += 1; model.close(); window?.allowsKeyboardFocus = false; window?.orderOut(nil); window?.contentView = nil }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
}

@MainActor final class SelectionCleanupViewModel: ObservableObject {
    let session = SelectionCleanupSession()
    @Published private(set) var capture: SelectedTextAccess.Capture?
    @Published private(set) var message: String?
    @Published private(set) var replaced = false
    @Published private(set) var replacementBlocked = false
    @Published private(set) var revision = 0

    init() { session.onChange = { [weak self] in self?.revision += 1 } }
    var canReplace: Bool { session.state == .preview && capture?.target?.permitsReplacement == true && !replacementBlocked && !replaced }
    var canCopy: Bool { session.state == .preview && session.result != nil }
    func start(_ capture: SelectedTextAccess.Capture, configuration: Config) throws {
        self.capture = capture; message = capture.restriction; replaced = false; replacementBlocked = false
        capture.target?.onInvalidated = { [weak self] in
            self?.replacementBlocked = true; self?.message = SelectionCleanupFailure.changed.localizedDescription
        }
        try session.start(text:capture.text,configuration:configuration,appBundleID:capture.bundleID,
                          requiresLocalOnly:capture.requiresLocalOnly)
    }
    func showFailure(_ error: Error) { close(); message = error.localizedDescription }
    func close() { capture?.target?.onInvalidated = nil; capture = nil; message = nil; replaced = false; replacementBlocked = false; session.close() }
    func replace() {
        guard canReplace, let result = session.result, let target = capture?.target else { return }
        do { try target.replace(with:result.text); replaced = true; message = L10n.text("selection.replaced") }
        catch { replacementBlocked = true; message = error.localizedDescription }
    }
    func copy() {
        guard canCopy, let result = session.result else { return }
        let board = NSPasteboard.general
        let previous = PasteboardSnapshot(pasteboard:board)
        let count = board.clearContents()
        if board.setString(result.text,forType:.string) { message = L10n.text("selection.copied") }
        else { previous.restore(to:board,ifChangeCountIs:count); message = L10n.text("selection.copy_failed") }
    }
}

@MainActor private struct SelectionCleanupView: View {
    @ObservedObject var model: SelectionCleanupViewModel
    let close: () -> Void
    let replace: () -> Void
    let copy: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L10n.text("selection.heading")).font(.title3.bold())
            if let capture = model.capture { Text(L10n.format("selection.application",capture.applicationName)).font(.headline) }
            if let config = model.session.configuration {
                Text(L10n.format("profiles.recording",config.profileLabel,config.whisper.language)).font(.callout)
                Text(L10n.text(!config.cleanup.enabled || config.cleanup.localOnly ? "selection.processing_local" : "selection.processing_text"))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Text(L10n.text("selection.help")).font(.callout).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
            if let message = model.message { Text(message).foregroundColor(model.replaced ? .green : .orange).font(.callout)
                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("selectionMessage") }
            if let reason = model.session.result?.fallbackReason {
                Text(reason).font(.caption).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true)
            }
            if model.session.input != nil {
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text(L10n.text("selection.input")).font(.headline).frame(maxWidth:.infinity,alignment:.leading)
                    HStack(alignment:.firstTextBaseline) {
                        Text(L10n.text("selection.output")).font(.headline)
                        Spacer(minLength:8)
                        if let result = model.session.result {
                            Text(L10n.text(result.origin == .rawFallback ? "selection.origin.rawFallback" : "editor.origin.\(result.origin.rawValue)"))
                                .font(.caption).foregroundColor(.secondary).accessibilityIdentifier("selectionOrigin")
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                HStack(alignment:.top,spacing:12) {
                    textBox(model.session.input ?? "",identifier:"selectionInput")
                    Group {
                        if model.session.isActive {
                            VStack(alignment:.leading) {
                                HStack { ProgressView().controlSize(.small);Text(L10n.text("selection.running"));Spacer() }
                                Spacer()
                            }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity)
                        } else if let result = model.session.result {
                            textBox(result.text,identifier:"selectionOutput")
                        } else if case .failed(let message) = model.session.state {
                            Text(message).foregroundColor(.red).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                }.frame(maxHeight:.infinity)
            } else { Spacer() }
            Divider()
            HStack {
                Button(L10n.text("selection.close"),action:close).keyboardShortcut(.cancelAction).accessibilityIdentifier("closeSelectionCleanup")
                Spacer()
                Button(L10n.text("selection.copy"),action:copy).disabled(!model.canCopy).accessibilityIdentifier("copySelectionCleanup")
                Button(L10n.text("selection.replace"),action:replace).disabled(!model.canReplace)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("replaceSelectionCleanup")
            }
        }.padding(16).frame(minWidth:640,minHeight:480)
    }
    private func textBox(_ text: String,identifier:String) -> some View {
        ScrollView { Text(verbatim:text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12) }
            .frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius:6)).accessibilityIdentifier(identifier)
    }
}

private final class SelectionCleanupPanel: NSPanel {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { allowsKeyboardFocus = true; makeKey() }
        super.sendEvent(event)
    }
}
private final class SelectionCleanupHostingView: NSHostingView<SelectionCleanupView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
