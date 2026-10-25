import XCTest
import PromptpadCore
@testable import PromptpadApp

private let target = TerminalTarget(sessionID: "session-original", windowID: "w", tabID: "t", title: "shell")

private actor FakeBridge: BridgeClient {
    var requests: [BridgeRequest] = []
    var current = target
    var unknownInsertion = false
    var heldOperation: BridgeOperation?
    var heldRequest: CheckedContinuation<Void, Never>?
    var pageSize = 40
    var captureFailure: BridgeErrorCode?
    var disconnects = 0
    func failCapture(_ code: BridgeErrorCode) { captureFailure = code }
    func holdNext(_ operation: BridgeOperation) { heldOperation = operation }
    func releaseRequest() { heldRequest?.resume(); heldRequest = nil }
    func useShortPages() { pageSize = 3 }
    func request(_ request: BridgeRequest) async throws -> BridgeResponse {
        requests.append(request)
        if request.operation == heldOperation {
            heldOperation = nil
            await withCheckedContinuation { heldRequest = $0 }
        }
        if request.operation == .captureTarget, let code = captureFailure {
            throw BridgeFailure(code, "Terminal focus unavailable (\(code.rawValue)).")
        }
        if request.operation == .readScrollback {
            let first = request.firstLine ?? 17
            let lines = (first..<min(100, first + pageSize)).map { "Line \($0)" }
            return .init(id: request.id, target: current,
                page: .init(target: current, firstLine: first, oldestLine: 0, newestLine: 100, lines: lines))
        }
        if request.operation == .insertText, unknownInsertion { throw BridgeFailure(.outcomeUnknown, "Inspect session-original before acknowledging.") }
        if let pinned = request.target, pinned != current { throw BridgeFailure(.targetChanged, "Target changed.") }
        return .init(id: request.id, target: request.operation == .ping ? nil : current)
    }
    func disconnect() async { disconnects += 1 }
    func disconnectCount() -> Int { disconnects }
    func allRequests() -> [BridgeRequest] { requests }
    func changeTarget() { current = .init(sessionID: "other", windowID: "w", tabID: "t", title: "other") }
    func loseInsertionReply() { unknownInsertion = true }
}
@MainActor private final class FakeVoice: VoiceService {
    var inputs: [AudioInput] = []
    var recognitionNotice = "Test"
    var started: [UInt64] = []
    var cancelled: [UInt64] = []
    var stopped: [UInt64] = []
    func stopCapture(generation: UInt64) { stopped.append(generation) }
    var waiter: CheckedContinuation<String, Error>?
    var delayTranscription = false
    func requestAuthorization() async throws {}
    func startRecording(inputID: String?, generation: UInt64) async throws { started.append(generation) }
    func stopAndTranscribe(generation: UInt64) async throws -> String {
        if delayTranscription { return try await withCheckedThrowingContinuation { waiter = $0 } }
        return "  echo\nhello\t\u{1b} "
    }
    func cancel(generation: UInt64) {
        cancelled.append(generation)
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }
}
@MainActor private final class FakeKeys: NativeKeyService {
    func sendArrow(_ direction: Direction, target: TerminalTarget) async throws {}
}

@MainActor final class CoordinatorTests: XCTestCase {
    private func ready() -> (AppCoordinator, FakeBridge, FakeVoice) {
        let bridge = FakeBridge(); let voice = FakeVoice()
        let app = AppCoordinator(bridge: bridge); app.voice = voice; app.keys = FakeKeys()
        app.send(.enabledChanged(true)); app.controllerChanged(true)
        app.send(.foregroundChanged(true)); app.send(.bridgeChanged(.connected))
        return (app, bridge, voice)
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(20)) }
    private func review(_ app: AppCoordinator) async {
        app.receive(.rightTrigger(1)); await settle()
        app.receive(.rightTrigger(0)); await settle()
    }
    func testReviewInsertOnceDistinctCrossSubmitsAndPinsTarget() async {
        let (app, bridge, _) = ready()
        await review(app)
        guard case let .review(_, pinned, text) = app.state.dictation else { return XCTFail("Missing review") }
        XCTAssertEqual(pinned, target); XCTAssertEqual(text, "echo hello")
        app.receive(.button(.cross, pressed: true)); await settle()
        app.receive(.button(.cross, pressed: true)); app.receive(.tick); await settle()
        let inserted = await bridge.allRequests()
        XCTAssertEqual(inserted.filter { $0.operation == .insertText }.count, 1)
        XCTAssertFalse(inserted.contains { $0.control == .enter })
        app.receive(.button(.cross, pressed: false)); app.receive(.button(.cross, pressed: true)); await settle()
        let sent = await bridge.allRequests().filter { $0.operation == .insertText || $0.operation == .control }
        XCTAssertEqual(sent.map(\.target), [target, target])
        XCTAssertEqual(sent.last?.control, .enter)
        XCTAssertEqual(app.state.dictation, .idle)
        await app.shutdown()
    }
    func testRecordingSuppressesOtherButtonsAndCircleDiscards() async {
        let (app, bridge, _) = ready()
        app.receive(.rightTrigger(1)); await settle()
        for button in [ControllerButton.cross, .square, .l1, .r1, .up, .triangle] { app.receive(.button(button, pressed: true)) }
        app.receive(.rightTrigger(0)); await settle()
        app.receive(.button(.circle, pressed: true)); await settle()
        XCTAssertEqual(app.state.dictation, .idle)
        let requests = await bridge.allRequests()
        XCTAssertTrue(requests.allSatisfy { $0.operation == .captureTarget })
        await app.shutdown()
    }
    func testDisconnectCancelsTranscriptionImmediatelyAndRequiresNewEdge() async {
        let (app, bridge, voice) = ready(); voice.delayTranscription = true
        app.receive(.rightTrigger(1)); await settle()
        app.receive(.rightTrigger(0)); await settle()
        XCTAssertNotNil(voice.waiter)
        let generation = app.state.generation
        app.controllerChanged(false)
        XCTAssertTrue(voice.cancelled.contains(generation))
        XCTAssertNil(voice.waiter)
        app.controllerChanged(true)
        app.receive(.button(.cross, pressed: true)); await settle()
        XCTAssertEqual(app.state.dictation, .idle)
        let requests = await bridge.allRequests()
        XCTAssertFalse(requests.contains { $0.operation == .insertText || $0.operation == .control })
        await app.shutdown()
    }
    func testChangedTargetRefusesDraftInsertion() async {
        let (app, bridge, _) = ready(); await review(app)
        await bridge.changeTarget()
        app.receive(.button(.cross, pressed: true)); await settle()
        XCTAssertNotNil(app.state.error)
        XCTAssertFalse(app.state.canUseTerminal)
        await app.shutdown()
    }
    func testUnknownInsertionLatchesUntilAcknowledgmentAndNeverRetries() async {
        let (app, bridge, _) = ready(); await review(app); await bridge.loseInsertionReply()
        app.receive(.button(.cross, pressed: true)); await settle()
        for _ in 0..<3 { app.receive(.button(.cross, pressed: false)); app.receive(.button(.cross, pressed: true)) }
        await settle()
        XCTAssertNotNil(app.state.error)
        let requests = await bridge.allRequests()
        XCTAssertEqual(requests.filter { $0.operation == .insertText }.count, 1)
        XCTAssertFalse(requests.contains { $0.control == .enter })
        app.send(.dismissError)
        XCTAssertTrue(app.state.canUseTerminal)
        await app.shutdown()
    }
    func testSnapshotR2PrecedesSimultaneousCross() async {
        let (app, bridge, _) = ready()
        let source = GameControllerAdapter(); source.onEvent = { app.receive($0) }
        source.deliver(.init(buttons: [.cross, .square], rightTrigger: 1)); await settle()
        let requests = await bridge.allRequests()
        XCTAssertTrue(requests.allSatisfy { $0.operation == .captureTarget })
        await app.shutdown()
    }
    func testFocusLossInvalidatesPinnedGenerationAndShutdownStopsVoice() async {
        let (app, _, voice) = ready()
        app.receive(.rightTrigger(1)); await settle()
        let generation = app.state.generation
        XCTAssertEqual(app.pinnedTarget(generation: generation), target)
        app.send(.foregroundChanged(false))
        XCTAssertNil(app.pinnedTarget(generation: generation))
        XCTAssertTrue(voice.cancelled.contains(generation))
        await app.shutdown()
        app.send(.enabledChanged(true))
        XCTAssertFalse(app.state.enabled)
    }
    func testBusyToggleDoesNotDesynchronizeScrollMode() async {
        let (app, bridge, _) = ready()
        await bridge.holdNext(.captureTarget)
        app.receive(.button(.square, pressed: true)); await settle()
        app.receive(.button(.triangle, pressed: true))
        app.receive(.button(.triangle, pressed: false))
        XCTAssertFalse(app.state.scrollMode)
        await bridge.releaseRequest(); await settle()
        app.receive(.button(.triangle, pressed: true)); await settle()
        XCTAssertTrue(app.state.scrollMode)
        app.receive(.button(.triangle, pressed: false))
        await bridge.holdNext(.readScrollback)
        app.receive(.stickY(1)); await settle()
        app.receive(.button(.triangle, pressed: true))
        app.receive(.button(.triangle, pressed: false))
        XCTAssertTrue(app.state.scrollMode)
        await bridge.releaseRequest(); await settle()
        app.receive(.button(.triangle, pressed: true)); await settle()
        XCTAssertFalse(app.state.scrollMode)
        await app.shutdown()
    }
    func testShortScrollbackPagesDoNotSkipLinesInEitherDirection() async {
        let (app, bridge, _) = ready()
        await bridge.useShortPages()
        app.receive(.button(.triangle, pressed: true)); await settle()
        XCTAssertEqual(app.scrollback?.firstLine, 17)
        app.receive(.stickY(-1)); await settle()
        XCTAssertEqual(app.scrollback?.firstLine, 20)
        app.receive(.stickY(0))
        app.receive(.stickY(1)); await settle()
        XCTAssertEqual(app.scrollback?.firstLine, 19)
        await app.shutdown()
    }

    func testReleaseStopsCaptureImmediatelyDuringPendingMonitorRPC() async {
        let (app, bridge, voice) = ready()
        app.receive(.rightTrigger(1)); await settle()
        let generation = app.state.generation
        await bridge.holdNext(.captureTarget)
        app.startMonitoring { true }
        await settle()
        app.receive(.rightTrigger(0))
        XCTAssertEqual(voice.stopped, [generation])
        XCTAssertEqual(app.state.dictation, .transcribing(generation: generation, target: target))
        await bridge.releaseRequest(); await settle()
        guard case .review = app.state.dictation else {
            await app.shutdown(); return XCTFail("Expected reviewed transcript")
        }
        await app.shutdown()
    }

    func testMonitoringTargetFailuresCancelDraftWithoutDisconnectingOrRetargeting() async {
        for code in [BridgeErrorCode.notFocused, .targetChanged, .targetGone] {
            let (app, bridge, voice) = ready()
            await review(app)
            let generation = app.state.generation
            await bridge.failCapture(code)
            app.startMonitoring { true }; await settle()
            XCTAssertEqual(app.state.dictation, .idle)
            XCTAssertTrue(voice.cancelled.contains(generation))
            XCTAssertEqual(app.state.error, "Terminal focus unavailable (\(code.rawValue)).")
            XCTAssertEqual(app.state.bridgeStatus, .connected)
            let disconnects = await bridge.disconnectCount()
            XCTAssertEqual(disconnects, 0)
            await bridge.changeTarget()
            app.receive(.button(.cross, pressed: true)); await settle()
            let requests = await bridge.allRequests()
            XCTAssertFalse(requests.contains { $0.operation == .insertText || $0.operation == .control })
            await app.shutdown()
        }
    }

    func testMonitoringChangedTargetEndsInsertedWorkflowWithoutDiscardErrorOrSending() async {
        let (app, bridge, _) = ready()
        await review(app)
        app.receive(.button(.cross, pressed: true)); await settle()
        guard case .inserted = app.state.dictation else { await app.shutdown(); return XCTFail("Expected insertion") }
        let generation = app.state.generation
        await bridge.changeTarget()
        app.startMonitoring { true }; await settle()
        XCTAssertEqual(app.state.dictation, .idle)
        XCTAssertGreaterThan(app.state.generation, generation)
        XCTAssertNil(app.state.error)
        XCTAssertEqual(app.state.bridgeStatus, .connected)
        XCTAssertNil(app.pinnedTarget(generation: generation))
        // A held insertion button cannot become Enter after lifecycle cancellation.
        app.receive(.button(.cross, pressed: true)); app.receive(.tick); await settle()
        let requests = await bridge.allRequests()
        XCTAssertEqual(requests.filter { $0.operation == .insertText }.count, 1)
        XCTAssertFalse(requests.contains { $0.control == .enter })
        let disconnects = await bridge.disconnectCount()
        XCTAssertEqual(disconnects, 0)
        await app.shutdown()
    }

    func testInsertedTargetFocusAndClosureFailuresAreQuiet() async {
        for code in [BridgeErrorCode.notFocused, .targetGone] {
            let (app, bridge, _) = ready()
            await review(app)
            app.receive(.button(.cross, pressed: true)); await settle()
            await bridge.failCapture(code)
            app.startMonitoring { true }; await settle()
            XCTAssertEqual(app.state.dictation, .idle)
            XCTAssertNil(app.state.error)
            XCTAssertEqual(app.state.bridgeStatus, .connected)
            let requests = await bridge.allRequests()
            XCTAssertEqual(requests.filter { $0.operation == .insertText }.count, 1)
            XCTAssertFalse(requests.contains { $0.control == .enter })
            await app.shutdown()
        }
    }

    func testMonitorTargetLossCancelsPendingTranscriptionImmediately() async {
        let (app, bridge, voice) = ready()
        voice.delayTranscription = true
        await review(app)
        XCTAssertNotNil(voice.waiter)
        let generation = app.state.generation
        await bridge.changeTarget()
        app.startMonitoring { true }; await settle()
        XCTAssertNil(voice.waiter)
        XCTAssertTrue(voice.cancelled.contains(generation))
        XCTAssertEqual(app.state.dictation, .idle)
        XCTAssertNotNil(app.state.error)
        XCTAssertEqual(app.state.bridgeStatus, .connected)
        let requests = await bridge.allRequests()
        XCTAssertFalse(requests.contains { $0.operation == .insertText || $0.operation == .control })
        await app.shutdown()
    }

    func testMonitoringDoesNotClearUnknownInsertionLatch() async {
        let (app, bridge, _) = ready()
        await review(app); await bridge.loseInsertionReply()
        app.receive(.button(.cross, pressed: true)); await settle()
        let error = app.state.error
        XCTAssertNotNil(error)
        await bridge.changeTarget()
        app.startMonitoring { true }; await settle()
        XCTAssertEqual(app.state.error, error)
        app.receive(.button(.cross, pressed: false)); app.receive(.button(.cross, pressed: true)); await settle()
        let requests = await bridge.allRequests()
        XCTAssertEqual(requests.filter { $0.operation == .insertText }.count, 1)
        XCTAssertFalse(requests.contains { $0.control == .enter })
        await app.shutdown()
    }

}
