import AppKit

/// Erneuert die Menüleisten-Anbindung nach einem Wechsel der Bildschirmfläche.
final class StatusItemController {
    private(set) var item: NSStatusItem!
    private let configure: (NSStatusItem) -> Void
    private let screens: () -> [CGRect]
    private let notifications: NotificationCenter
    private let delay: TimeInterval
    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var attachedScreens: [CGRect] = []

    init(notifications: NotificationCenter = .default,
         screens: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) },
         delay: TimeInterval = 0.5,
         configure: @escaping (NSStatusItem) -> Void) {
        self.notifications = notifications
        self.screens = screens
        self.delay = delay
        self.configure = configure
        recreate()
        observer = notifications.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.screenParametersChanged()
        }
    }

    func recreate() {
        cancelPending()
        if let item {
            item.menu?.cancelTracking()
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        // Die beim Anlegen vergebene AppKit-Kennung bleibt erhalten, damit sich
        // die Identität der Menüleisten-Anbindung nicht nachträglich ändert.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configure(item)
        item.isVisible = true
        attachedScreens = screens()
    }

    func invalidate() {
        cancelPending()
        if let observer { notifications.removeObserver(observer) }
        observer = nil
    }

    private func screenParametersChanged() {
        cancelPending()
        let layout = screens()
        guard !layout.isEmpty, layout != attachedScreens else { return }
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            let layout = self.screens()
            guard !layout.isEmpty, layout != self.attachedScreens else { return }
            self.recreate()
        }
        pending = work
        // AppKit muss die neue Menüleiste zuerst fertig zuordnen. Eine Serie von
        // Bildschirmmeldungen führt deshalb erst nach ihrem Ende zu einem Neubau.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    deinit {
        invalidate()
        if let item { NSStatusBar.system.removeStatusItem(item) }
    }
}
