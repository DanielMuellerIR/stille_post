import AppKit
import StillePostCore

// Native Carbon-/Tastenstatus-Prüfung ohne Mikrofon, Audio, Netz oder Einfügen.
@main struct HotkeyRegression {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let scenario = CommandLine.arguments[2]
        let mode: Config.HotkeyMode = scenario == "toggle" ? .toggle : .hold
        var input = DictationHotkeyState(), state = DictationState.idle
        var generation = 0, starts = 0, recordings = 0, completed = 0
        let begin = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        func save(_ event: String) {
            events.append(["event": event, "seconds": ProcessInfo.processInfo.systemUptime - begin,
                           "keyDown": CGEventSource.keyState(.combinedSessionState, key: 40),
                           "hidKeyDown": CGEventSource.keyState(.hidSystemState, key: 40),
                           "sessionFlags": CGEventSource.flagsState(.combinedSessionState).rawValue,
                           "hidFlags": CGEventSource.flagsState(.hidSystemState).rawValue,
                           "accessibilityTrusted": AXIsProcessTrusted(),
                           "listenAllowed": CGPreflightListenEventAccess()])
            let value: [String: Any] = ["scenario": scenario, "state": String(describing: state), "starts": starts,
                "recordings": recordings, "completed": completed, "events": events]
            try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        }
        func update(_ value: DictationState) { state = value; input.didChangeState(value) }
        func start() {
            generation += 1; let current = generation
            starts += 1; update(.starting)
            DispatchQueue.main.asyncAfter(deadline: .now() + (scenario == "limit-start" ? 0.9 : (scenario == "quick" ? 0.5 : 0.2))) {
                guard generation == current, state == .starting else { return }
                recordings += 1; update(.recording); save("recording")
            }
        }
        func stop() {
            update(.processing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { completed += 1; update(.idle); save("completed") }
        }
        func receive(_ event: DictationHotkeyState.Input) {
            let action = input.handle(event, mode: mode, state: state, canReadKeyboardState: HotkeyManager.canReadKeyboardState)
            switch action {
            case .none, .unavailable: break
            case .toggle:
                if state == .idle { start() } else if state == .recording { stop() }
            case .start: start()
            case .stop, .stopAtLimit: stop()
            case .cancel, .cancelAtLimit: generation += 1; update(.idle)
            }
            save(String(describing: event) + ":" + String(describing: action))
        }
        var shortcut = Config.Hotkey(); shortcut.keyCode = 40; shortcut.modifiers = ["ctrl", "cmd"]
        let manager = try HotkeyManager(config: shortcut, onRelease: { receive(.released) },
            onInterruption: { receive(.interrupted) }, onHoldLimit: { receive(.deadline) },
            maximumHoldDuration: scenario.hasPrefix("limit") ? 0.5 : DictationHotkeyState.maximumHoldDuration,
            onPress: { receive(.pressed) })
        save("ready")
        if scenario.hasPrefix("state-probe") {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in DispatchQueue.main.async { save("sample") } }
        }
        if scenario == "interrupt" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { save("finished"); app.terminate(nil) }
        withExtendedLifetime(manager) { app.run() }
    }
}
