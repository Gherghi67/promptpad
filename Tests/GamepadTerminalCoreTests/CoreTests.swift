import XCTest
@testable import GamepadTerminalCore

final class CoreTests: XCTestCase {
    let target = TerminalTarget(sessionID: "session-a", windowID: "window-a", tabID: "tab-a", title: "shell")

    func ready() -> ApplicationState {
        var state = ApplicationState()
        _ = state.handle(.enabledChanged(true))
        _ = state.handle(.controllerConnected(true))
        _ = state.handle(.foregroundChanged(true))
        _ = state.handle(.bridgeChanged(.connected))
        return state
    }

    func start(_ state: inout ApplicationState) -> UInt64 {
        XCTAssertEqual(state.handle(.intent(.dictationPressed)), [.captureTarget(generation: state.generation)])
        let gen = state.generation
        XCTAssertEqual(state.handle(.targetCaptured(generation: gen, target: target)), [.startRecording(generation: gen, target: target)])
        XCTAssertEqual(state.handle(.recordingStarted(generation: gen)), [])
        return gen
    }

    func review(_ state: inout ApplicationState) -> UInt64 {
        let gen = start(&state)
        XCTAssertEqual(state.handle(.intent(.dictationReleased)), [.stopAndTranscribe(generation: gen)])
        XCTAssertEqual(state.handle(.transcriptReady(generation: gen, text: "echo hello\r\n")), [])
        return gen
    }

    func testSanitizationRemovesEveryC0AndC1Control() throws {
        let controls = String(String.UnicodeScalarView((0...159).compactMap { value in
            (value < 32 || value >= 127) ? UnicodeScalar(value) : nil
        }))
        let text = TranscriptSanitizer.sanitize("hello" + controls + "world\u{2028}next\u{2029}line\u{200B}\u{202E}!")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) })
        XCTAssertEqual(text, "hello world next line!")
        XCTAssertEqual(try TranscriptSanitizer.validated("  café\t🙂\r\n命令  "), "café 🙂 命令")
        XCTAssertEqual(TranscriptSanitizer.sanitize("echo \u{1b}[31mhi\u{1b}[0m"), "echo [31mhi[0m")
    }

    func testSanitizationRejectsEmptyAndByteOverflow() {
        XCTAssertThrowsError(try TranscriptSanitizer.validated("\n\t\u{1b}\u{0}"))
        XCTAssertThrowsError(try TranscriptSanitizer.validated(String(repeating: "🙂", count: 2049)))
        XCTAssertNoThrow(try TranscriptSanitizer.validated(String(repeating: "a", count: 8192)))
    }

    func testCrossInsertsThenSeparateCrossSubmitsToCapturedTarget() {
        var state = ready()
        let gen = review(&state)
        XCTAssertEqual(state.dictation, .review(generation: gen, target: target, text: "echo hello"))
        XCTAssertEqual(state.handle(.intent(.confirm)), [.insertTranscript(generation: gen, target: target, text: "echo hello")])
        XCTAssertEqual(state.handle(.intent(.confirm)), []) // cannot queue Enter while insertion is pending
        XCTAssertEqual(state.handle(.insertionFinished(generation: gen)), [])
        XCTAssertEqual(state.dictation, .inserted(generation: gen, target: target))
        XCTAssertEqual(state.handle(.intent(.confirm)), [.submit(generation: gen, target: target)])
        XCTAssertEqual(state.handle(.intent(.confirm)), [])
        _ = state.handle(.submissionFinished(generation: gen))
        XCTAssertEqual(state.dictation, .idle)
        XCTAssertNotEqual(state.generation, gen)
    }

    func testRecordingAndTranscribingBlockTerminalButtonsAndReviewAlsoBlocks() {
        var state = ready()
        let gen = start(&state)
        for intent: ControllerIntent in [.confirm, .terminal(.arrow(.up)), .terminal(.control(.tab)), .showHelp, .scrollModeChanged(true)] {
            XCTAssertEqual(state.handle(.intent(intent)), [])
        }
        _ = state.handle(.intent(.dictationReleased))
        XCTAssertEqual(state.handle(.intent(.confirm)), [])
        _ = state.handle(.transcriptReady(generation: gen, text: "draft"))
        XCTAssertEqual(state.handle(.intent(.terminal(.arrow(.up)))), [])
        XCTAssertFalse(state.scrollMode)
    }

    func testAllGateLossesCancelGenerationAndRejectLateCallbacks() {
        for gate in [ApplicationEvent.enabledChanged(false), .controllerConnected(false), .foregroundChanged(false), .bridgeChanged(.disconnected)] {
            var state = ready()
            let gen = start(&state)
            XCTAssertEqual(state.handle(gate), [.cancelVoice(generation: gen)])
            XCTAssertEqual(state.dictation, .idle)
            XCTAssertFalse(state.canUseTerminal)
            XCTAssertEqual(state.handle(.transcriptReady(generation: gen, text: "late")), [])
            XCTAssertEqual(state.handle(.recordingStarted(generation: gen)), [])
            XCTAssertEqual(state.handle(.failed(generation: gen, message: "stale")), [])
            XCTAssertNil(state.error)
            XCTAssertEqual(state.handle(.intent(.confirm)), [])
            XCTAssertEqual(state.handle(.intent(.dictationPressed)), [])
        }
    }

    func testReleaseDuringCaptureOrStartAbortsBeforeLateRecording() {
        var state = ready()
        _ = state.handle(.intent(.dictationPressed))
        let aborted = state.generation
        XCTAssertEqual(state.handle(.intent(.dictationReleased)), [.cancelVoice(generation: aborted)])
        XCTAssertEqual(state.handle(.targetCaptured(generation: aborted, target: target)), [])
        _ = state.handle(.intent(.dictationPressed))
        let gen = state.generation
        _ = state.handle(.targetCaptured(generation: gen, target: target))
        XCTAssertEqual(state.handle(.intent(.dictationReleased)), [.cancelVoice(generation: gen)])
        XCTAssertEqual(state.handle(.recordingStarted(generation: gen)), [])
        XCTAssertEqual(state.dictation, .idle)
    }

    func testCancelAndModifiedCircleDiscardDraftWithoutSendingControl() {
        for intent in [ControllerIntent.cancel, .terminal(.control(.interrupt))] {
            var state = ready()
            let gen = review(&state)
            XCTAssertEqual(state.handle(.intent(intent)), [.cancelVoice(generation: gen)])
            XCTAssertEqual(state.dictation, .idle)
        }
    }

    func testFailedInsertionNeverAllowsAnImplicitRetryOrSubmit() {
        var state = ready()
        let gen = review(&state)
        _ = state.handle(.intent(.confirm))
        _ = state.handle(.failed(generation: gen, message: "Outcome unknown: inspect the pinned session."))
        XCTAssertEqual(state.dictation, .idle)
        XCTAssertEqual(state.handle(.insertionFinished(generation: gen)), [])
        XCTAssertNotNil(state.error)
        XCTAssertEqual(state.handle(.intent(.confirm)), [])
        XCTAssertFalse(state.canUseTerminal)
        _ = state.handle(.dismissError)
        XCTAssertTrue(state.canUseTerminal)
    }

    func testOrdinaryCrossEscapeAndInterruptHaveDistinctEffects() {
        var state = ready()
        let gen = state.generation
        XCTAssertEqual(state.handle(.intent(.confirm)), [.terminal(generation: gen, action: .control(.enter))])
        XCTAssertEqual(state.handle(.intent(.cancel)), [.terminal(generation: gen, action: .control(.escape))])
        XCTAssertEqual(state.handle(.intent(.terminal(.control(.interrupt)))), [.terminal(generation: gen, action: .control(.interrupt))])
    }

    func testViewerOpensOnToggleAndConsumesConfirmOrCancel() {
        for intent in [ControllerIntent.confirm, .cancel, .terminal(.control(.interrupt))] {
            var state = ready()
            XCTAssertEqual(state.handle(.intent(.scrollModeChanged(true))),
                           [.terminal(generation: state.generation, action: .scrollback(deltaLines: 0))])
            XCTAssertTrue(state.scrollMode)
            XCTAssertEqual(state.handle(.intent(intent)), [])
            XCTAssertFalse(state.scrollMode)
        }
    }

    func testMapperEdgesNoRepeatEnterOrInterruptAndTriggerHysteresis() {
        var mapper = ControllerMapper(); mapper.setGate(true)
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 0), [.confirm])
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 0.1), [])
        XCTAssertEqual(mapper.handle(.tick, at: 10), [])
        _ = mapper.handle(.leftTrigger(0.65), at: 10)
        XCTAssertEqual(mapper.handle(.button(.circle, pressed: true), at: 10), [.terminal(.control(.interrupt))])
        XCTAssertEqual(mapper.handle(.tick, at: 20), [])
        XCTAssertEqual(mapper.handle(.rightTrigger(0.64), at: 20), [])
        XCTAssertEqual(mapper.handle(.rightTrigger(0.65), at: 20), [.dictationPressed])
        XCTAssertEqual(mapper.handle(.rightTrigger(0.5), at: 20), [])
        mapper.setOrdinaryActionsEnabled(false)
        XCTAssertEqual(mapper.handle(.rightTrigger(0.35), at: 20), [.dictationReleased])
    }

    func testMapperBoundedRepeatNoCatchupAndReleaseStops() {
        var mapper = ControllerMapper(); mapper.setGate(true)
        let arrow = ControllerIntent.terminal(.arrow(.up))
        XCTAssertEqual(mapper.handle(.button(.up, pressed: true), at: 0), [arrow])
        XCTAssertEqual(mapper.handle(.tick, at: 0.39), [])
        XCTAssertEqual(mapper.handle(.tick, at: 0.4), [arrow])
        XCTAssertEqual(mapper.handle(.tick, at: 100), [arrow])
        XCTAssertEqual(mapper.handle(.tick, at: 100.01), [])
        XCTAssertEqual(mapper.handle(.tick, at: 100.125), [arrow])
        _ = mapper.handle(.button(.up, pressed: false), at: 101)
        XCTAssertEqual(mapper.handle(.tick, at: 102), [])
    }

    func testMapperDeadZonePaneModifierAndVoiceGating() {
        var mapper = ControllerMapper(); mapper.setGate(true)
        _ = mapper.handle(.leftTrigger(0.8), at: 0)
        XCTAssertEqual(mapper.handle(.button(.up, pressed: true), at: 0), [.terminal(.selectPane(.up))])
        _ = mapper.handle(.leftTrigger(0), at: 1)
        XCTAssertEqual(mapper.handle(.tick, at: 1), [])
        XCTAssertEqual(mapper.handle(.stickY(1), at: 1), []) // no scroll until Triangle
        XCTAssertEqual(mapper.handle(.button(.triangle, pressed: true), at: 1), [.scrollModeChanged(true)])
        _ = mapper.handle(.stickY(0.25), at: 1)
        XCTAssertEqual(mapper.handle(.stickY(0.26), at: 1), [.terminal(.scrollback(deltaLines: 8))])
        mapper.setOrdinaryActionsEnabled(false)
        XCTAssertEqual(mapper.handle(.tick, at: 100), [])
        XCTAssertEqual(mapper.handle(.button(.square, pressed: true), at: 100), [])
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 100), [.confirm])
        XCTAssertFalse(mapper.isScrollMode)
    }

    func testGateReopenNeverReplaysHeldInputAndDisconnectRequiresR2Release() {
        var mapper = ControllerMapper()
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 0), [])
        mapper.setGate(true)
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 1), [])
        _ = mapper.handle(.button(.cross, pressed: false), at: 1)
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 1), [.confirm])
        mapper.disconnected(); mapper.setGate(true)
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 1), [])
        _ = mapper.handle(.button(.cross, pressed: false), at: 1)
        XCTAssertEqual(mapper.handle(.button(.cross, pressed: true), at: 1), [.confirm])
        XCTAssertEqual(mapper.handle(.rightTrigger(1), at: 1), [])
        XCTAssertEqual(mapper.handle(.rightTrigger(0), at: 1), [.dictationReleased])
        XCTAssertEqual(mapper.handle(.rightTrigger(1), at: 1), [.dictationPressed])
    }
}
