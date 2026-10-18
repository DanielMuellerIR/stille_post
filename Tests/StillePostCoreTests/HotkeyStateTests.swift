import XCTest
@testable import StillePostCore

final class HotkeyStateTests: XCTestCase {
    func testOldInvalidAndRoundTripModesAndOptimisticSave() throws {
        for json in [#"{}"#, #"{"hotkeyMode":"unknown"}"#, #"{"hotkeyMode":4}"#] {
            XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data(json.utf8)).hotkeyMode, .toggle)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ConfigFile(url: directory.appendingPathComponent("config.json"))
        var config = Config(); try file.save(config)
        let original = config
        config.hotkeyMode = .hold; try file.save(config, expected: original)
        XCTAssertNotEqual(original, config)
        XCTAssertEqual(try file.load(), config)
        XCTAssertEqual(try file.load().resolvedForRequest().hotkeyMode, .hold)
        XCTAssertThrowsError(try file.save(original, expected: original))
        config.lastResultHotkey = config.hotkey
        XCTAssertThrowsError(try config.validate())
    }

    func testToggleRepeatAndReleaseNeverStopOrRestartIndependently() {
        var input = DictationHotkeyState()
        XCTAssertEqual(input.handle(.pressed, mode: .toggle, state: .idle), .toggle)
        XCTAssertEqual(input.handle(.pressed, mode: .toggle, state: .recording), .none)
        XCTAssertEqual(input.handle(.released, mode: .toggle, state: .recording), .none)
        XCTAssertEqual(input.handle(.pressed, mode: .toggle, state: .recording), .toggle)
        XCTAssertEqual(input.handle(.deadline, mode: .toggle, state: .recording), .none)
    }

    func testShortHoldCancelsStartAndLongHoldStopsExactlyOnce() {
        var input = DictationHotkeyState()
        XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .idle), .start)
        XCTAssertEqual(input.handle(.released, mode: .hold, state: .starting), .cancel)
        XCTAssertFalse(input.ownsHold)
        XCTAssertEqual(input.handle(.released, mode: .hold, state: .idle), .none)
        XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .idle), .start)
        input.didChangeState(.recording)
        XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .recording), .none)
        XCTAssertEqual(input.handle(.released, mode: .hold, state: .recording), .stop)
        XCTAssertEqual(input.handle(.released, mode: .hold, state: .processing), .none)
    }

    func testBusyPressAndLateReleaseCannotOwnAnotherRecording() {
        for state in [DictationState.starting, .recording, .processing] {
            var input = DictationHotkeyState()
            XCTAssertEqual(input.handle(.pressed, mode: .hold, state: state), .none)
            XCTAssertEqual(input.handle(.released, mode: .hold, state: .recording), .none)
        }
        for state in [DictationState.idle, .processing, .error("fixture")] {
            var input = DictationHotkeyState()
            _ = input.handle(.pressed, mode: .hold, state: .idle)
            input.didChangeState(state)
            XCTAssertEqual(input.handle(.released, mode: .hold, state: .recording), .none)
        }
    }

    func testInterruptAndDeadlineStayLatchedUntilPhysicalRelease() {
        for interrupt in [DictationHotkeyState.Input.interrupted, .deadline] {
            for state in [DictationState.starting, .recording] {
                var input = DictationHotkeyState()
                _ = input.handle(.pressed, mode: .hold, state: .idle)
                let action = input.handle(interrupt, mode: .hold, state: state)
                XCTAssertEqual(action, interrupt == .interrupted ? .cancel : (state == .starting ? .cancelAtLimit : .stopAtLimit))
                XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .idle), .none)
                XCTAssertEqual(input.handle(interrupt, mode: .hold, state: state), .none)
                _ = input.handle(.released, mode: .hold, state: .idle)
                XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .error("fixture")), .start)
            }
        }
        XCTAssertEqual(DictationHotkeyState.maximumHoldDuration, 300)
    }

    func testUnavailableKeyboardStateBlocksOnlyHoldAndStaysLatched() {
        var input = DictationHotkeyState()
        XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .idle, canReadKeyboardState: false), .unavailable)
        XCTAssertFalse(input.ownsHold)
        XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .idle), .none)
        XCTAssertEqual(input.handle(.released, mode: .hold, state: .starting), .none)
        XCTAssertEqual(input.handle(.pressed, mode: .toggle, state: .idle, canReadKeyboardState: false), .toggle)
        _ = input.handle(.released, mode: .toggle, state: .idle)
        XCTAssertEqual(input.handle(.pressed, mode: .hold, state: .idle), .start)
    }

    func testHoldOwnershipSurvivesModeChangeUntilRelease() {
        var input = DictationHotkeyState()
        _ = input.handle(.pressed, mode: .hold, state: .idle)
        XCTAssertEqual(input.handle(.released, mode: .toggle, state: .recording), .stop)
    }
}
