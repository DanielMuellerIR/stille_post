import Foundation

/// Besitzt nur den durch diese Betätigung gestarteten Hold-Auftrag. Die Engine
/// entscheidet weiterhin über Audio, Abbruchgeneration und einmalige Verarbeitung.
public struct DictationHotkeyState {
    public static let maximumHoldDuration: TimeInterval = 300
    public enum Input: Equatable { case pressed, released, interrupted, deadline }
    public enum Action: Equatable { case none, toggle, start, stop, cancel, stopAtLimit, cancelAtLimit, unavailable }
    public private(set) var isPressed = false
    public private(set) var ownsHold = false

    public init() {}

    public mutating func handle(_ input: Input, mode: Config.HotkeyMode, state: DictationState, canReadKeyboardState: Bool = true) -> Action {
        switch input {
        case .pressed:
            guard !isPressed else { return .none }
            isPressed = true
            if mode == .toggle { return .toggle }
            switch state {
            case .idle, .error:
                guard canReadKeyboardState else { return .unavailable }
                ownsHold = true
                return .start
            case .starting, .recording, .paused, .resuming, .processing: return .none
            }
        case .released, .interrupted, .deadline:
            if input == .released { isPressed = false }
            guard ownsHold else { return .none }
            ownsHold = false
            switch state {
            case .starting: return input == .deadline ? .cancelAtLimit : .cancel
            case .recording, .paused, .resuming:
                if input == .interrupted { return .cancel }
                return input == .deadline ? .stopAtLimit : .stop
            case .idle, .processing, .error: return .none
            }
        }
    }

    public mutating func didChangeState(_ state: DictationState) {
        switch state {
        case .starting, .recording, .paused, .resuming: break
        case .idle, .processing, .error: ownsHold = false
        }
    }
}
